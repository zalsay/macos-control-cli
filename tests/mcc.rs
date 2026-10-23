#![cfg(target_os = "macos")]
use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Output};

struct Environment(PathBuf);
impl Environment {
    fn new() -> Self {
        Self(PathBuf::from(format!(
            "/tmp/mcc-test-{}",
            copis_chrome::protocol::random_id().unwrap()
        )))
    }
    fn raw(&self, executable: &str, args: &[&str]) -> Output {
        Command::new(executable)
            .args(args)
            .env("COPIS_DESKTOP_RUNTIME_DIR", &self.0)
            .env(
                "COPIS_DESKTOP_HELPER",
                format!(
                    "{}/tests/fixtures/fake-helper.sh",
                    env!("CARGO_MANIFEST_DIR")
                ),
            )
            .output()
            .unwrap()
    }
    fn call(&self, executable: &str, args: &[&str]) -> Value {
        let output = self.raw(executable, args);
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert!(output.status.success(), "{value}");
        assert_eq!(value["scope"], "desktop");
        value
    }
}
impl Drop for Environment {
    fn drop(&mut self) {
        if self.0.exists() {
            let _ = self.raw(env!("CARGO_BIN_EXE_desktop-control"), &["daemon", "stop"]);
            for _ in 0..60 {
                if !self.0.join("daemon.sock").exists() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            if !self.0.join("daemon.sock").exists() {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }
}
fn mcc() -> &'static str {
    option_env!("CARGO_BIN_EXE_mcc").expect("必须构建默认 mcc 入口")
}
#[test]
fn given_mcc_when_help_or_version_requested_then_no_runtime_or_desktop_side_effects() {
    let env = Environment::new();
    let output = env.raw(mcc(), &["--help"]);
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.starts_with("mcc —"));
    for command in [
        "mcc permissions",
        "mcc apps",
        "mcc windows",
        "mcc observe",
        "mcc click",
        "mcc daemon stop",
    ] {
        assert!(help.contains(command), "帮助缺少 {command}");
    }
    assert!(help.contains("frameId") && help.contains("原像素"));
    assert!(help.contains("~/.copis/desktop-control-cli"));
    assert!(!help.contains("~/.copis/mcc-cli"));
    assert!(!env.0.exists());
    let version = env.call(mcc(), &["--version"]);
    assert_eq!(version["version"], env!("CARGO_PKG_VERSION"));
    assert!(!env.0.exists());
}
#[test]
fn given_mcc_and_legacy_desktop_entry_when_sharing_runtime_then_mode_and_connection_are_compatible()
{
    let env = Environment::new();
    let connection = env.call(mcc(), &["connect", "--window", "42"]);
    let id = connection["connectionId"].as_str().unwrap();
    assert_eq!(
        env.call(env!("CARGO_BIN_EXE_desktop-control"), &["status"])["connected"],
        true
    );
    env.call(
        env!("CARGO_BIN_EXE_desktop-control"),
        &["disconnect", "--connection", id],
    );
    assert_eq!(env.call(mcc(), &["status"])["connected"], false);
    env.call(mcc(), &["daemon", "stop"]);
}
