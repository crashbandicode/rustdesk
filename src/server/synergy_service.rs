use hbb_common::{
    anyhow::{bail, Context},
    config::Config,
    log,
    sysinfo::System,
    ResultType,
};
use std::{
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, ErrorKind, Read, Write},
    net::{Ipv4Addr, SocketAddrV4, TcpStream},
    os::windows::io::AsRawHandle,
    path::PathBuf,
    sync::{
        mpsc::{self, Receiver, RecvTimeoutError, Sender},
        OnceLock,
    },
    thread,
    time::{Duration, Instant},
};
use windows::{Win32::Foundation::HANDLE, Win32::System::Pipes::PeekNamedPipe};
use windows_service::{
    service::{Service, ServiceAccess, ServiceState},
    service_manager::{ServiceManager, ServiceManagerAccess},
};

pub const OPTION_PAUSE_SYNERGY: &str = "pause-synergy-on-incoming-sessions";

const SERVICE_NAME: &str = "Synergy Core Daemon";
const CORE_PROCESS_NAME: &str = "synergy-core.exe";
const CORE_PIPE_PATH: &str = r"\\.\pipe\synergy-daemon";
const REST_ADDRESS: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 24803);
const REST_RESTART_PATH: &str = "/v1/controls/restart";
const RESUME_GRACE: Duration = Duration::from_secs(5);
const RETRY_DELAY: Duration = Duration::from_secs(5);
const SERVICE_TIMEOUT: Duration = Duration::from_secs(15);
const SERVICE_POLL_INTERVAL: Duration = Duration::from_millis(100);
const PIPE_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const PIPE_RESPONSE_TIMEOUT: Duration = Duration::from_secs(3);
const REST_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_IPC_RESPONSE_SIZE: usize = 4096;

static WORKER: OnceLock<Sender<Event>> = OnceLock::new();

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Event {
    Initialize,
    /// Count of authenticated remote sessions that are actively viewing
    /// (not backgrounded/minimized on the controller).
    ActiveViewerCount(usize),
    OptionChanged(usize),
    RestoreDeadline,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    None,
    Pause,
    Restore,
    ScheduleRestore,
}

#[derive(Default)]
struct Policy {
    active_viewers: usize,
    restore_scheduled: bool,
}

impl Policy {
    fn transition(&mut self, event: Event, enabled: bool, owns_pause: bool) -> Action {
        match event {
            Event::Initialize => {
                if owns_pause {
                    Action::Restore
                } else {
                    Action::None
                }
            }
            Event::ActiveViewerCount(count) => {
                let previous = self.active_viewers;
                self.active_viewers = count;
                if count > 0 {
                    self.restore_scheduled = false;
                    if enabled {
                        Action::Pause
                    } else if owns_pause {
                        Action::Restore
                    } else {
                        Action::None
                    }
                } else if previous > 0 && owns_pause {
                    if enabled {
                        self.restore_scheduled = true;
                        Action::ScheduleRestore
                    } else {
                        self.restore_scheduled = false;
                        Action::Restore
                    }
                } else if !enabled && owns_pause {
                    self.restore_scheduled = false;
                    Action::Restore
                } else {
                    Action::None
                }
            }
            Event::OptionChanged(count) => {
                self.active_viewers = count;
                if !enabled && owns_pause {
                    self.restore_scheduled = false;
                    Action::Restore
                } else if enabled && count > 0 {
                    self.restore_scheduled = false;
                    Action::Pause
                } else if enabled && owns_pause && !self.restore_scheduled {
                    Action::Restore
                } else {
                    Action::None
                }
            }
            Event::RestoreDeadline => {
                self.restore_scheduled = false;
                if self.active_viewers == 0 && owns_pause {
                    Action::Restore
                } else if self.active_viewers > 0 && enabled {
                    Action::Pause
                } else {
                    Action::None
                }
            }
        }
    }
}

struct Worker {
    policy: Policy,
    restore_deadline: Option<Instant>,
    last_error: Option<String>,
}

impl Worker {
    fn new() -> Self {
        Self {
            policy: Policy::default(),
            restore_deadline: None,
            last_error: None,
        }
    }

