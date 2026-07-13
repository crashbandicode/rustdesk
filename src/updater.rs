use crate::{common::do_check_software_update, hbbs_http::create_http_client_with_url_strict};
use hbb_common::{anyhow::anyhow, bail, config, log, ResultType};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc::{channel, Receiver, Sender},
        Mutex,
    },
    time::{Duration, Instant},
};

enum UpdateMsg {
    CheckUpdate,
    Exit,
}

lazy_static::lazy_static! {
    static ref TX_MSG : Mutex<Sender<UpdateMsg>> = Mutex::new(start_auto_update_check());
}

static CONTROLLING_SESSION_COUNT: AtomicUsize = AtomicUsize::new(0);

const DUR_ONE_DAY: Duration = Duration::from_secs(60 * 60 * 24);
const MAX_UPDATE_BYTES: u64 = 300 * 1024 * 1024;
const MAX_CHECKSUM_MANIFEST_BYTES: usize = 64 * 1024;
const GITHUB_FORK_RELEASE_TAG_PREFIX: &str =
    "https://github.com/crashbandicode/rustdesk/releases/tag/";
const GITHUB_FORK_RELEASE_DOWNLOAD_PREFIX: &str =
    "https://github.com/crashbandicode/rustdesk/releases/download/";

fn is_github_fork_build() -> bool {
    option_env!("RUSTDESK_BUILD_FORK")
        .map(|fork| fork.split_whitespace().next() == Some("crashbandicode/rustdesk"))
        .unwrap_or(false)
}

fn is_valid_github_fork_tag(tag: &str) -> bool {
    let Some((base, build)) = tag.split_once('-') else {
        return false;
    };
    base.split('.').count() == 3
        && base
            .split('.')
            .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
        && !build.is_empty()
        && build.chars().all(|c| c.is_ascii_digit())
}

fn parse_sha256_manifest(manifest: &str, filename: &str) -> Option<String> {
    manifest.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        let hash = fields.next()?;
        let listed_filename = fields.next()?;
        if fields.next().is_none()
            && listed_filename == filename
            && hash.len() == 64
            && hash.chars().all(|c| c.is_ascii_hexdigit())
        {
            Some(hash.to_ascii_lowercase())
        } else {
            None
        }
    })
}

fn sha256_file(path: &Path) -> ResultType<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn update_controlling_session_count(count: usize) {
    CONTROLLING_SESSION_COUNT.store(count, Ordering::SeqCst);
}

#[allow(dead_code)]
pub fn start_auto_update() {
    let _sender = TX_MSG.lock().unwrap();
}

#[allow(dead_code)]
pub fn manually_check_update() -> ResultType<()> {
    let sender = TX_MSG.lock().unwrap();
    sender.send(UpdateMsg::CheckUpdate)?;
    Ok(())
}

#[allow(dead_code)]
pub fn stop_auto_update() {
    let sender = TX_MSG.lock().unwrap();
    sender.send(UpdateMsg::Exit).unwrap_or_default();
}

#[inline]
fn has_no_active_conns() -> bool {
    let conns = crate::Connection::alive_conns();
    conns.is_empty() && has_no_controlling_conns()
}

#[cfg(any(not(target_os = "windows"), feature = "flutter"))]
fn has_no_controlling_conns() -> bool {
    CONTROLLING_SESSION_COUNT.load(Ordering::SeqCst) == 0
}

#[cfg(not(any(not(target_os = "windows"), feature = "flutter")))]
fn has_no_controlling_conns() -> bool {
    let app_exe = format!("{}.exe", crate::get_app_name().to_lowercase());
    for arg in [
        "--connect",
        "--play",
        "--file-transfer",
        "--view-camera",
        "--port-forward",
        "--rdp",
    ] {
        if !crate::platform::get_pids_of_process_with_first_arg(&app_exe, arg).is_empty() {
            return false;
        }
    }
    true
}

fn start_auto_update_check() -> Sender<UpdateMsg> {
    let (tx, rx) = channel();
    std::thread::spawn(move || start_auto_update_check_(rx));
    return tx;
}

