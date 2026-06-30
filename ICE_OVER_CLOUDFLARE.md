# ICE-style P2P traversal over a proxied (Cloudflare/WSS) rendezvous

> Experimental fork branch: `experiment/ice-candidate-traversal`.
> Status: **research / in progress.** This document is the design of record.

## 1. The idea in one paragraph

RustDesk's rendezvous server (`hbbs`) can be reached two ways: directly over
UDP/TCP, or over WebSocket (WSS, 443) through a reverse proxy such as
Cloudflare. The proxy is great for hiding the server and surviving hostile
networks, but today it forces every session through the **relay** (`hbbr`),
because the proxy hides each peer's real transport address from the server, and
the server is what tells peers where to punch. The idea here is to borrow
WebRTC's model: keep **signaling** on the proxied WSS channel (server stays
hidden), but do **candidate discovery** against *public* STUN servers and let
peers punch a **direct** path to each other. Signaling over the proxy, media
peer-to-peer.

## 2. How RustDesk traversal works today (mapped in this fork)

Files/lines are from this checkout.

### Controlling side (the peer that initiates), `src/client.rs`
- `test_udp_uat` (≈4183): opens a UDP socket and sends `TestNatRequest` **to the
  rendezvous server** over UDP. The server replies `TestNatResponse { port }` —
  i.e. *the rendezvous server acts as the STUN server* and reports the public
  port it observed. Result is stored as `udp_port` (4222/4256).
- The punch request (≈462) sends `PunchHoleRequest { id, udp_port, ... }`.

### Server (`rustdesk-server`/`sctgdesk`, hbbs)
- Looks up the target peer, and relays a `PunchHole` to it, filling
  `socket_addr` with the **address the server observed** for the initiator.

### Controlled side (the peer being connected to), `src/rendezvous_mediator.rs`
- `handle_punch_hole` (650): `peer_addr = AddrMangle::decode(ph.socket_addr)`
  (651) — the address to punch toward, **as provided by the server**.
- The relay gate (659): `let relay = use_ws() || Config::is_proxy() || ph.force_relay;`
- If not relaying and `ph.udp_port > 0` → `punch_udp_hole` (701-705).
- `punch_udp_hole` (724): `new_direct_udp_for(host)` opens a UDP socket, sends
  `PunchHoleSent` **to the rendezvous host** over UDP (to open/observe the
  mapping), then `udp_nat_listen` waits for the peer. (948)

### Net effect
Both peers learn their public mapping by talking to the **rendezvous server over
direct UDP**, and the **server** stitches the two observed addresses together.

## 3. Why the proxy forces relay

When the only path to the server is WSS/443 via Cloudflare:
1. **No direct UDP to the server** → `test_udp_uat` / `punch_udp_hole` can't
   discover a mapping. (`use_ws()` is true.)
2. **Server can't observe a peer's real address** → it only sees Cloudflare.
3. So `let relay = use_ws() || ...` short-circuits to relay, by design.

It's not a bug — there is simply no address information to punch with.

## 4. The change: swap "server-as-STUN" for "public STUN", exchange candidates over signaling

The discovery RustDesk already does is *exactly* STUN; it just points at the
rendezvous server. We:

1. **Gather srflx from public STUN** on the very socket we'll punch from
   (`src/ice.rs`, this commit). EIM NATs return a stable mapping, so the
   advertised `IP:port` is reachable by the peer.
2. **Carry the candidate over the existing WSS signaling.** The punch messages
   already carry an address field (`socket_addr`); we set it to *our*
   STUN-discovered address instead of relying on the server's observation, and
   we add the peer's IP (today only `udp_port` crosses; the server supplies the
   IP). The server **passes the candidate through unchanged** rather than
   overwriting it.
3. **Punch** using the exchanged candidates with the existing
   `punch_udp_hole` / `udp_nat_listen` path. Relay remains the fallback.

