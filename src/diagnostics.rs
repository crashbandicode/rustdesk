use hbb_common::{
    anyhow::{anyhow, bail, Context},
    config::{Config, LocalConfig},
    ResultType,
};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufWriter, Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
    sync::{Mutex, Once},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use zip::{write::FileOptions, CompressionMethod, ZipWriter};

pub const DIAGNOSTIC_MODE_OPTION: &str = "diagnostic-mode";
pub const POWER_PROFILING_OPTION: &str = "power-profiling";
pub const POWER_PROFILING_STARTED_AT_OPTION: &str = "power-profiling-started-at";
const POWER_PROFILING_SOURCE_OPTION: &str = "power-profiling-source";

const MAX_BUNDLE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_BUNDLE_FILES: usize = 128;
const MAX_METADATA_BYTES: usize = 32 * 1024;
const MAX_EVENT_BYTES: usize = 8 * 1024;
const MAX_WALK_DEPTH: usize = 8;
const DEFAULT_CAPTURE_WINDOW_MILLIS: u64 = 24 * 60 * 60 * 1000;
const POWER_PROFILE_SAMPLE_INTERVAL: Duration = Duration::from_secs(60);
const POWER_PROFILE_DISABLED_POLL_INTERVAL: Duration = Duration::from_secs(5 * 60);
const MAX_POWER_PROFILE_FILE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_POWER_PROFILE_GENERATIONS: usize = 4;
const MAX_POWER_PROFILE_FILES: usize = 32;
const MAX_POWER_PROFILE_AGE_MILLIS: u64 = 14 * 24 * 60 * 60 * 1000;

static EVENT_WRITER: Mutex<()> = Mutex::new(());
static POWER_PROFILE_WRITER: Mutex<()> = Mutex::new(());
static POWER_PROFILE_DEFAULT: Once = Once::new();
static POWER_PROFILER: Once = Once::new();
static POWER_PROFILE_PRUNE_TICK: AtomicUsize = AtomicUsize::new(0);

#[derive(Debug)]
struct Candidate {
    path: PathBuf,
    relative_name: String,
    modified_millis: u64,
    size: u64,
}

#[derive(Debug)]
struct SelectedFile {
    candidate: Candidate,
    included_bytes: u64,
    tail_only: bool,
}

#[derive(Serialize)]
struct ManifestFile {
    name: String,
    modified_millis: u64,
    original_bytes: u64,
    included_bytes: u64,
    tail_only: bool,
}

#[derive(Serialize)]
struct BundleManifest {
    format_version: u8,
    created_at_utc: String,
    capture_started_millis: u64,
    metadata: Value,
    files: Vec<ManifestFile>,
    omitted_file_count: usize,
    included_uncompressed_bytes: u64,
    privacy_notice: &'static str,
}

#[derive(Debug, Serialize)]
pub struct BundleSummary {
    pub path: String,
    pub file_count: usize,
    pub included_uncompressed_bytes: u64,
    pub omitted_file_count: usize,
}

pub fn log_path() -> String {
    Config::log_path().to_string_lossy().into_owned()
}

pub fn write_event(event: &str, fields_json: &str) -> ResultType<bool> {
    let power_event = event.starts_with("power_profile.");
    if LocalConfig::get_option(DIAGNOSTIC_MODE_OPTION) != "Y"
        && !(power_event && is_power_profiling_enabled())
    {
        return Ok(false);
    }
    if event.is_empty()
        || event.len() > 64
        || !event
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        bail!("Invalid diagnostic event name");
    }
    if fields_json.len() > MAX_EVENT_BYTES {
        bail!("Diagnostic event fields are too large");
    }
    let fields = if fields_json.trim().is_empty() {
        json!({})
    } else {
        let value: Value = serde_json::from_str(fields_json)?;
        if !value.is_object() {
            bail!("Diagnostic event fields must be a JSON object");
        }
        value
    };

    if power_event {
        write_power_profile_record(event, fields)?;
        return Ok(true);
    }

    let root = Config::log_path();
    fs::create_dir_all(&root).with_context(|| {
        format!(
            "Failed to create diagnostic log directory {}",
            root.display()
        )
    })?;
    let path = root.join(format!("support-events-{}.jsonl", std::process::id()));
    let record = json!({
        "timestamp_utc": chrono::Utc::now().to_rfc3339(),
        "event": event,
        "pid": std::process::id(),
        "fields": fields,
    });

    let _guard = EVENT_WRITER
        .lock()
        .map_err(|_| anyhow!("Diagnostic event writer lock is poisoned"))?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("Failed to open diagnostic event log {}", path.display()))?;
    serde_json::to_writer(&mut file, &record)?;
    file.write_all(b"\n")?;
    file.flush()?;
    Ok(true)
}