fn start_auto_update_check_(rx_msg: Receiver<UpdateMsg>) {
    std::thread::sleep(Duration::from_secs(30));
    if let Err(e) = check_update(false) {
        log::error!("Error checking for updates: {}", e);
    }

    const MIN_INTERVAL: Duration = Duration::from_secs(60 * 10);
    const RETRY_INTERVAL: Duration = Duration::from_secs(60 * 30);
    let mut last_check_time = Instant::now();
    let mut check_interval = DUR_ONE_DAY;
    loop {
        let recv_res = rx_msg.recv_timeout(check_interval);
        match &recv_res {
            Ok(UpdateMsg::CheckUpdate) | Err(_) => {
                if last_check_time.elapsed() < MIN_INTERVAL {
                    // log::debug!("Update check skipped due to minimum interval.");
                    continue;
                }
                // Don't check update if there are alive connections.
                if !has_no_active_conns() {
                    check_interval = RETRY_INTERVAL;
                    continue;
                }
                if let Err(e) = check_update(matches!(recv_res, Ok(UpdateMsg::CheckUpdate))) {
                    log::error!("Error checking for updates: {}", e);
                    check_interval = RETRY_INTERVAL;
                } else {
                    last_check_time = Instant::now();
                    check_interval = DUR_ONE_DAY;
                }
            }
            Ok(UpdateMsg::Exit) => break,
        }
    }
}