    fn run(mut self, receiver: Receiver<Event>) {
        loop {
            let event = match self.restore_deadline {
                Some(deadline) => match receiver
                    .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                {
                    Ok(event) => event,
                    Err(RecvTimeoutError::Timeout) => Event::RestoreDeadline,
                    Err(RecvTimeoutError::Disconnected) => break,
                },
                None => match receiver.recv() {
                    Ok(event) => event,
                    Err(_) => break,
                },
            };
            self.handle(event);
        }
    }

    fn handle(&mut self, event: Event) {
        let enabled = Config::get_bool_option(OPTION_PAUSE_SYNERGY);
        let action = self.policy.transition(event, enabled, owns_pause());
        match action {
            Action::None => {}
            Action::ScheduleRestore => {
                self.restore_deadline = Some(Instant::now() + RESUME_GRACE);
                log::info!(
                    "Synergy restore scheduled in {} seconds",
                    RESUME_GRACE.as_secs()
                );
                record_event("restore_scheduled", "pending", "last remote session ended");
            }
            Action::Pause => {
                self.restore_deadline = None;
                self.record_result("stop", pause_core_if_running());
            }
            Action::Restore => {
                self.restore_deadline = None;
                let result = restore_core_if_owned();
                let retry =
                    result.is_err() && owns_pause() && (!enabled || self.policy.active_viewers == 0);
                self.record_result("start", result);
                if retry {
                    self.policy.restore_scheduled = true;
                    self.restore_deadline = Some(Instant::now() + RETRY_DELAY);
                }
            }
        }
    }

    fn record_result(&mut self, action: &str, result: ResultType<()>) {
        match result {
            Ok(()) => self.last_error = None,
            Err(err) => {
                let detail = err.to_string();
                if self.last_error.as_deref() != Some(&detail) {
                    log::warn!("Failed to {action} Synergy core: {detail}");
                    record_event(action, "error", &detail);
                    self.last_error = Some(detail);
                }
            }
        }
    }
}

pub fn initialize() {
    send(Event::Initialize);
}

pub fn remote_count_changed(count: usize) {
    // Historical name: callers now pass the active-viewer count (remote
    // sessions that are not viewer-backgrounded).
    send(Event::ActiveViewerCount(count));
}

pub fn option_changed() {
    send(Event::OptionChanged(current_remote_count()));
}

fn current_remote_count() -> usize {
    super::AUTHED_CONNS
        .lock()
        .unwrap()
        .iter()
        .filter(|connection| {
            connection.conn_type == super::AuthConnType::Remote && !connection.viewer_backgrounded
        })
        .count()
}

fn send(event: Event) {
    let sender = WORKER.get_or_init(|| {
        let (sender, receiver) = mpsc::channel();
        if let Err(err) = thread::Builder::new()
            .name("synergy-service-control".to_owned())
            .spawn(move || Worker::new().run(receiver))
        {
            log::error!("Failed to start Synergy service control worker: {err}");
        }
        sender
    });
    if let Err(err) = sender.send(event) {
        log::warn!("Failed to notify Synergy service control worker: {err}");
    }
}

fn open_service() -> windows_service::Result<Service> {
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
    manager.open_service(
        SERVICE_NAME,
        ServiceAccess::QUERY_STATUS | ServiceAccess::START | ServiceAccess::PAUSE_CONTINUE,
    )
}

fn pause_core_if_running() -> ResultType<()> {
    let service = open_service().context("open Synergy Core Daemon")?;
    let state = service
        .query_status()
        .context("query Synergy Core Daemon status")?
        .current_state;
    if state != ServiceState::Running {
        return Ok(());
    }
    if !is_core_running() {
        return Ok(());
    }

    let newly_owned = !owns_pause();
    if newly_owned {
        create_ownership_marker()?;
    }
    log::info!("Stopping the Synergy core for an active remote viewer");
    record_event(
        "stop",
        "requested",
        "active remote viewer present; keeping Synergy tray alive",
    );
    if let Err(err) = send_core_ipc_command("stop", "ok") {
        if newly_owned {
            if let Err(marker_err) = clear_ownership_marker() {
                log::warn!("Failed to clear Synergy ownership marker: {marker_err}");
            }
        }
        return Err(err).context("request graceful Synergy core stop");
    }
    if !wait_for_core_state(false) {
        bail!("timed out waiting for the Synergy core process to stop");
    }
    log::info!("Synergy core stopped by RustDesk; daemon and tray remain running");
    record_event("stop", "complete", "core stopped; tray remains running");
    Ok(())
}

