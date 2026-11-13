//! Shared local command dispatch and request preprocessing.
use crate::{
    args::Command,
    protocol::{Error, Result, Scope},
};
use serde_json::{json, Value};
use std::path::PathBuf;

/// Native Linux shares the X11 backend, but never inherits Docker handoff policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LinuxDesktopMode {
    Docker,
    Host,
}
impl LinuxDesktopMode {
    fn select(docker: bool, host: bool) -> Result<Option<Self>> {
        match (docker, host) {
            (true, false) => Ok(Some(Self::Docker)),
            (false, true) => Ok(Some(Self::Host)),
            (false, false) => Ok(None),
            (true, true) => Err(Error::invalid(
                "MCC_DOCKER 与 MCC_LINUX_DESKTOP 不能同时启用",
            )),
        }
    }
    fn validate_session(
        self,
        uid: u32,
        session: Option<&str>,
        display: Option<&str>,
    ) -> Result<()> {
        if uid == 0 {
            return Err(Error::new(
                "UNSUPPORTED_PLATFORM",
                "Linux 桌面必须由当前登录的普通用户运行，不能使用 sudo/root",
            ));
        }
        if self == Self::Host && session != Some("x11") {
            return Err(Error::new("SESSION_UNSUPPORTED", "宿主模式仅支持 Xorg；请在 Ubuntu on Xorg 登录会话的终端运行，Wayland/XWayland 不受支持"));
        }
        let display = display.unwrap_or("");
        let local = display
            .strip_prefix(':')
            .or_else(|| display.strip_prefix("unix:"));
        if !local.is_some_and(|value| {
            !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        }) {
            return Err(Error::new(
                "X11_UNVERIFIED",
                "DISPLAY 必须为当前用户的本地 X11 显示，例如 :0；不支持 SSH X11 转发",
            ));
        }
        Ok(())
    }
}
fn configured_linux_mode(scope: Scope) -> Result<Option<LinuxDesktopMode>> {
    if !cfg!(target_os = "linux") || scope != Scope::Desktop {
        return Ok(None);
    }
    LinuxDesktopMode::select(
        std::env::var_os("MCC_DOCKER").as_deref() == Some(std::ffi::OsStr::new("1")),
        std::env::var_os("MCC_LINUX_DESKTOP").as_deref() == Some(std::ffi::OsStr::new("1")),
    )
}
pub fn container_desktop_enabled(scope: Scope) -> bool {
    configured_linux_mode(scope).ok().flatten() == Some(LinuxDesktopMode::Docker)
}
pub fn host_desktop_enabled(scope: Scope) -> bool {
    configured_linux_mode(scope).ok().flatten() == Some(LinuxDesktopMode::Host)
}
pub fn linux_desktop_enabled(scope: Scope) -> bool {
    configured_linux_mode(scope).ok().flatten().is_some()
}
#[cfg(target_os = "linux")]
pub(crate) fn validate_linux_environment() -> Result<LinuxDesktopMode> {
    let mode = configured_linux_mode(Scope::Desktop)?.ok_or_else(|| Error::new("UNSUPPORTED_PLATFORM", "请通过 Ubuntu X11 安装入口运行，或显式设置 MCC_LINUX_DESKTOP=1；Docker 使用 MCC_DOCKER=1"))?;
    mode.validate_session(
        unsafe { libc::geteuid() },
        std::env::var("XDG_SESSION_TYPE").ok().as_deref(),
        std::env::var("DISPLAY").ok().as_deref(),
    )?;
    Ok(mode)
}
fn local_execution_enabled(scope: Scope) -> bool {
    cfg!(target_os = "macos") || linux_desktop_enabled(scope)
}

#[cfg(unix)]
pub fn execute_local(command: Command, scope: Scope) -> Result<Value> {
    use crate::{daemon, runtime::Runtime};
    if let Command::Config(args) = command {
        return crate::config::Store::from_env()?.execute(&args, std::io::stdin().lock());
    }
    #[cfg(target_os = "linux")]
    if scope == Scope::Desktop {
        validate_linux_environment()?;
    }
    if !local_execution_enabled(scope) {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "桌面自动化支持 macOS 14+、Ubuntu Xorg 宿主桌面及显式 Docker 桌面",
        ));
    }
    match command {
        Command::Daemon(subcommand) => {
            let runtime = Runtime::from_env_for_scope(scope)?;
            match subcommand.as_str() {
                "start" => daemon::start(&runtime),
                "stop" => daemon::stop(&runtime),
                "status" => daemon::status(&runtime),
                "run" => daemon::run(&runtime),
                _ => unreachable!(),
            }
        }
        Command::Request { request, output } => execute_request(request, output, scope),
        Command::FilePut { .. } | Command::Host(_) | Command::Remote { .. } => {
            Err(Error::invalid("远程命令只能由 CLI 前端分派"))
        }
        Command::Help | Command::Version | Command::Config(_) => unreachable!(),
    }
}