fn check_update(manually: bool) -> ResultType<()> {
    #[cfg(target_os = "windows")]
    let update_msi = crate::platform::is_msi_installed()? && !crate::is_custom_client();
    let github_fork_build = is_github_fork_build();
    if !(manually
        || github_fork_build
        || config::Config::get_bool_option(config::keys::OPTION_ALLOW_AUTO_UPDATE))
    {
        return Ok(());
    }
    if do_check_software_update().is_err() {
        // ignore
        return Ok(());
    }

    let update_url = crate::common::SOFTWARE_UPDATE_URL.lock().unwrap().clone();
    if update_url.is_empty() {
        log::debug!("No update available.");
    } else {
        let (download_url, version) = if github_fork_build {
            let Some(version) = update_url.strip_prefix(GITHUB_FORK_RELEASE_TAG_PREFIX) else {
                bail!("Unexpected fork update URL: {}", update_url);
            };
            if !is_valid_github_fork_tag(version) {
                bail!("Unexpected fork update version: {}", version);
            }
            (
                format!("{GITHUB_FORK_RELEASE_DOWNLOAD_PREFIX}{version}"),
                version.to_owned(),
            )
        } else {
            let download_url = update_url.replace("tag", "download");
            let version = download_url.split('/').last().unwrap_or_default().to_owned();
            (download_url, version)
        };
        #[cfg(target_os = "windows")]
        let download_url = if cfg!(feature = "flutter") {
            let Some(arch) = crate::platform::windows::release_arch_suffix() else {
                bail!(
                    "Unsupported Windows release architecture: {}",
                    std::env::consts::ARCH
                );
            };
            format!(
                "{}/rustdesk-{}-{}.{}",
                download_url,
                &version,
                arch,
                if update_msi { "msi" } else { "exe" }
            )
        } else {
            format!("{}/rustdesk-{}-x86-sciter.exe", download_url, &version)
        };
        log::debug!("New version available: {}", &version);
        let client = create_http_client_with_url_strict(&download_url)?;
        let Some(file_path) = get_download_file_from_url(&download_url) else {
            bail!("Failed to get the file path from the URL: {}", download_url);
        };
        let expected_sha256 = if github_fork_build {
            let filename = file_path
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or_else(|| anyhow!("Invalid update filename"))?;
            let release_base = download_url
                .rsplit_once('/')
                .map(|(base, _)| base)
                .ok_or_else(|| anyhow!("Invalid update asset URL"))?;
            let manifest_url = format!("{release_base}/SHA256SUMS.txt");
            let manifest_response = client.get(&manifest_url).send()?;
            if !manifest_response.status().is_success() {
                bail!(
                    "Failed to download update checksums: {}",
                    manifest_response.status()
                );
            }
            let manifest = manifest_response.bytes()?;
            if manifest.len() > MAX_CHECKSUM_MANIFEST_BYTES {
                bail!("Update checksum manifest is too large");
            }
            let manifest = std::str::from_utf8(&manifest)?;
            Some(
                parse_sha256_manifest(manifest, filename)
                    .ok_or_else(|| anyhow!("Update checksum is missing or invalid"))?,
            )
        } else {
            None
        };
        let mut is_file_exists = false;
        if file_path.exists() {
            // Check if the file size is the same as the server file size
            // If the file size is the same, we don't need to download it again.
            let file_size = std::fs::metadata(&file_path)?.len();
            let response = client.head(&download_url).send()?;
            if !response.status().is_success() {
                bail!("Failed to get the file size: {}", response.status());
            }
            let total_size = response
                .headers()
                .get(reqwest::header::CONTENT_LENGTH)
                .and_then(|ct_len| ct_len.to_str().ok())
                .and_then(|ct_len| ct_len.parse::<u64>().ok());
            let Some(total_size) = total_size else {
                bail!("Failed to get content length");
            };
            if total_size == 0 || total_size > MAX_UPDATE_BYTES {
                std::fs::remove_file(&file_path)?;
                bail!("Invalid update file size");
            }
            if file_size == total_size
                && expected_sha256
                    .as_ref()
                    .map(|expected| sha256_file(&file_path).ok().as_ref() == Some(expected))
                    .unwrap_or(true)
            {
                is_file_exists = true;
            } else {
                std::fs::remove_file(&file_path)?;
            }
        }
        if !is_file_exists {
            let response = client.get(&download_url).send()?;
            if !response.status().is_success() {
                bail!(
                    "Failed to download the new version file: {}",
                    response.status()
                );
            }
            let declared_size = response.content_length();
            if declared_size.map(|size| size > MAX_UPDATE_BYTES).unwrap_or(false) {
                bail!("Update file is too large");
            }
            let file_data = response.bytes()?;
            let actual_size = file_data.len() as u64;
            if actual_size == 0 || actual_size > MAX_UPDATE_BYTES {
                bail!("Invalid update file size");
            }
            if declared_size.map(|size| size != actual_size).unwrap_or(false) {
                bail!("Incomplete update download");
            }
            let filename = file_path
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or_else(|| anyhow!("Invalid update filename"))?;
            let partial_path = file_path.with_file_name(format!("{filename}.part"));
            let write_result = (|| -> ResultType<()> {
                let mut file = std::fs::File::create(&partial_path)?;
                file.write_all(&file_data)?;
                file.sync_all()?;
                if let Some(expected) = &expected_sha256 {
                    if &sha256_file(&partial_path)? != expected {
                        bail!("Downloaded update checksum does not match");
                    }
                }
                std::fs::rename(&partial_path, &file_path)?;
                Ok(())
            })();
            if write_result.is_err() {
                std::fs::remove_file(&partial_path).ok();
            }
            write_result?;
        }
        // We have checked if the `conns` is empty before, but we need to check again.
        // No need to care about the downloaded file here, because it's rare case that the `conns` are empty
        // before the download, but not empty after the download.
        if has_no_active_conns() {
            #[cfg(target_os = "windows")]
            update_new_version(update_msi, &version, &file_path);
        }
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn update_new_version(update_msi: bool, version: &str, file_path: &PathBuf) {
    log::debug!(
        "New version is downloaded, update begin, update msi: {update_msi}, version: {version}, file: {:?}",
        file_path.to_str()
    );
    if let Some(p) = file_path.to_str() {
        if let Some(session_id) = crate::platform::get_current_process_session_id() {
            if update_msi {
                match crate::platform::update_me_msi(p, true) {
                    Ok(_) => {
                        log::debug!("New version \"{}\" updated.", version);
                    }
                    Err(e) => {
                        log::error!(
                            "Failed to install the new msi version  \"{}\": {}",
                            version,
                            e
                        );
                        std::fs::remove_file(&file_path).ok();
                    }
                }
            } else {
                let custom_client_staging_dir = if crate::is_custom_client() {
                    let custom_client_staging_dir =
                        crate::platform::get_custom_client_staging_dir();
                    if let Err(e) = crate::platform::handle_custom_client_staging_dir_before_update(
                        &custom_client_staging_dir,
                    ) {
                        log::error!(
                            "Failed to handle custom client staging dir before update: {}",
                            e
                        );
                        std::fs::remove_file(&file_path).ok();
                        return;
                    }
                    Some(custom_client_staging_dir)
                } else {
                    // Clean up any residual staging directory from previous custom client
                    let staging_dir = crate::platform::get_custom_client_staging_dir();
                    hbb_common::allow_err!(crate::platform::remove_custom_client_staging_dir(
                        &staging_dir
                    ));
                    None
                };
                let update_launched = match crate::platform::launch_privileged_process(
                    session_id,
                    &format!("{} --update", p),
                ) {
                    Ok(h) => {
                        if h.is_null() {
                            log::error!("Failed to update to the new version: {}", version);
                            false
                        } else {
                            log::debug!("New version \"{}\" is launched.", version);
                            true
                        }
                    }
                    Err(e) => {
                        log::error!("Failed to run the new version: {}", e);
                        false
                    }
                };
                if !update_launched {
                    if let Some(dir) = custom_client_staging_dir {
                        hbb_common::allow_err!(crate::platform::remove_custom_client_staging_dir(
                            &dir
                        ));
                    }
                    std::fs::remove_file(&file_path).ok();
                }
            }
        } else {
            log::error!(
                "Failed to get the current process session id, Error {}",
                std::io::Error::last_os_error()
            );
            std::fs::remove_file(&file_path).ok();
        }
    } else {
        // unreachable!()
        log::error!(
            "Failed to convert the file path to string: {}",
            file_path.display()
        );
    }
}

fn get_update_download_file_from_url_(url: &str, allow_github_fork: bool) -> Option<PathBuf> {
    let parsed = url::Url::parse(url).ok()?;
    // Check the raw prefix before Url normalizes default ports.
    if !url.starts_with("https://github.com/")
        || parsed.scheme() != "https"
        || parsed.host_str() != Some("github.com")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.port().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }

    let mut segments = parsed.path_segments()?;
    let owner = segments.next()?;
    let repo = segments.next()?;
    let releases = segments.next()?;
    let download = segments.next()?;
    let tag = segments.next()?;
    let filename = segments.next()?;

    let trusted_repository = (owner == "rustdesk" && repo == "rustdesk")
        || (allow_github_fork && owner == "crashbandicode" && repo == "rustdesk");
    if !trusted_repository
        || releases != "releases"
        || download != "download"
        || tag.is_empty()
        || segments.next().is_some()
        || !is_plain_update_filename(filename)
    {
        return None;
    }

    Some(std::env::temp_dir().join(filename))
}

pub fn get_update_download_file_from_url(url: &str) -> Option<PathBuf> {
    get_update_download_file_from_url_(url, is_github_fork_build())
}

fn is_plain_update_filename(filename: &str) -> bool {
    if filename.is_empty()
        || filename.contains('/')
        || filename.contains('\\')
        || filename.contains(':')
    {
        return false;
    }

    let mut components = Path::new(filename).components();
    matches!(
        components.next(),
        Some(Component::Normal(name)) if name.to_str() == Some(filename)
    ) && components.next().is_none()
}

pub fn get_download_file_from_url(url: &str) -> Option<PathBuf> {
    get_update_download_file_from_url(url)
}

#[cfg(test)]
mod tests {
    use super::{
        get_download_file_from_url, get_update_download_file_from_url_, parse_sha256_manifest,
    };

    #[test]
    fn update_download_file_accepts_expected_github_asset_urls() {
        let file = get_download_file_from_url(
            "https://github.com/rustdesk/rustdesk/releases/download/1.4.0/rustdesk-1.4.0-x86_64.dmg",
        )
        .expect("valid GitHub release asset URL");

        assert_eq!(
            file.file_name().and_then(|name| name.to_str()),
            Some("rustdesk-1.4.0-x86_64.dmg")
        );
    }

    #[test]
    fn fork_build_accepts_only_its_expected_github_asset_repository() {
        let file = get_update_download_file_from_url_(
            "https://github.com/crashbandicode/rustdesk/releases/download/1.4.9-56/rustdesk-1.4.9-56-x64.exe",
            true,
        )
        .expect("valid fork GitHub release asset URL");
        assert_eq!(
            file.file_name().and_then(|name| name.to_str()),
            Some("rustdesk-1.4.9-56-x64.exe")
        );
        assert!(get_update_download_file_from_url_(
            "https://github.com/crashbandicode/other/releases/download/1/rustdesk.exe",
            true,
        )
        .is_none());
        assert!(get_update_download_file_from_url_(
            "https://github.com/crashbandicode/rustdesk/releases/download/1/rustdesk.exe",
            false,
        )
        .is_none());
    }

    #[test]
    fn checksum_manifest_requires_an_exact_asset_name_and_sha256() {
        let manifest = concat!(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  rustdesk-1.4.9-56-x64.exe\n",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  rustdesk-1.4.9-56-aarch64.apk\n",
        );
        assert_eq!(
            parse_sha256_manifest(manifest, "rustdesk-1.4.9-56-x64.exe"),
            Some("a".repeat(64))
        );
        assert_eq!(parse_sha256_manifest(manifest, "rustdesk.exe"), None);
        assert_eq!(parse_sha256_manifest("not-a-hash  rustdesk.exe", "rustdesk.exe"), None);
    }

    #[test]
    fn update_download_file_rejects_untrusted_or_malformed_urls() {
        for url in [
            "http://github.com/rustdesk/rustdesk/releases/download/1/rustdesk.exe",
            "https://example.com/rustdesk.exe",
            "https://github.com/other/project/releases/download/1/rustdesk.exe",
            "https://github.com/rustdesk/rustdesk/releases/download/1/",
            "https://github.com/rustdesk/rustdesk/releases/download/1/nested/rustdesk.exe",
            "https://github.com/rustdesk/rustdesk/releases/download/1/C:rustdesk.exe",
            "https://user@github.com/rustdesk/rustdesk/releases/download/1/rustdesk.exe",
            "https://github.com:443/rustdesk/rustdesk/releases/download/1/rustdesk.exe",
            "https://github.com/rustdesk/rustdesk/releases/download/1/rustdesk.exe?download=1",
            "https://github.com/rustdesk/rustdesk/releases/download/1/rustdesk.exe#download",
            "not a url",
        ] {
            assert!(get_download_file_from_url(url).is_none(), "{url}");
        }
    }
}
