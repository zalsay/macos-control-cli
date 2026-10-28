//! Shared local command dispatch and request preprocessing.
use crate::{
    args::Command,
    protocol::{Error, Result, Scope},
};
use serde_json::{json, Value};
use std::path::PathBuf;

#[cfg(unix)]
pub fn execute_local(command: Command, scope: Scope) -> Result<Value> {
    use crate::{daemon, runtime::Runtime};
    if let Command::Config(args) = command {
        return crate::config::Store::from_env()?.execute(&args, std::io::stdin().lock());
    }
    if !cfg!(target_os = "macos") {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "桌面自动化仅支持 macOS 14 及以上版本",
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
        Command::Host(_) | Command::Remote { .. } => {
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
    use crate::{
        daemon,
        runtime::{export_image, Runtime},
    };
    if !cfg!(target_os = "macos") {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "桌面自动化仅支持 macOS 14 及以上版本",
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
        if request["action"] == "status" {
            return daemon::status(&runtime);
        }
        daemon::start(&runtime)?;
    }
    if request["action"] == "click-target"
        || request["action"] == "chrome-start"
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
/// `operation` is the validated envelope sequence encoded as a nonzero,
/// canonical decimal u64, monotonically increasing for the current owner.
#[cfg(unix)]
pub fn execute_remote_request(
    request: Value,
    scope: Scope,
    owner: &str,
    operation: &str,
) -> Result<Value> {
    if !cfg!(target_os = "macos") {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "桌面自动化仅支持 macOS 14 及以上版本",
        ));
    }
    let runtime = crate::runtime::Runtime::from_env_for_scope(scope)?;
    if crate::daemon::remote_read_only(&request) {
        return crate::daemon::remote_read(&runtime, owner, operation, request);
    }
    crate::daemon::remote_reserve(&runtime, owner, operation)?;
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
        "桌面自动化仅支持 macOS 14 及以上版本",
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
        "桌面自动化仅支持 macOS 14 及以上版本",
    ))
}
#[cfg(not(unix))]
pub fn execute_request(_: Value, _: Option<PathBuf>, _: Scope) -> Result<Value> {
    Err(Error::new(
        "UNSUPPORTED_PLATFORM",
        "桌面自动化仅支持 macOS 14 及以上版本",
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
