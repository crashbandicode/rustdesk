use hbb_common::{
    config::Config,
    log,
    message_proto::{key_event, Clipboard, ClipboardFormat, ControlKey, KeyEvent, KeyboardMode},
};
use rdev::{EventType, Key};
use std::{ffi::OsStr, path::Path};
use winapi::{
    shared::minwindef::DWORD,
    um::winuser::{
        GetAsyncKeyState, GetClassNameW, GetForegroundWindow, GetWindowThreadProcessId,
        VK_LCONTROL, VK_LMENU, VK_LWIN, VK_RCONTROL, VK_RMENU, VK_RWIN,
    },
};

pub const OPTION_TERMINAL_IMAGE_PASTE: &str = "terminal-image-paste";

#[derive(Debug)]
struct ForegroundWindowIdentity {
    process_name: String,
    class_name: String,
}

/// Windows Terminal consumes a simulated Ctrl+V itself. For an image-only
/// clipboard that produces no terminal input, so Codex never sees the shortcut
/// it uses to attach the image. Codex also accepts Alt+V specifically for this
/// terminal-host limitation; translate only that narrow case and let Codex own
/// its existing temp-PNG staging and attachment behavior.
pub fn try_handle(evt: &KeyEvent) -> bool {
    if !is_enabled() || !is_v_key_down(evt) {
        return false;
    }

    crate::platform::windows::try_change_desktop();
    let left_ctrl_down = async_key_down(VK_LCONTROL);
    let right_ctrl_down = async_key_down(VK_RCONTROL);
    if !event_has_control(evt) && !left_ctrl_down && !right_ctrl_down {
        return false;
    }
    if event_has_alt_or_meta(evt)
        || async_key_down(VK_LMENU)
        || async_key_down(VK_RMENU)
        || async_key_down(VK_LWIN)
        || async_key_down(VK_RWIN)
    {
        return false;
    }
    if !crate::clipboard::clipboard_has_image_only() {
        return false;
    }

    let Some(identity) = foreground_window_identity() else {
        log::debug!("Could not identify foreground window for terminal image paste");
        return false;
    };
    if !is_terminal_window(&identity.process_name, &identity.class_name) {
        return false;
    }

    let delivered = deliver_alt_v(left_ctrl_down, right_ctrl_down);
    if delivered {
        log::info!(
            "Translated image Ctrl+V to Alt+V for terminal process '{}' (class '{}')",
            identity.process_name,
            identity.class_name
        );
    } else {
        log::warn!(
            "Failed to deliver terminal image paste for process '{}' (class '{}')",
            identity.process_name,
            identity.class_name
        );
    }
    delivered
}

pub fn is_enabled() -> bool {
    enabled_from_option(&Config::get_option(OPTION_TERMINAL_IMAGE_PASTE))
}

fn enabled_from_option(value: &str) -> bool {
    value != "N"
}

pub fn should_apply_clipboard_synchronously(clipboards: &[Clipboard]) -> bool {
    is_enabled() && clipboards_contain_image(clipboards)
}

fn clipboards_contain_image(clipboards: &[Clipboard]) -> bool {
    clipboards.iter().any(|clipboard| {
        matches!(
            clipboard.format.enum_value(),
            Ok(ClipboardFormat::ImageRgba)
                | Ok(ClipboardFormat::ImagePng)
                | Ok(ClipboardFormat::ImageSvg)
        )
    })
}

fn is_v_key_down(evt: &KeyEvent) -> bool {
    if !evt.down {
        return false;
    }
    match evt.mode.enum_value_or(KeyboardMode::Legacy) {
        KeyboardMode::Map => crate::keyboard::keycode_to_rdev_key(evt.chr()) == Key::KeyV,
        KeyboardMode::Translate => match evt.union {
            Some(key_event::Union::Chr(code)) => {
                crate::keyboard::keycode_to_rdev_key(code & 0x0000_FFFF) == Key::KeyV
                    || char_is_v(code)
            }
            _ => false,
        },
        _ => match evt.union {
            Some(key_event::Union::Chr(code)) => char_is_v(code),
            _ => false,
        },
    }
}

fn char_is_v(code: u32) -> bool {
    char::from_u32(code).is_some_and(|value| value.eq_ignore_ascii_case(&'v'))
}

fn event_has_control(evt: &KeyEvent) -> bool {
    evt.modifiers.iter().any(|modifier| {
        matches!(
            modifier.enum_value_or_default(),
            ControlKey::Control | ControlKey::RControl
        )
    })
}

fn event_has_alt_or_meta(evt: &KeyEvent) -> bool {
    evt.modifiers.iter().any(|modifier| {
        matches!(
            modifier.enum_value_or_default(),
            ControlKey::Alt | ControlKey::RAlt | ControlKey::Meta | ControlKey::RWin
        )
    })
}

fn async_key_down(key: i32) -> bool {
    unsafe { GetAsyncKeyState(key) < 0 }
}