/// Start one low-overhead sampler per RustDesk process. It uses a five-minute
/// config poll while disabled, switches to one-minute samples when enabled,
/// and emits nothing while off. This lets a long-running service observe a CLI
/// enable without requiring a restart while keeping idle overhead negligible.
pub fn ensure_power_profiler_started() {
    initialize_power_profile_default();
    POWER_PROFILER.call_once(|| {
        let _ = thread::Builder::new()
            .name("power-profiler".to_owned())
            .spawn(power_profile_loop);
    });
}

pub fn is_power_profiling_enabled() -> bool {
    initialize_power_profile_default();
    Config::get_option(POWER_PROFILING_OPTION) == "Y"
}

#[inline]
pub fn converged_power_profiling_enabled(local_enabled: bool, peer_enabled: bool) -> bool {
    local_enabled || peer_enabled
}

/// Persist profiling state locally. Callers use `remote_peer` when a connected
/// endpoint enabled collection; peer IDs are deliberately not persisted in the
/// global config and appear only in the bounded diagnostic record.
pub fn set_power_profiling_enabled(enabled: bool, source: &str, remote_peer: Option<&str>) -> bool {
    ensure_power_profiler_started();
    let was_enabled = is_power_profiling_enabled();
    let needs_started_at =
        enabled && Config::get_option(POWER_PROFILING_STARTED_AT_OPTION).is_empty();
    if enabled == was_enabled && !needs_started_at {
        return enabled;
    }
    if enabled != was_enabled {
        Config::set_option(
            POWER_PROFILING_OPTION.to_owned(),
            if enabled { "Y" } else { "N" }.to_owned(),
        );
    }
    Config::set_option(POWER_PROFILING_SOURCE_OPTION.to_owned(), source.to_owned());
    if needs_started_at {
        Config::set_option(
            POWER_PROFILING_STARTED_AT_OPTION.to_owned(),
            now_millis().to_string(),
        );
    }
    let mut fields = json!({
        "enabled": enabled,
        "previously_enabled": was_enabled,
        "source": source,
    });
    if let Some(peer) = remote_peer.filter(|peer| !peer.is_empty()) {
        fields["peer_id"] = json!(peer);
    }
    if enabled || was_enabled {
        let _ = write_power_profile_record("power_profile.state_changed", fields);
    }
    enabled
}

fn initialize_power_profile_default() {
    POWER_PROFILE_DEFAULT.call_once(|| {
        if Config::get_option(POWER_PROFILING_OPTION).is_empty()
            && option_env!("RUSTDESK_POWER_PROFILING_DEFAULT") == Some("Y")
        {
            Config::set_option(POWER_PROFILING_OPTION.to_owned(), "Y".to_owned());
            Config::set_option(
                POWER_PROFILING_SOURCE_OPTION.to_owned(),
                "profiling-build".to_owned(),
            );
            if Config::get_option(POWER_PROFILING_STARTED_AT_OPTION).is_empty() {
                Config::set_option(
                    POWER_PROFILING_STARTED_AT_OPTION.to_owned(),
                    now_millis().to_string(),
                );
            }
        }
    });
}

