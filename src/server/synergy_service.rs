use hbb_common::{
    anyhow::{bail, Context},
    config::Config,
    log, ResultType,
};
use std::{
    ffi::OsStr,
    fs::{self, File},
    io::{ErrorKind, Write},
    path::PathBuf,
    sync::{
        mpsc::{self, Receiver, RecvTimeoutError, Sender},
        OnceLock,
    },
    thread,
    time::{Duration, Instant},
};
use windows_service::{
    service::{Service, ServiceAccess, ServiceState},
    service_manager::{ServiceManager, ServiceManagerAccess},
};

pub const OPTION_PAUSE_SYNERGY: &str = "pause-synergy-on-incoming-sessions";

const SERVICE_NAME: &str = "Synergy Core Daemon";
const RESUME_GRACE: Duration = Duration::from_secs(5);
const RETRY_DELAY: Duration = Duration::from_secs(5);
const SERVICE_TIMEOUT: Duration = Duration::from_secs(15);
const SERVICE_POLL_INTERVAL: Duration = Duration::from_millis(100);

static WORKER: OnceLock<Sender<Event>> = OnceLock::new();

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Event {
    Initialize,
    RemoteCount(usize),
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
    remote_count: usize,
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
            Event::RemoteCount(count) => {
                let previous = self.remote_count;
                self.remote_count = count;
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
                self.remote_count = count;
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
                if self.remote_count == 0 && owns_pause {
                    Action::Restore
                } else if self.remote_count > 0 && enabled {
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
                self.record_result("stop", pause_service_if_running());
            }
            Action::Restore => {
                self.restore_deadline = None;
                let result = restore_service_if_owned();
                let retry =
                    result.is_err() && owns_pause() && (!enabled || self.policy.remote_count == 0);
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
                    log::warn!("Failed to {action} Synergy service: {detail}");
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
    send(Event::RemoteCount(count));
}

pub fn option_changed() {
    send(Event::OptionChanged(current_remote_count()));
}

fn current_remote_count() -> usize {
    super::AUTHED_CONNS
        .lock()
        .unwrap()
        .iter()
        .filter(|connection| connection.conn_type == super::AuthConnType::Remote)
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
        ServiceAccess::QUERY_STATUS
            | ServiceAccess::START
            | ServiceAccess::STOP
            | ServiceAccess::PAUSE_CONTINUE,
    )
}

fn pause_service_if_running() -> ResultType<()> {
    let service = open_service().context("open Synergy Core Daemon")?;
    let state = service
        .query_status()
        .context("query Synergy Core Daemon status")?
        .current_state;
    if state != ServiceState::Running {
        return Ok(());
    }

    let newly_owned = !owns_pause();
    if newly_owned {
        create_ownership_marker()?;
    }
    log::info!("Stopping Synergy Core Daemon for an authenticated remote session");
    record_event("stop", "requested", "authenticated remote session active");
    if let Err(err) = service.stop() {
        if newly_owned {
            if let Err(marker_err) = clear_ownership_marker() {
                log::warn!("Failed to clear Synergy ownership marker: {marker_err}");
            }
        }
        return Err(err).context("request Synergy Core Daemon stop");
    }
    if !wait_for_state(&service, ServiceState::Stopped)? {
        bail!("timed out waiting for Synergy Core Daemon to stop");
    }
    log::info!("Synergy Core Daemon stopped by RustDesk");
    record_event("stop", "complete", "service stopped");
    Ok(())
}

fn restore_service_if_owned() -> ResultType<()> {
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
            log::info!("Starting Synergy Core Daemon after the last remote session");
            record_event(
                "start",
                "requested",
                "no authenticated remote sessions remain",
            );
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

    clear_ownership_marker()?;
    log::info!("Synergy Core Daemon is running; RustDesk ownership cleared");
    record_event("start", "complete", "service running");
    Ok(())
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
        .write_all(b"RustDesk stopped Synergy Core Daemon\n")
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
            policy.transition(Event::RemoteCount(0), true, false),
            Action::None
        );
        assert_eq!(
            policy.transition(Event::RemoteCount(1), true, false),
            Action::Pause
        );
    }

    #[test]
    fn multiple_sessions_restore_only_after_the_last_disconnects() {
        let mut policy = Policy::default();
        policy.transition(Event::RemoteCount(2), true, false);
        assert_eq!(
            policy.transition(Event::RemoteCount(1), true, true),
            Action::Pause
        );
        assert_eq!(
            policy.transition(Event::RemoteCount(0), true, true),
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
        policy.transition(Event::RemoteCount(1), true, false);
        policy.transition(Event::RemoteCount(0), true, true);
        assert!(policy.restore_scheduled);
        assert_eq!(
            policy.transition(Event::RemoteCount(1), true, true),
            Action::Pause
        );
        assert!(!policy.restore_scheduled);
    }

    #[test]
    fn disabling_the_option_restores_an_owned_pause_immediately() {
        let mut policy = Policy::default();
        policy.transition(Event::RemoteCount(1), true, false);
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
}