#[cfg(unix)]
pub fn execute_request(request: Value, output: Option<PathBuf>, scope: Scope) -> Result<Value> {
    execute_request_inner(request, output, scope, None)
}
#[cfg(unix)]
fn execute_request_inner(
    mut request: Value,
    output: Option<PathBuf>,
    scope: Scope,
    remote: Option<(&str, &str)>,
) -> Result<Value> {
    if request.get("fileId").is_some() {
        return Err(Error::invalid(
            "--file-id 仅用于远端 Host 文件；本地选择请使用 --path",
        ));
    }
    use crate::{
        daemon,
        runtime::{export_image, Runtime},
    };
    #[cfg(target_os = "linux")]
    if scope == Scope::Desktop {
        validate_linux_environment()?;
    }
    if !local_execution_enabled(scope) {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "桌面自动化支持 macOS 14+、Ubuntu Xorg 宿主桌面及显式 Docker 桌面",
        ));
    }
    let runtime = Runtime::from_env_for_scope(scope)?;
    if request["action"] == "click-target" {
        let model = crate::config::Store::from_env()?
            .resolve_model(request.get("jevKey").and_then(Value::as_str))?;
        request["jevKey"] = json!(model.api_key);
        request["jevUrl"] = json!(model.url);
        request["jevModel"] = json!(model.model);
        request["jevProtocol"] = json!(crate::jev::DECISION_PROTOCOL);
    }
    if request["action"] == "chrome-start" {
        apply_chrome_start_settings(&mut request, &crate::config::Store::from_env()?)?;
    }
    if remote.is_none() {
        if request["action"] == "control" {
            // Interrupt the existing helper without Service's startup/status
            // preflight, which is busy while an input holds its mutex.
            return daemon::call(&runtime, request);
        }
        if request["action"] == "status" {
            return daemon::status(&runtime);
        }
        daemon::start(&runtime)?;
    }
    if request["action"] == "click-target"
        || request["action"] == "chrome-start"
        || request["action"] == "firefox-start"
        || request["action"] == "permissions"
    {
        // Reuse the version gate for new startup protocol, and authenticate
        // dynamic endpoint support before any per-call key is sent.
        let status = daemon::call(&runtime, json!({"action":"status"}))?;
        let incompatible_decisions = request["action"] == "click-target"
            && (status["jev"]["protocol"] != crate::jev::DECISION_PROTOCOL
                || status["jev"]["dynamicEndpoint"] != true);
        if status["version"] != env!("CARGO_PKG_VERSION") || incompatible_decisions {
            return Err(Error::new("DAEMON_UPGRADE_REQUIRED", "现有 daemon 版本或动态 Decisions 配置契约不匹配；尚未发送密钥、请求授权或创建窗口，请仅结束自己持有的旧 daemon 后重新连接"));
        }
    }
    let mut result = match remote {
        Some((owner, operation)) => daemon::remote_call(&runtime, owner, operation, request)?,
        None => daemon::call(&runtime, request)?,
    };
    if let Some(output) = output {
        let source = result["imagePath"]
            .as_str()
            .ok_or_else(|| Error::new("PROTOCOL_ERROR", "观察结果缺少截图路径"))?;
        result["imagePath"] = json!(export_image(std::path::Path::new(source), &output)?);
    }
    Ok(result)
}

/// Execute an already-authorized Host request without starting a daemon.
/// `operation` is the trusted Host operation sequence encoded as a nonzero,
/// canonical decimal u64, monotonically increasing for the current owner.
#[cfg(unix)]
pub fn execute_remote_request(
    request: Value,
    scope: Scope,
    owner: &str,
    operation: &str,
) -> Result<Value> {
    #[cfg(target_os = "linux")]
    if scope == Scope::Desktop {
        validate_linux_environment()?;
    }
    if !local_execution_enabled(scope) {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "桌面自动化支持 macOS 14+、Ubuntu Xorg 宿主桌面及显式 Docker 桌面",
        ));
    }
    let runtime = crate::runtime::Runtime::from_env_for_scope(scope)?;
    if crate::daemon::remote_read_only(&request) {
        return crate::daemon::remote_read(&runtime, owner, operation, request);
    }
    crate::daemon::remote_reserve(&runtime, owner, operation, &request)?;
    let result = execute_request_inner(request, None, scope, Some((owner, operation)));
    // A dispatched operation has already cleared its reservation; a preprocessing
    // failure leaves only the matching not-yet-running reservation to abandon.
    let _ = crate::daemon::remote_abandon(&runtime, owner, operation);
    result
}
#[cfg(not(unix))]
pub fn execute_remote_request(_: Value, _: Scope, _: &str, _: &str) -> Result<Value> {
    Err(Error::new(
        "UNSUPPORTED_PLATFORM",
        "桌面自动化支持 macOS 14+、Ubuntu Xorg 宿主桌面及显式 Docker 桌面",
    ))
}