fn power_profile_loop() {
    use hbb_common::sysinfo::{Pid, System};

    let pid = Pid::from_u32(std::process::id());
    let mut system = System::new();
    system.refresh_processes();
    loop {
        let enabled = is_power_profiling_enabled();
        thread::sleep(if enabled {
            POWER_PROFILE_SAMPLE_INTERVAL
        } else {
            POWER_PROFILE_DISABLED_POLL_INTERVAL
        });
        if !is_power_profiling_enabled() {
            continue;
        }
        system.refresh_processes();
        let Some(process) = system.process(pid) else {
            continue;
        };
        let disk = process.disk_usage();
        let fields = json!({
            "role": process_role(),
            "cpu_percent": process.cpu_usage(),
            "rss_bytes": process.memory(),
            "virtual_memory_bytes": process.virtual_memory(),
            "read_bytes_interval": disk.read_bytes,
            "written_bytes_interval": disk.written_bytes,
            "read_bytes_total": disk.total_read_bytes,
            "written_bytes_total": disk.total_written_bytes,
            "process_uptime_seconds": process.run_time(),
            "logical_cpu_count": std::thread::available_parallelism().map(|count| count.get()).unwrap_or(1),
            "incoming_session_count": crate::ui_cm_interface::get_clients_length(),
            "profiling_source": Config::get_option(POWER_PROFILING_SOURCE_OPTION),
            "build_fork": option_env!("RUSTDESK_BUILD_FORK").unwrap_or("local"),
            "build_commit": option_env!("RUSTDESK_BUILD_COMMIT").or(option_env!("GITHUB_SHA")).unwrap_or("local"),
            "platform": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
        });
        let _ = write_power_profile_record("power_profile.process_sample", fields);
    }
}

fn process_role() -> &'static str {
    let args: Vec<String> = std::env::args().skip(1).take(4).collect();
    if args.iter().any(|arg| arg == "--service") {
        "service"
    } else if args.iter().any(|arg| arg == "--server") {
        "server"
    } else if args.iter().any(|arg| arg == "--tray") {
        "tray"
    } else if args.iter().any(|arg| arg == "--cm") {
        "connection-manager"
    } else if args.iter().any(|arg| arg == "multi_window") {
        "session-window"
    } else {
        "main"
    }
}

fn write_power_profile_record(event: &str, fields: Value) -> ResultType<()> {
    let root = Config::log_path();
    fs::create_dir_all(&root).with_context(|| {
        format!(
            "Failed to create power profile directory {}",
            root.display()
        )
    })?;
    let _guard = POWER_PROFILE_WRITER
        .lock()
        .map_err(|_| anyhow!("Power profile writer lock is poisoned"))?;
    let path = root.join(format!("power-profile-{}.jsonl", std::process::id()));
    if POWER_PROFILE_PRUNE_TICK.fetch_add(1, Ordering::Relaxed) % 60 == 0 {
        prune_power_profiles(&root, &path);
    }
    rotate_power_profile_if_needed(&path)?;
    let record = json!({
        "timestamp_utc": chrono::Utc::now().to_rfc3339(),
        "event": event,
        "pid": std::process::id(),
        "fields": fields,
    });
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("Failed to open power profile log {}", path.display()))?;
    serde_json::to_writer(&mut file, &record)?;
    file.write_all(b"\n")?;
    file.flush()?;
    Ok(())
}

fn prune_power_profiles(root: &Path, current: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    let mut files = entries
        .filter_map(|entry| {
            let entry = entry.ok()?;
            let path = entry.path();
            let name = path.file_name()?.to_str()?;
            if path == current || !name.starts_with("power-profile-") || !name.ends_with(".jsonl") {
                return None;
            }
            let modified = system_time_millis(entry.metadata().ok()?.modified().ok()?);
            Some((path, modified))
        })
        .collect::<Vec<_>>();
    files.sort_by_key(|(_, modified)| std::cmp::Reverse(*modified));
    let cutoff = now_millis().saturating_sub(MAX_POWER_PROFILE_AGE_MILLIS);
    for (index, (path, modified)) in files.into_iter().enumerate() {
        if modified < cutoff || index >= MAX_POWER_PROFILE_FILES.saturating_sub(1) {
            let _ = fs::remove_file(path);
        }
    }
}