fn foreground_window_identity() -> Option<ForegroundWindowIdentity> {
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.is_null() {
            return None;
        }

        let mut class_name = [0u16; 256];
        let class_len = GetClassNameW(hwnd, class_name.as_mut_ptr(), class_name.len() as i32);
        let class_name = if class_len > 0 {
            String::from_utf16_lossy(&class_name[..class_len as usize]).to_ascii_lowercase()
        } else {
            String::new()
        };

        let mut process_id: DWORD = 0;
        GetWindowThreadProcessId(hwnd, &mut process_id);
        let process_name = if process_id == 0 {
            String::new()
        } else {
            crate::platform::windows::get_process_executable_path(process_id)
                .ok()
                .and_then(|path| process_file_name(&path))
                .unwrap_or_default()
        };

        Some(ForegroundWindowIdentity {
            process_name,
            class_name,
        })
    }
}

fn process_file_name(path: &Path) -> Option<String> {
    path.file_name()
        .and_then(OsStr::to_str)
        .map(str::to_ascii_lowercase)
}

fn is_terminal_window(process_name: &str, class_name: &str) -> bool {
    matches!(
        process_name,
        "windowsterminal.exe"
            | "openconsole.exe"
            | "conhost.exe"
            | "pwsh.exe"
            | "powershell.exe"
            | "wezterm-gui.exe"
            | "alacritty.exe"
            | "kitty.exe"
    ) || matches!(
        class_name,
        "cascadia_hosting_window_class" | "consolewindowclass"
    )
}

fn simulate(event_type: EventType) -> bool {
    if let Err(err) = rdev::simulate(&event_type) {
        log::debug!("Failed to simulate terminal image paste event {event_type:?}: {err:?}");
        return false;
    }
    true
}

fn deliver_alt_v(left_ctrl_down: bool, right_ctrl_down: bool) -> bool {
    if left_ctrl_down {
        let _ = simulate(EventType::KeyRelease(Key::ControlLeft));
    }
    if right_ctrl_down {
        let _ = simulate(EventType::KeyRelease(Key::ControlRight));
    }

    let alt_down = simulate(EventType::KeyPress(Key::Alt));
    let v_down = alt_down && simulate(EventType::KeyPress(Key::KeyV));
    if v_down {
        let _ = simulate(EventType::KeyRelease(Key::KeyV));
    }
    if alt_down {
        let _ = simulate(EventType::KeyRelease(Key::Alt));
    }

    // Preserve the controller's held-modifier state. Its eventual Ctrl key-up
    // event will release the restored key normally.
    if left_ctrl_down {
        let _ = simulate(EventType::KeyPress(Key::ControlLeft));
    }
    if right_ctrl_down {
        let _ = simulate(EventType::KeyPress(Key::ControlRight));
    }
    v_down
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::protobuf::EnumOrUnknown;

    fn legacy_v(down: bool, modifiers: &[ControlKey]) -> KeyEvent {
        let mut evt = KeyEvent {
            mode: KeyboardMode::Legacy.into(),
            down,
            modifiers: modifiers.iter().copied().map(EnumOrUnknown::new).collect(),
            ..Default::default()
        };
        evt.set_chr('v' as u32);
        evt
    }

    #[test]
    fn recognizes_only_v_key_down() {
        assert!(is_v_key_down(&legacy_v(true, &[ControlKey::Control])));
        assert!(!is_v_key_down(&legacy_v(false, &[ControlKey::Control])));

        let mut other = legacy_v(true, &[ControlKey::Control]);
        other.set_chr('c' as u32);
        assert!(!is_v_key_down(&other));

        let v_scan_code = rdev::win_scancode_from_key(Key::KeyV).unwrap_or_default();
        for mode in [KeyboardMode::Map, KeyboardMode::Translate] {
            let mut evt = KeyEvent {
                mode: mode.into(),
                down: true,
                ..Default::default()
            };
            evt.set_chr(v_scan_code);
            assert!(is_v_key_down(&evt), "failed to recognize {mode:?}");
        }
    }

    #[test]
    fn recognizes_control_without_alt_or_meta() {
        let ctrl = legacy_v(true, &[ControlKey::Control]);
        assert!(event_has_control(&ctrl));
        assert!(!event_has_alt_or_meta(&ctrl));

        let ctrl_alt = legacy_v(true, &[ControlKey::Control, ControlKey::Alt]);
        assert!(event_has_control(&ctrl_alt));
        assert!(event_has_alt_or_meta(&ctrl_alt));
    }

    #[test]
    fn limits_translation_to_terminal_hosts() {
        assert!(is_terminal_window("windowsterminal.exe", ""));
        assert!(is_terminal_window("", "cascadia_hosting_window_class"));
        assert!(is_terminal_window("conhost.exe", "consolewindowclass"));
        assert!(!is_terminal_window("chrome.exe", "chrome_widgetwin_1"));
        assert!(!is_terminal_window("code.exe", "chrome_widgetwin_1"));
    }

    #[test]
    fn recognizes_image_clipboard_payloads() {
        let image = Clipboard {
            format: ClipboardFormat::ImagePng.into(),
            content: vec![1, 2, 3].into(),
            ..Default::default()
        };
        let text = Clipboard {
            format: ClipboardFormat::Text.into(),
            content: b"hello".to_vec().into(),
            ..Default::default()
        };

        assert!(clipboards_contain_image(&[image]));
        assert!(!clipboards_contain_image(&[text]));
    }

    #[test]
    fn enables_terminal_image_paste_by_default() {
        assert!(enabled_from_option(""));
        assert!(enabled_from_option("Y"));
        assert!(!enabled_from_option("N"));
    }
}