fn restore_core_if_owned() -> ResultType<()> {
    if !owns_pause() {
        return Ok(());
    }
    let service = open_service().context("open Synergy Core Daemon")?;
    let mut state = service
        .query_status()
        .context("query Synergy Core Daemon status")?
        .current_state;

    if state == ServiceState::StopPending {
        if !wait_for_state(&service, ServiceState::Stopped)? {
            bail!("timed out waiting for Synergy Core Daemon to finish stopping");
        }
        state = ServiceState::Stopped;
    }

    match state {
        ServiceState::Stopped => {
            log::info!("Starting Synergy Core Daemon before restoring its core process");
            let arguments: [&OsStr; 0] = [];
            service
                .start(&arguments)
                .context("request Synergy Core Daemon start")?;
            if !wait_for_state(&service, ServiceState::Running)? {
                bail!("timed out waiting for Synergy Core Daemon to start");
            }
        }
        ServiceState::StartPending | ServiceState::ContinuePending => {
            if !wait_for_state(&service, ServiceState::Running)? {
                bail!("timed out waiting for Synergy Core Daemon to become ready");
            }
        }
        ServiceState::Paused | ServiceState::PausePending => {
            service.resume().context("resume Synergy Core Daemon")?;
            if !wait_for_state(&service, ServiceState::Running)? {
                bail!("timed out waiting for Synergy Core Daemon to resume");
            }
        }
        ServiceState::Running => {}
        ServiceState::StopPending => {
            bail!("Synergy Core Daemon is still stopping");
        }
    }

    if !is_core_running() {
        log::info!("Restoring the Synergy core after the last remote session");
        record_event(
            "start",
            "requested",
            "no authenticated remote sessions remain",
        );
        request_core_restart()?;
        if !wait_for_core_state(true) {
            bail!("timed out waiting for the Synergy core process to start");
        }
    }

    clear_ownership_marker()?;
    log::info!("Synergy core is running; RustDesk ownership cleared");
    record_event("start", "complete", "core running; tray remained available");
    Ok(())
}

fn send_core_ipc_command(command: &str, expected_response: &str) -> ResultType<()> {
    let mut pipe = open_core_pipe()?;
    send_core_ipc_message(&mut pipe, "hello", "hello")?;
    send_core_ipc_message(&mut pipe, "noop", "ok")?;
    send_core_ipc_message(&mut pipe, command, expected_response)
}

fn open_core_pipe() -> ResultType<File> {
    let deadline = Instant::now() + PIPE_CONNECT_TIMEOUT;
    loop {
        match OpenOptions::new()
            .read(true)
            .write(true)
            .open(CORE_PIPE_PATH)
        {
            Ok(pipe) => return Ok(pipe),
            Err(err) if Instant::now() < deadline => {
                log::debug!("Synergy core pipe is not ready yet: {err}");
                thread::sleep(SERVICE_POLL_INTERVAL);
            }
            Err(err) => return Err(err).context("open Synergy core IPC pipe"),
        }
    }
}

fn send_core_ipc_message(
    pipe: &mut File,
    message: &str,
    expected_response: &str,
) -> ResultType<()> {
    pipe.write_all(message.as_bytes())
        .with_context(|| format!("write Synergy core IPC message '{message}'"))?;
    pipe.write_all(b"\n")
        .with_context(|| format!("terminate Synergy core IPC message '{message}'"))?;
    pipe.flush()
        .with_context(|| format!("flush Synergy core IPC message '{message}'"))?;

    let response = read_core_ipc_line(pipe)?;
    if response != expected_response {
        bail!(
            "unexpected Synergy core IPC response to '{message}': '{response}' (expected '{expected_response}')"
        );
    }
    Ok(())
}