fn rotate_power_profile_if_needed(path: &Path) -> ResultType<()> {
    if path.metadata().map(|metadata| metadata.len()).unwrap_or(0) < MAX_POWER_PROFILE_FILE_BYTES {
        return Ok(());
    }
    for generation in (1..MAX_POWER_PROFILE_GENERATIONS).rev() {
        let source = rotated_power_profile_path(path, generation - 1);
        let destination = rotated_power_profile_path(path, generation);
        if destination.exists() {
            fs::remove_file(&destination)?;
        }
        if source.exists() {
            fs::rename(source, destination)?;
        }
    }
    Ok(())
}

fn rotated_power_profile_path(path: &Path, generation: usize) -> PathBuf {
    if generation == 0 {
        return path.to_owned();
    }
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("power-profile");
    path.with_file_name(format!("{stem}-{generation}.jsonl"))
}

pub fn export_bundle(
    destination: &Path,
    capture_started_millis: u64,
    metadata_json: &str,
) -> ResultType<BundleSummary> {
    export_bundle_from(
        &Config::log_path(),
        destination,
        capture_started_millis,
        metadata_json,
    )
}

fn export_bundle_from(
    log_root: &Path,
    destination: &Path,
    capture_started_millis: u64,
    metadata_json: &str,
) -> ResultType<BundleSummary> {
    if destination
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| !extension.eq_ignore_ascii_case("zip"))
        .unwrap_or(true)
    {
        bail!("Diagnostic bundle destination must end in .zip");
    }
    if metadata_json.len() > MAX_METADATA_BYTES {
        bail!("Diagnostic metadata is too large");
    }
    let metadata = if metadata_json.trim().is_empty() {
        json!({})
    } else {
        let value: Value = serde_json::from_str(metadata_json)?;
        if !value.is_object() {
            bail!("Diagnostic metadata must be a JSON object");
        }
        value
    };

    fs::create_dir_all(log_root).with_context(|| {
        format!(
            "Failed to prepare diagnostic log directory {}",
            log_root.display()
        )
    })?;
    let effective_started_millis = if capture_started_millis == 0 {
        now_millis().saturating_sub(DEFAULT_CAPTURE_WINDOW_MILLIS)
    } else {
        capture_started_millis
    };

    let mut candidates = Vec::new();
    collect_candidates(
        log_root,
        log_root,
        0,
        effective_started_millis,
        &mut candidates,
    )?;
    candidates.sort_by(|left, right| {
        right
            .modified_millis
            .cmp(&left.modified_millis)
            .then_with(|| left.relative_name.cmp(&right.relative_name))
    });

    let candidate_count = candidates.len();
    let mut remaining_bytes = MAX_BUNDLE_BYTES;
    let mut selected = Vec::new();
    for candidate in candidates.into_iter().take(MAX_BUNDLE_FILES) {
        if remaining_bytes == 0 {
            break;
        }
        let included_bytes = candidate.size.min(remaining_bytes);
        let tail_only = included_bytes < candidate.size;
        remaining_bytes = remaining_bytes.saturating_sub(included_bytes);
        selected.push(SelectedFile {
            candidate,
            included_bytes,
            tail_only,
        });
    }
    let included_uncompressed_bytes = selected
        .iter()
        .map(|selected| selected.included_bytes)
        .sum();
    let omitted_file_count = candidate_count.saturating_sub(selected.len());

    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!(
                "Failed to create diagnostic destination directory {}",
                parent.display()
            )
        })?;
    }
    let partial = destination.with_extension("zip.part");
    if partial.exists() {
        fs::remove_file(&partial).with_context(|| {
            format!(
                "Failed to remove stale diagnostic bundle {}",
                partial.display()
            )
        })?;
    }

    let write_result = write_bundle(
        &partial,
        effective_started_millis,
        metadata,
        &selected,
        omitted_file_count,
        included_uncompressed_bytes,
    );
    if let Err(error) = write_result {
        fs::remove_file(&partial).ok();
        return Err(error);
    }
    if destination.exists() {
        fs::remove_file(destination).with_context(|| {
            format!(
                "Failed to replace existing diagnostic bundle {}",
                destination.display()
            )
        })?;
    }
    fs::rename(&partial, destination).with_context(|| {
        format!(
            "Failed to finalize diagnostic bundle {}",
            destination.display()
        )
    })?;

    Ok(BundleSummary {
        path: destination.to_string_lossy().into_owned(),
        file_count: selected.len(),
        included_uncompressed_bytes,
        omitted_file_count,
    })
}

