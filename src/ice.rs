//! Experimental ICE-style NAT traversal helpers (see ICE_OVER_CLOUDFLARE.md).
//!
//! Goal: let two peers establish a direct (P2P) media path even when the
//! rendezvous server is reached only over WebSocket through a reverse proxy
//! (e.g. Cloudflare), which today forces `relay` because the proxy hides each
//! peer's transport address.
//!
//! RustDesk already performs STUN-like discovery, but it uses the *rendezvous
//! server itself* as the STUN server over direct UDP (`TestNatRequest` ->
//! `TestNatResponse.port`, see `client::test_udp_uat` and
//! `rendezvous_mediator::punch_udp_hole`). When the only path to the server is
//! WSS/443 through a proxy, that direct-UDP discovery is impossible.
//!
//! This module provides the missing piece: discover our own server-reflexive
//! (srflx) mapping from a *public* STUN server over UDP, on the very socket we
//! intend to punch from. The discovered `IP:port` is then exchanged with the
//! peer over the existing (proxied) signaling channel, and the existing punch
//! machinery can run. Public STUN means the rendezvous server's IP never has to
//! be exposed.
//!
//! Only IPv4 + XOR-MAPPED-ADDRESS is handled here; that is all RustDesk's punch
//! path needs. The parser is covered by the RFC 5769 sample vector test.

use std::net::SocketAddr;

use hbb_common::{
    anyhow::bail,
    tokio::{
        net::UdpSocket,
        time::{timeout, Duration},
    },
    ResultType,
};

/// STUN magic cookie (RFC 5389).
pub const MAGIC_COOKIE: u32 = 0x2112_A442;

/// Public STUN servers used for srflx discovery. These never see our session
/// traffic and never learn the rendezvous server's address.
pub const DEFAULT_STUN_SERVERS: &[&str] = &[
    "stun.l.google.com:19302",
    "stun.cloudflare.com:3478",
    "stun1.l.google.com:19302",
];

const BINDING_REQUEST: u16 = 0x0001;
const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;

/// Config option name that turns the experimental ICE path on (default off).
pub const OPTION_ENABLE_ICE: &str = "enable-ice";
/// Config option name for overriding the STUN server used for srflx discovery.
pub const OPTION_STUN_SERVER: &str = "custom-stun-server";

/// Whether the experimental ICE traversal path is enabled.
///
/// This is the dedicated `experiment/ice-candidate-traversal` build, so ICE
/// defaults **on** when the option is unset — that lets the Android APK (where
/// editing the config file is impractical) exercise the path with no extra
/// setup. It can still be explicitly turned off via config
/// (`enable-ice = 'N'`), and only affects WebSocket/proxied connections; direct
/// (port-forwarded) sessions are untouched.
pub fn enabled() -> bool {
    let v = hbb_common::config::Config::get_option(OPTION_ENABLE_ICE).to_lowercase();
    // On (default) unless explicitly disabled; empty/unset counts as on.
    !matches!(v.as_str(), "n" | "no" | "false" | "0" | "off")
}

/// STUN server (`host:port`) to use for srflx discovery: the configured override
/// if set, otherwise the first default public server.
pub fn configured_stun() -> String {
    let s = hbb_common::config::Config::get_option(OPTION_STUN_SERVER);
    if s.is_empty() {
        DEFAULT_STUN_SERVERS[0].to_string()
    } else {
        s
    }
}

/// Build a STUN Binding Request with the given 96-bit transaction id.
pub fn build_binding_request(txn: &[u8; 12]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(20);
    buf.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    buf.extend_from_slice(&0u16.to_be_bytes()); // message length (no attributes)
    buf.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    buf.extend_from_slice(txn);
    buf
}

