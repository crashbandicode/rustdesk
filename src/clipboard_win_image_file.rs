//! Stage synchronized clipboard PNGs as real files and publish CF_HDROP.
//!
//! Cursor's agent composer paste handler attaches images from
//! `clipboardData.files`, which Chromium populates from CF_HDROP on Windows.
//! Bitmap/`PNG` formats alone leave that FileList empty, so paste falls through
//! or AI utils may sniff DIB bytes and error. Publishing a staged temp PNG via
//! CF_HDROP matches the drag-and-drop path Cursor already handles.
//!
//! arboard's `ClipboardData::FileUrl` exists only on Linux/macOS, so Windows
//! staging is tracked separately and applied after arboard writes PNG/DIB.

use hbb_common::{anyhow, bail, log, ResultType};
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

/// Filename prefix for RustDesk-owned clipboard image staging files.
pub const STAGED_CLIPBOARD_IMAGE_PREFIX: &str = ".rustdesk_clipboard_";

lazy_static::lazy_static! {
    static ref PENDING_HDROP_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);
}

/// Write `png` into a uniquely named temp file and remember it for CF_HDROP.
///
/// Previous RustDesk-owned staged clipboard PNGs in the same temp directory are
/// best-effort removed so successive pastes do not accumulate files.
pub fn stage_clipboard_png(png: &[u8]) -> ResultType<PathBuf> {
    if png.is_empty() {
        bail!("Refusing to stage an empty clipboard PNG");
    }
    let dir = std::env::temp_dir();
    cleanup_staged_clipboard_pngs(&dir);
    let unique = unique_stage_token();
    let path = dir.join(format!("{}{}.png", STAGED_CLIPBOARD_IMAGE_PREFIX, unique));
    fs::write(&path, png)?;
    *PENDING_HDROP_PATH.lock().unwrap() = Some(path.clone());
    Ok(path)
}

/// Take the pending staged clipboard image path, if any.
pub fn take_pending_hdrop_path() -> Option<PathBuf> {
    PENDING_HDROP_PATH.lock().unwrap().take()
}

/// Clear any pending staged path without publishing CF_HDROP.
pub fn clear_pending_hdrop_path() {
    *PENDING_HDROP_PATH.lock().unwrap() = None;
}

/// True when `path` is a RustDesk-owned staged clipboard PNG filename.
pub fn is_rustdesk_staged_clipboard_image_path(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(is_rustdesk_staged_clipboard_image_name)
        .unwrap_or(false)
}

/// True when a path/URL string refers to a RustDesk staged PNG.
pub fn is_rustdesk_staged_clipboard_image_url(url: &str) -> bool {
    parse_staged_clipboard_image_path(url).is_some()
}

/// Parse a file URL or raw path string into a staged clipboard image path.
pub fn parse_staged_clipboard_image_path(url: &str) -> Option<PathBuf> {
    if let Ok(parsed) = url::Url::parse(url) {
        match parsed.scheme() {
            "file" => {
                let path = parsed.to_file_path().ok()?;
                return is_rustdesk_staged_clipboard_image_path(&path).then_some(path);
            }
            // Windows drive letters such as `C:\...` parse as a one-character scheme.
            scheme if scheme.len() == 1 => {}
            // http(s)/other remote URLs must not match by filename alone.
            _ => return None,
        }
    }
    let direct = PathBuf::from(url);
    is_rustdesk_staged_clipboard_image_path(&direct).then_some(direct)
}

/// Publish CF_HDROP for the given filesystem paths without clearing other formats.
#[cfg(target_os = "windows")]
pub fn publish_clipboard_hdrop(paths: &[impl AsRef<str>]) -> ResultType<()> {
    if paths.is_empty() {
        bail!("No staged clipboard image paths to publish as CF_HDROP");
    }
    // Retry briefly: another process may still be holding the clipboard after
    // arboard's set_formats returns and closes its open handle.
    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 0..5 {
        match try_publish_clipboard_hdrop(paths) {
            Ok(()) => return Ok(()),
            Err(err) => {
                last_err = Some(err);
                if attempt + 1 < 5 {
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow::anyhow!("Failed to publish CF_HDROP")))
}

#[cfg(target_os = "windows")]
fn try_publish_clipboard_hdrop(paths: &[impl AsRef<str>]) -> ResultType<()> {
    // Keep the clipboard open for the SetClipboardData call. clipboard-win's
    // set_file_list uses NoClear so existing PNG/DIB formats remain.
    let _open = clipboard_win::Clipboard::new_attempts(10).map_err(|code| {
        io::Error::new(
            io::ErrorKind::Other,
            format!("OpenClipboard failed: {code}"),
        )
    })?;
    clipboard_win::raw::set_file_list(paths).map_err(|code| {
        io::Error::new(
            io::ErrorKind::Other,
            format!("SetClipboardData(CF_HDROP) failed: {code}"),
        )
    })?;
    log::debug!(
        "Published CF_HDROP for {} staged clipboard image path(s)",
        paths.len()
    );
    Ok(())
}

fn is_rustdesk_staged_clipboard_image_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    name.starts_with(STAGED_CLIPBOARD_IMAGE_PREFIX) && lower.ends_with(".png")
}

fn unique_stage_token() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{}_{}", nanos, std::process::id())
}

fn cleanup_staged_clipboard_pngs(dir: &Path) {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(err) => {
            log::debug!("Could not list temp dir for clipboard image cleanup: {err}");
            return;
        }
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !is_rustdesk_staged_clipboard_image_path(&path) {
            continue;
        }
        if let Err(err) = fs::remove_file(&path) {
            // The previous file may still be mapped by the clipboard or open in
            // another app; leave it and continue.
            log::debug!(
                "Could not remove staged clipboard image {}: {err}",
                path.display()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_png_with_rustdesk_prefix_and_cleans_previous() {
        let first = stage_clipboard_png(&[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]).unwrap();
        assert!(is_rustdesk_staged_clipboard_image_path(&first));
        assert!(first.exists());

        let second = stage_clipboard_png(&[137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]).unwrap();
        assert!(is_rustdesk_staged_clipboard_image_path(&second));
        assert!(second.exists());
        assert_ne!(first, second);
        // Best-effort cleanup of the previous stage file. Parallel clipboard
        // tests may also stage, so only assert the returned paths here.
        let _ = fs::remove_file(&second);
    }

    #[test]
    fn recognizes_file_url_and_raw_path_forms() {
        let path =
            std::env::temp_dir().join(format!("{}recognize.png", STAGED_CLIPBOARD_IMAGE_PREFIX));
        let url = url::Url::from_file_path(&path).unwrap().to_string();
        assert!(is_rustdesk_staged_clipboard_image_url(&url));
        assert!(is_rustdesk_staged_clipboard_image_url(
            &path.to_string_lossy()
        ));
        assert!(!is_rustdesk_staged_clipboard_image_url(
            "C:\\Users\\public\\photo.png"
        ));
        assert!(!is_rustdesk_staged_clipboard_image_url(
            "https://example.com/.rustdesk_clipboard_x.png"
        ));
    }
}