fn write_bundle(
    partial: &Path,
    capture_started_millis: u64,
    metadata: Value,
    selected: &[SelectedFile],
    omitted_file_count: usize,
    included_uncompressed_bytes: u64,
) -> ResultType<()> {
    let file = File::create(partial).with_context(|| {
        format!(
            "Failed to create temporary diagnostic bundle {}",
            partial.display()
        )
    })?;
    let mut zip = ZipWriter::new(BufWriter::new(file));
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .unix_permissions(0o600);

    let manifest = BundleManifest {
        format_version: 1,
        created_at_utc: chrono::Utc::now().to_rfc3339(),
        capture_started_millis,
        metadata,
        files: selected
            .iter()
            .map(|selected| ManifestFile {
                name: selected.candidate.relative_name.clone(),
                modified_millis: selected.candidate.modified_millis,
                original_bytes: selected.candidate.size,
                included_bytes: selected.included_bytes,
                tail_only: selected.tail_only,
            })
            .collect(),
        omitted_file_count,
        included_uncompressed_bytes,
        privacy_notice: "This exporter selects only .log and .jsonl files; it never adds configuration files, recordings, or clipboard payloads. Log text can still contain peer IDs, hostnames, IP addresses, local file paths, and other diagnostic data. Review the bundle before sharing outside trusted support.",
    };

    zip.start_file("manifest.json", options)?;
    serde_json::to_writer_pretty(&mut zip, &manifest)?;
    zip.write_all(b"\n")?;
    zip.start_file("README.txt", options)?;
    zip.write_all(manifest.privacy_notice.as_bytes())?;
    zip.write_all(b"\n")?;

    for selected_file in selected {
        zip.start_file(
            format!("logs/{}", selected_file.candidate.relative_name),
            options,
        )?;
        let mut source = File::open(&selected_file.candidate.path).with_context(|| {
            format!(
                "Failed to open diagnostic log {}",
                selected_file.candidate.path.display()
            )
        })?;
        if selected_file.tail_only {
            source.seek(SeekFrom::End(-(selected_file.included_bytes as i64)))?;
        }
        io::copy(&mut source.take(selected_file.included_bytes), &mut zip)?;
    }

    let mut writer = zip.finish().context("Failed to finish diagnostic ZIP")?;
    writer
        .flush()
        .context("Failed to flush diagnostic ZIP contents")?;
    writer
        .get_ref()
        .sync_all()
        .context("Failed to synchronize diagnostic ZIP contents")?;
    Ok(())
}

fn collect_candidates(
    root: &Path,
    directory: &Path,
    depth: usize,
    capture_started_millis: u64,
    candidates: &mut Vec<Candidate>,
) -> ResultType<()> {
    if depth > MAX_WALK_DEPTH {
        return Ok(());
    }
    let entries = fs::read_dir(directory).with_context(|| {
        format!(
            "Failed to enumerate diagnostic log directory {}",
            directory.display()
        )
    })?;
    for entry in entries {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        let path = entry.path();
        if file_type.is_dir() {
            collect_candidates(root, &path, depth + 1, capture_started_millis, candidates)?;
            continue;
        }
        if !file_type.is_file() || !is_supported_log(&path) {
            continue;
        }

        let metadata = entry.metadata()?;
        let modified_millis = system_time_millis(metadata.modified().unwrap_or(UNIX_EPOCH));
        if modified_millis < capture_started_millis {
            continue;
        }
        let Some(relative_name) = safe_relative_name(root, &path) else {
            continue;
        };
        candidates.push(Candidate {
            path,
            relative_name,
            modified_millis,
            size: metadata.len(),
        });
    }
    Ok(())
}