/// Parse a STUN Binding response and return the reflexive `IPv4:port` from the
/// XOR-MAPPED-ADDRESS attribute (falling back to MAPPED-ADDRESS).
pub fn parse_mapped_address(resp: &[u8]) -> Option<SocketAddr> {
    if resp.len() < 20 {
        return None;
    }
    let mut i = 20usize; // skip the 20-byte STUN header
    while i + 4 <= resp.len() {
        let atype = u16::from_be_bytes([resp[i], resp[i + 1]]);
        let alen = u16::from_be_bytes([resp[i + 2], resp[i + 3]]) as usize;
        let val_start = i + 4;
        if val_start + alen > resp.len() {
            break;
        }
        let val = &resp[val_start..val_start + alen];
        if (atype == ATTR_XOR_MAPPED_ADDRESS || atype == ATTR_MAPPED_ADDRESS) && alen >= 8 {
            let family = val[1];
            if family == 0x01 {
                // IPv4
                let raw_port = u16::from_be_bytes([val[2], val[3]]);
                let magic = MAGIC_COOKIE.to_be_bytes();
                let (port, ip) = if atype == ATTR_XOR_MAPPED_ADDRESS {
                    let port = raw_port ^ (MAGIC_COOKIE >> 16) as u16;
                    let ip = [
                        val[4] ^ magic[0],
                        val[5] ^ magic[1],
                        val[6] ^ magic[2],
                        val[7] ^ magic[3],
                    ];
                    (port, ip)
                } else {
                    (raw_port, [val[4], val[5], val[6], val[7]])
                };
                return Some(SocketAddr::from((ip, port)));
            }
        }
        // attributes are padded to a 4-byte boundary
        i = val_start + alen + ((4 - (alen % 4)) % 4);
    }
    None
}

fn new_txn() -> [u8; 12] {
    use std::sync::atomic::{AtomicU64, Ordering};
    static CTR: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let ctr = CTR.fetch_add(1, Ordering::Relaxed);
    let mut t = [0u8; 12];
    t[..8].copy_from_slice(&nanos.to_le_bytes());
    t[8..].copy_from_slice(&(ctr as u32).to_le_bytes());
    t
}

async fn resolve_v4(server: &str) -> ResultType<SocketAddr> {
    let mut it = hbb_common::tokio::net::lookup_host(server).await?;
    match it.find(|a| a.is_ipv4()) {
        Some(a) => Ok(a),
        None => bail!("no IPv4 address for STUN server {}", server),
    }
}

/// Discover the server-reflexive candidate for an already-bound UDP socket.
///
/// Critical: the mapping is gathered on the *same* socket that will later be
/// used to punch, so on endpoint-independent-mapping (EIM) NATs the advertised
/// address is the one the peer can actually reach.
pub async fn gather_srflx_on(
    socket: &UdpSocket,
    stun_server: &str,
    timeout_ms: u64,
) -> ResultType<SocketAddr> {
    let target = resolve_v4(stun_server).await?;
    let txn = new_txn();
    let req = build_binding_request(&txn);
    socket.send_to(&req, target).await?;
    let mut buf = [0u8; 512];
    let (n, _src) = timeout(Duration::from_millis(timeout_ms), socket.recv_from(&mut buf)).await??;
    match parse_mapped_address(&buf[..n]) {
        Some(addr) => Ok(addr),
        None => bail!("STUN response from {} had no mapped address", stun_server),
    }
}

/// Convenience: bind a fresh socket and gather its srflx candidate.
pub async fn gather_srflx(stun_server: &str, timeout_ms: u64) -> ResultType<(UdpSocket, SocketAddr)> {
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    let srflx = gather_srflx_on(&socket, stun_server, timeout_ms).await?;
    Ok((socket, srflx))
}

/// Probe the NAT mapping behaviour by querying two STUN servers from one
/// socket. Equal mappings => endpoint-independent (punchable); differing
/// mappings => symmetric NAT (must relay).
pub async fn detect_endpoint_independent_mapping(
    stun_a: &str,
    stun_b: &str,
    timeout_ms: u64,
) -> ResultType<(SocketAddr, SocketAddr, bool)> {
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    let a = gather_srflx_on(&socket, stun_a, timeout_ms).await?;
    let b = gather_srflx_on(&socket, stun_b, timeout_ms).await?;
    let eim = a == b;
    Ok((a, b, eim))
}

/// A peer's exchanged ICE candidates. Encoded compactly into the single
/// `ice_srflx` signaling string (which our patched rendezvous relays verbatim,
/// so no server change is needed) as `h=<ip:port>;s=<ip:port>`. For backward
/// compatibility a bare `ip:port` with no tags is read as the srflx candidate.
#[derive(Default, Debug, Clone)]
pub struct Candidates {
    /// Host candidate: our LAN address (best for same-network peers).
    pub host: Option<SocketAddr>,
    /// Server-reflexive candidate: our public mapping via STUN.
    pub srflx: Option<SocketAddr>,
}