fn apply_chrome_start_settings(request: &mut Value, store: &crate::config::Store) -> Result<()> {
    let (max_width_px, default_profile) = store.chrome_start_settings()?;
    request["maxWidthPx"] = json!(max_width_px);
    if request.get("profile").is_none() {
        if let Some(profile) = default_profile {
            request["profile"] = json!(profile);
        }
    }
    Ok(())
}

#[cfg(not(unix))]
pub fn execute_local(_: Command, _: Scope) -> Result<Value> {
    Err(Error::new(
        "UNSUPPORTED_PLATFORM",
        "桌面自动化支持 macOS 14+、Ubuntu Xorg 宿主桌面及显式 Docker 桌面",
    ))
}
#[cfg(not(unix))]
pub fn execute_request(_: Value, _: Option<PathBuf>, _: Scope) -> Result<Value> {
    Err(Error::new(
        "UNSUPPORTED_PLATFORM",
        "桌面自动化支持 macOS 14+、Ubuntu Xorg 宿主桌面及显式 Docker 桌面",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Store;

    struct ConfigFixture(std::path::PathBuf);
    impl ConfigFixture {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                "mcc-main-profile-{}",
                crate::protocol::random_id().unwrap()
            )))
        }

        fn store(&self) -> Store {
            Store::new(self.0.clone())
        }
    }
    impl Drop for ConfigFixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn explicit_profile_wins_and_persisted_profile_is_used_only_when_absent() {
        let fixture = ConfigFixture::new();
        let store = fixture.store();
        store
            .execute(
                &["chrome".into(), "--profile".into(), "Saved".into()],
                std::io::empty(),
            )
            .unwrap();
        store
            .execute(
                &["window".into(), "--max-width".into(), "1400".into()],
                std::io::empty(),
            )
            .unwrap();

        let mut explicit = json!({"action":"chrome-start","profile":"CLI"});
        apply_chrome_start_settings(&mut explicit, &store).unwrap();
        assert_eq!(explicit["profile"], "CLI");
        assert_eq!(explicit["maxWidthPx"], 1400);

        let mut defaulted = json!({"action":"chrome-start"});
        apply_chrome_start_settings(&mut defaulted, &store).unwrap();
        assert_eq!(defaulted["profile"], "Saved");
        assert_eq!(defaulted["maxWidthPx"], 1400);

        store
            .execute(
                &["chrome".into(), "--clear-profile".into()],
                std::io::empty(),
            )
            .unwrap();
        let mut no_default = json!({"action":"chrome-start"});
        apply_chrome_start_settings(&mut no_default, &store).unwrap();
        assert_eq!(
            no_default,
            json!({"action":"chrome-start","maxWidthPx":1400})
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn remote_dispatch_never_starts_missing_daemon_or_creates_runtime() {
        let root = std::env::temp_dir().join(format!(
            "mcc-missing-daemon-{}",
            crate::protocol::random_id().unwrap()
        ));
        let previous = std::env::var_os("COPIS_CHROME_RUNTIME_DIR");
        std::env::set_var("COPIS_CHROME_RUNTIME_DIR", &root);
        let result = execute_remote_request(
            json!({"action":"status"}),
            Scope::Chrome,
            "owner",
            "operation",
        );
        match previous {
            Some(value) => std::env::set_var("COPIS_CHROME_RUNTIME_DIR", value),
            None => std::env::remove_var("COPIS_CHROME_RUNTIME_DIR"),
        }
        assert!(result.is_err());
        assert_ne!(result.unwrap_err().code, "NOT_IMPLEMENTED");
        assert!(!root.exists());
    }
}

#[cfg(test)]
mod ubuntu_x11_tests {
    use super::*;
    #[test]
    fn modes_and_shared_session_validation_are_separate() {
        assert_eq!(
            LinuxDesktopMode::select(true, false).unwrap(),
            Some(LinuxDesktopMode::Docker)
        );
        assert_eq!(
            LinuxDesktopMode::select(false, true).unwrap(),
            Some(LinuxDesktopMode::Host)
        );
        assert!(LinuxDesktopMode::select(true, true).is_err());
        let host = LinuxDesktopMode::Host;
        assert!(host.validate_session(1000, Some("x11"), Some(":0")).is_ok());
        assert!(host
            .validate_session(1000, Some("x11"), Some("unix:1.0"))
            .is_ok());
        for session in [Some("wayland"), None] {
            assert_eq!(
                host.validate_session(1000, session, Some(":0"))
                    .unwrap_err()
                    .code,
                "SESSION_UNSUPPORTED"
            );
        }
        assert!(host.validate_session(0, Some("x11"), Some(":0")).is_err());
        for display in [None, Some("localhost:10.0"), Some(":"), Some("host:0")] {
            assert!(host.validate_session(1000, Some("x11"), display).is_err());
        }
        assert!(LinuxDesktopMode::Docker
            .validate_session(1000, None, Some(":99"))
            .is_ok());
    }
}