fn is_supported_log(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| {
            extension.eq_ignore_ascii_case("log") || extension.eq_ignore_ascii_case("jsonl")
        })
        .unwrap_or(false)
}

fn safe_relative_name(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let mut parts = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().into_owned()),
            _ => return None,
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("/"))
    }
}

fn system_time_millis(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}

fn now_millis() -> u64 {
    system_time_millis(SystemTime::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use zip::ZipArchive;

    fn unique_test_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "rustdesk-diagnostics-{name}-{}-{}",
            std::process::id(),
            now_millis()
        ))
    }

    #[test]
    fn bundle_contains_only_supported_recent_logs() {
        let root = unique_test_dir("bundle");
        let logs = root.join("logs");
        fs::create_dir_all(logs.join("nested")).unwrap();
        fs::write(logs.join("current.log"), b"connection ready").unwrap();
        fs::write(logs.join("nested/support-events.jsonl"), b"{}\n").unwrap();
        fs::write(logs.join("RustDesk.toml"), b"password = secret").unwrap();
        let destination = root.join("bundle.zip");

        let summary = export_bundle_from(&logs, &destination, 1, r#"{"version":"test"}"#).unwrap();
        assert_eq!(summary.file_count, 2);

        let file = File::open(&destination).unwrap();
        let mut archive = ZipArchive::new(file).unwrap();
        assert!(archive.by_name("manifest.json").is_ok());
        assert!(archive.by_name("logs/current.log").is_ok());
        assert!(archive.by_name("logs/nested/support-events.jsonl").is_ok());
        assert!(archive.by_name("logs/RustDesk.toml").is_err());

        let mut readme = String::new();
        archive
            .by_name("README.txt")
            .unwrap()
            .read_to_string(&mut readme)
            .unwrap();
        assert!(readme.contains("never adds configuration files"));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn invalid_destination_extension_is_rejected() {
        let root = unique_test_dir("extension");
        fs::create_dir_all(&root).unwrap();
        let error = export_bundle_from(&root, &root.join("bundle.txt"), 1, "{}").unwrap_err();
        assert!(error.to_string().contains("must end in .zip"));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn inaccessible_log_root_reports_the_failed_stage() {
        let root = unique_test_dir("log-root-error");
        fs::create_dir_all(&root).unwrap();
        let log_root = root.join("not-a-directory");
        fs::write(&log_root, b"file blocks directory creation").unwrap();

        let error = export_bundle_from(&log_root, &root.join("bundle.zip"), 1, "{}").unwrap_err();
        assert!(error
            .to_string()
            .contains("Failed to prepare diagnostic log directory"));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn peer_power_profiling_converges_with_or_semantics() {
        assert!(!converged_power_profiling_enabled(false, false));
        assert!(converged_power_profiling_enabled(true, false));
        assert!(converged_power_profiling_enabled(false, true));
        assert!(converged_power_profiling_enabled(true, true));
    }

    #[test]
    fn rotated_power_profiles_remain_jsonl_bundle_candidates() {
        let path = PathBuf::from("power-profile-42.jsonl");
        assert_eq!(
            rotated_power_profile_path(&path, 2),
            PathBuf::from("power-profile-42-2.jsonl")
        );
        assert!(is_supported_log(&rotated_power_profile_path(&path, 2)));
    }

    #[test]
    fn power_profile_retention_is_bounded_and_preserves_current_file() {
        let root = unique_test_dir("power-retention");
        fs::create_dir_all(&root).unwrap();
        let current = root.join("power-profile-current.jsonl");
        fs::write(&current, b"current\n").unwrap();
        for index in 0..40 {
            fs::write(
                root.join(format!("power-profile-old-{index}.jsonl")),
                b"old\n",
            )
            .unwrap();
        }

        prune_power_profiles(&root, &current);

        let remaining = fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("power-profile-")
            })
            .count();
        assert!(current.exists());
        assert!(remaining <= MAX_POWER_PROFILE_FILES);
        fs::remove_dir_all(root).ok();
    }
}