fn read_core_ipc_line(pipe: &mut File) -> ResultType<String> {
    let deadline = Instant::now() + PIPE_RESPONSE_TIMEOUT;
    let mut response = Vec::new();
    loop {
        let mut available = 0u32;
        unsafe {
            PeekNamedPipe(
                HANDLE(pipe.as_raw_handle()),
                None,
                0,
                None,
                Some(&mut available),
                None,
            )
        }
        .context("peek Synergy core IPC response")?;

        if available > 0 {
            let remaining = MAX_IPC_RESPONSE_SIZE.saturating_sub(response.len());
            if remaining == 0 {
                bail!("Synergy core IPC response exceeded {MAX_IPC_RESPONSE_SIZE} bytes");
            }
            let mut buffer = vec![0u8; (available as usize).min(remaining)];
            let read = pipe
                .read(&mut buffer)
                .context("read Synergy core IPC response")?;
            if read == 0 {
                bail!("Synergy closed its core IPC pipe before replying");
            }
            response.extend_from_slice(&buffer[..read]);
            if let Some(newline) = response.iter().position(|byte| *byte == b'\n') {
                response.truncate(newline);
                if response.last() == Some(&b'\r') {
                    response.pop();
                }
                return String::from_utf8(response).context("decode Synergy core IPC response");
            }
        } else if Instant::now() >= deadline {
            bail!("timed out waiting for a Synergy core IPC response");
        } else {
            thread::sleep(SERVICE_POLL_INTERVAL);
        }
    }
}

fn request_core_restart() -> ResultType<()> {
    let mut stream = TcpStream::connect_timeout(&REST_ADDRESS.into(), REST_TIMEOUT)
        .context("connect to the Synergy local control service")?;
    stream
        .set_read_timeout(Some(REST_TIMEOUT))
        .context("set Synergy control response timeout")?;
    stream
        .set_write_timeout(Some(REST_TIMEOUT))
        .context("set Synergy control request timeout")?;

    let request = format!(
        "POST {REST_RESTART_PATH} HTTP/1.1\r\nHost: {REST_ADDRESS}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"
    );
    stream
        .write_all(request.as_bytes())
        .context("send Synergy core restart request")?;
    stream
        .flush()
        .context("flush Synergy core restart request")?;

    let mut status_line = String::new();
    BufReader::new(stream)
        .read_line(&mut status_line)
        .context("read Synergy core restart response")?;
    if !http_status_is_success(&status_line) {
        bail!("Synergy core restart returned an unsuccessful response: {status_line:?}");
    }
    Ok(())
}

fn http_status_is_success(status_line: &str) -> bool {
    status_line
        .split_whitespace()
        .nth(1)
        .and_then(|status| status.parse::<u16>().ok())
        .is_some_and(|status| (200..300).contains(&status))
}

fn is_core_running() -> bool {
    let mut system = System::new();
    system.refresh_processes();
    system.processes().values().any(|process| {
        process
            .name()
            .trim_end_matches('\0')
            .eq_ignore_ascii_case(CORE_PROCESS_NAME)
    })
}

fn wait_for_core_state(running: bool) -> bool {
    let deadline = Instant::now() + SERVICE_TIMEOUT;
    while Instant::now() < deadline {
        if is_core_running() == running {
            return true;
        }
        thread::sleep(SERVICE_POLL_INTERVAL);
    }
    false
}

fn wait_for_state(service: &Service, desired: ServiceState) -> ResultType<bool> {
    let deadline = Instant::now() + SERVICE_TIMEOUT;
    while Instant::now() < deadline {
        let status = service
            .query_status()
            .context("query Synergy Core Daemon status while waiting")?;
        if status.current_state == desired {
            return Ok(true);
        }
        thread::sleep(SERVICE_POLL_INTERVAL);
    }
    Ok(false)
}

fn ownership_marker_path() -> PathBuf {
    let mut path = Config::file();
    path.set_extension("synergy-service-lease");
    path
}

fn owns_pause() -> bool {
    ownership_marker_path().is_file()
}

