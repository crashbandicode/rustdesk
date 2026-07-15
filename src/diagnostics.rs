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
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use zip::{write::FileOptions, CompressionMethod, ZipWriter};

pub const DIAGNOSTIC_MODE_OPTION: &str = "diagnostic-mode";

const MAX_BUNDLE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_BUNDLE_FILES: usize = 128;
const MAX_METADATA_BYTES: usize = 32 * 1024;
const MAX_EVENT_BYTES: usize = 8 * 1024;
const MAX_WALK_DEPTH: usize = 8;
const DEFAULT_CAPTURE_WINDOW_MILLIS: u64 = 24 * 60 * 60 * 1000;

static EVENT_WRITER: Mutex<()> = Mutex::new(());

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
    if LocalConfig::get_option(DIAGNOSTIC_MODE_OPTION) != "Y" {
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

    let root = Config::log_path();
    fs::create_dir_all(&root)?;
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
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    serde_json::to_writer(&mut file, &record)?;
    file.write_all(b"\n")?;
    file.flush()?;
    Ok(true)
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

    fs::create_dir_all(log_root)?;
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
        fs::create_dir_all(parent)?;
    }
    let partial = destination.with_extension("zip.part");
    if partial.exists() {
        fs::remove_file(&partial)?;
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
        fs::remove_file(destination)?;
    }
    fs::rename(&partial, destination)?;

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
    let file = File::create(partial)?;
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

    let mut writer = zip.finish()?;
    writer.flush()?;
    writer.get_ref().sync_all()?;
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
    for entry in fs::read_dir(directory)? {
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
}