/// Our primary LAN IP, as recorded when connecting to the rendezvous server
/// (`local-ip-addr`). Loopback / unspecified are rejected.
pub fn local_ip() -> Option<std::net::IpAddr> {
    let s = hbb_common::config::Config::get_option("local-ip-addr");
    if s.is_empty() {
        return None;
    }
    s.parse::<std::net::IpAddr>()
        .ok()
        .filter(|ip| !ip.is_loopback() && !ip.is_unspecified())
}

/// Build our host candidate string (LAN IP + the local port we punch from).
pub fn host_candidate(local_port: u16) -> Option<String> {
    if local_port == 0 {
        return None;
    }
    local_ip().map(|ip| SocketAddr::new(ip, local_port).to_string())
}

/// Encode host + srflx candidates into the single signaling string.
pub fn encode_candidates(host: Option<&str>, srflx: Option<&str>) -> String {
    let mut parts = Vec::new();
    if let Some(h) = host {
        if !h.is_empty() {
            parts.push(format!("h={}", h));
        }
    }
    if let Some(s) = srflx {
        if !s.is_empty() {
            parts.push(format!("s={}", s));
        }
    }
    parts.join(";")
}

/// Parse the signaling string produced by [`encode_candidates`]. A bare
/// `ip:port` (older builds) is interpreted as the srflx candidate.
pub fn parse_candidates(s: &str) -> Candidates {
    let mut c = Candidates::default();
    if s.is_empty() {
        return c;
    }
    if !s.contains('=') {
        c.srflx = s.parse().ok();
        return c;
    }
    for part in s.split(';') {
        if let Some(v) = part.strip_prefix("h=") {
            c.host = v.parse().ok();
        } else if let Some(v) = part.strip_prefix("s=") {
            c.srflx = v.parse().ok();
        }
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidate_roundtrip() {
        let enc = encode_candidates(Some("192.168.0.5:41000"), Some("203.0.113.7:50000"));
        let c = parse_candidates(&enc);
        assert_eq!(c.host, Some("192.168.0.5:41000".parse().unwrap()));
        assert_eq!(c.srflx, Some("203.0.113.7:50000".parse().unwrap()));
    }

    #[test]
    fn candidate_bare_is_srflx() {
        let c = parse_candidates("203.0.113.7:50000");
        assert!(c.host.is_none());
        assert_eq!(c.srflx, Some("203.0.113.7:50000".parse().unwrap()));
    }

    #[test]
    fn candidate_srflx_only() {
        let enc = encode_candidates(None, Some("203.0.113.7:50000"));
        assert_eq!(enc, "s=203.0.113.7:50000");
        let c = parse_candidates(&enc);
        assert!(c.host.is_none());
        assert_eq!(c.srflx, Some("203.0.113.7:50000".parse().unwrap()));
    }

    // RFC 5769 section 2.1/2.2 sample: XOR-MAPPED-ADDRESS decodes to
    // 192.0.2.1:32853.
    #[test]
    fn parses_rfc5769_xor_mapped_address() {
        let txn = [
            0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae,
        ];
        let mut resp = Vec::new();
        resp.extend_from_slice(&0x0101u16.to_be_bytes()); // Binding Success Response
        resp.extend_from_slice(&0x000cu16.to_be_bytes()); // length: one 12-byte attr
        resp.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        resp.extend_from_slice(&txn);
        // XOR-MAPPED-ADDRESS attribute
        resp.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
        resp.extend_from_slice(&0x0008u16.to_be_bytes());
        resp.extend_from_slice(&[0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43]);

        let addr = parse_mapped_address(&resp).expect("should parse");
        assert_eq!(addr, "192.0.2.1:32853".parse().unwrap());
    }

    #[test]
    fn binding_request_is_well_formed() {
        let txn = [1u8; 12];
        let req = build_binding_request(&txn);
        assert_eq!(req.len(), 20);
        assert_eq!(u16::from_be_bytes([req[0], req[1]]), BINDING_REQUEST);
        assert_eq!(u16::from_be_bytes([req[2], req[3]]), 0); // no attributes
        assert_eq!(u32::from_be_bytes([req[4], req[5], req[6], req[7]]), MAGIC_COOKIE);
        assert_eq!(&req[8..20], &txn);
    }

    #[test]
    fn rejects_short_and_empty() {
        assert!(parse_mapped_address(&[]).is_none());
        assert!(parse_mapped_address(&[0u8; 10]).is_none());
    }
}