fn create_ownership_marker() -> ResultType<()> {
    let path = ownership_marker_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("create RustDesk configuration directory")?;
    }
    let mut marker = File::create(&path).context("create Synergy ownership marker")?;
    marker
        .write_all(b"RustDesk paused the Synergy core process\n")
        .context("write Synergy ownership marker")?;
    marker
        .sync_all()
        .context("flush Synergy ownership marker")?;
    Ok(())
}

fn clear_ownership_marker() -> ResultType<()> {
    match fs::remove_file(ownership_marker_path()) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err).context("remove Synergy ownership marker"),
    }
}

fn record_event(action: &str, result: &str, detail: &str) {
    #[cfg(feature = "flutter")]
    {
        let fields = serde_json::json!({
            "service": SERVICE_NAME,
            "action": action,
            "result": result,
            "detail": detail,
        })
        .to_string();
        if let Err(err) = crate::diagnostics::write_event("synergy_service", &fields) {
            log::debug!("Failed to write Synergy diagnostic event: {err}");
        }
    }
    #[cfg(not(feature = "flutter"))]
    {
        let _ = (action, result, detail);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_remote_sessions_request_a_pause() {
        let mut policy = Policy::default();
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(0), true, false),
            Action::None
        );
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(1), true, false),
            Action::Pause
        );
    }

    #[test]
    fn multiple_sessions_restore_only_after_the_last_disconnects() {
        let mut policy = Policy::default();
        policy.transition(Event::ActiveViewerCount(2), true, false);
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(1), true, true),
            Action::Pause
        );
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(0), true, true),
            Action::ScheduleRestore
        );
        assert_eq!(
            policy.transition(Event::RestoreDeadline, true, true),
            Action::Restore
        );
    }

    #[test]
    fn reconnect_cancels_a_scheduled_restore() {
        let mut policy = Policy::default();
        policy.transition(Event::ActiveViewerCount(1), true, false);
        policy.transition(Event::ActiveViewerCount(0), true, true);
        assert!(policy.restore_scheduled);
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(1), true, true),
            Action::Pause
        );
        assert!(!policy.restore_scheduled);
    }

    #[test]
    fn disabling_the_option_restores_an_owned_pause_immediately() {
        let mut policy = Policy::default();
        policy.transition(Event::ActiveViewerCount(1), true, false);
        assert_eq!(
            policy.transition(Event::OptionChanged(1), false, true),
            Action::Restore
        );
    }

    #[test]
    fn startup_recovers_only_an_owned_pause() {
        let mut policy = Policy::default();
        assert_eq!(
            policy.transition(Event::Initialize, true, false),
            Action::None
        );
        assert_eq!(
            policy.transition(Event::Initialize, true, true),
            Action::Restore
        );
    }

    #[test]
    fn backgrounding_the_last_active_viewer_schedules_restore() {
        let mut policy = Policy::default();
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(1), true, false),
            Action::Pause
        );
        // Session remains connected, but the controller is backgrounded.
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(0), true, true),
            Action::ScheduleRestore
        );
        assert!(policy.restore_scheduled);
        assert_eq!(
            policy.transition(Event::RestoreDeadline, true, true),
            Action::Restore
        );
    }

    #[test]
    fn foregrounding_a_backgrounded_viewer_pauses_again() {
        let mut policy = Policy::default();
        policy.transition(Event::ActiveViewerCount(1), true, false);
        policy.transition(Event::ActiveViewerCount(0), true, true);
        assert!(policy.restore_scheduled);
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(1), true, true),
            Action::Pause
        );
        assert!(!policy.restore_scheduled);
    }

    #[test]
    fn one_active_viewer_keeps_synergy_paused_while_another_is_backgrounded() {
        let mut policy = Policy::default();
        policy.transition(Event::ActiveViewerCount(2), true, false);
        assert_eq!(
            policy.transition(Event::ActiveViewerCount(1), true, true),
            Action::Pause
        );
        assert!(!policy.restore_scheduled);
    }

    #[test]
    fn accepts_only_successful_http_statuses() {
        assert!(http_status_is_success("HTTP/1.1 200 OK\r\n"));
        assert!(http_status_is_success("HTTP/1.1 204 No Content\r\n"));
        assert!(!http_status_is_success("HTTP/1.1 404 Not Found\r\n"));
        assert!(!http_status_is_success("not http"));
    }
}