Because signaling still flows over WSS, the rendezvous server's real address is
never exposed; public STUN only ever learns the peers' own mappings.

## 5. Concrete change list

### A. `rustdesk` client (this repo) — DONE, compiles (`cargo check --features linux-pkg-config`)
- [x] `src/ice.rs` — STUN srflx gatherer + EIM probe + `enabled()`/`configured_stun()`.
- [x] Controlling side (`client.rs`): under `use_ws()` + ICE, skip the (proxy-dropped)
      UDP NAT test, gather srflx via `ice::gather_srflx_on` on the punch socket, and
      advertise the full `IP:port` in `PunchHoleRequest.ice_srflx`; on the
      `PunchHoleResponse`, punch toward `ph.ice_srflx` when present.
- [x] Controlled side (`rendezvous_mediator.rs`): in `handle_punch_hole`, when an ICE
      candidate is present and not force-relay, gather our own srflx, report it back via
      `PunchHoleSent.ice_srflx` over the proxied rendezvous, and punch to the peer
      candidate (`punch_udp_hole_ice`). Falls back to relay on any failure.
- [x] Config options `enable-ice` (default **off**) and `custom-stun-server`.

### B. `hbb_common` (submodule) — DONE, forked + repointed
- [x] Added `string ice_srflx` to `PunchHoleRequest`/`PunchHole`/`PunchHoleSent`/
      `PunchHoleResponse` (backward-compatible new field numbers). Pushed to
      `crashbandicode/hbb_common@experiment/ice-candidate-traversal`; the rustdesk
      submodule URL + commit are repointed there.
- Note: a shallow clone does **not** fetch submodules; run
  `git submodule update --init libs/hbb_common` before building.

### C. Server (`crashbandicode/sctgdesk-server`, hbbs) — TODO (required for e2e)
- [ ] Bump the server's `hbb_common` to one that has `ice_srflx`.
- [ ] In the punch-hole request handler, copy `ice_srflx` verbatim from
      `PunchHoleRequest` → `PunchHole` (to the controlled peer) and from
      `PunchHoleSent` → `PunchHoleResponse` (to the initiator), instead of relying on
      the proxy-observed `socket_addr`.
- [ ] Optionally surface a server-provided STUN list to clients.

## 6. NAT reality (measured today, 2026-06-30)

From the home network (`stun_poc.py`):
```
same socket -> stun.l.google.com  : 184.164.47.94:59271
same socket -> stun.cloudflare.com: 184.164.47.94:59271
=> ENDPOINT-INDEPENDENT MAPPING (punchable)
```
Public port also equalled the local source port (port-preserving NAT). So the
home side is punchable. Still to verify:
- **Mobile carrier (Verizon) side.** Many mobile networks are CGNAT; some are
  EIM (punchable), some symmetric (not). The Amcrest P2P that worked on the
  phone is evidence EIM is at least sometimes available there.
- If **either** side is symmetric, direct punch fails → **relay fallback**
  (unchanged behaviour). This experiment only ever *adds* a fast path.

## 7. How to test

- Unit (no network): `ice.rs` parses the RFC 5769 sample vector and validates
  request framing — `cargo test -p rustdesk ice`.
- Discovery PoC (Python, no toolchain): `python3 stun_poc.py` (kept outside the
  repo) prints srflx + the EIM verdict from the current network.
- End-to-end (later): two clients pointed at the proxied `hbbs`, with relay
  temporarily disabled, confirm a direct path via `netstat`/logs.

## 8. Honest assessment

- **Most promising:** discovery + candidate exchange is small and localized; the
  punch machinery already exists and is merely gated off under `use_ws()`.
- **Real work:** the protobuf change spans the `hbb_common` submodule and the
  server, and there are three sides to keep in sync.
- **Won't fix everything:** symmetric/CGNAT peers still need relay; this is a
  best-effort fast path, exactly like WebRTC's ICE (which also falls back to
  TURN). That's the right mental model.
