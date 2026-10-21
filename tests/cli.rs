#![cfg(target_os = "macos")]
use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

struct Environment {
    root: PathBuf,
}
impl Environment {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/tmp/copis-cli-test-{}",
            copis_chrome::protocol::random_id().unwrap()
        ));
        Self { root }
    }
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_copis-chrome"));
        command.env("COPIS_CHROME_RUNTIME_DIR", &self.root).env(
            "COPIS_CHROME_HELPER",
            format!(
                "{}/tests/fixtures/fake-helper.sh",
                env!("CARGO_MANIFEST_DIR")
            ),
        );
        command
    }
    fn raw(&self, args: &[&str]) -> Output {
        self.command().args(args).output().unwrap()
    }
    fn call(&self, args: &[&str]) -> Value {
        let output = self.raw(args);
        let value: Value = serde_json::from_slice(&output.stdout).unwrap_or_else(|e| {
            panic!(
                "{args:?}: {e}; stdout={:?}; stderr={:?}",
                output.stdout, output.stderr
            )
        });
        assert_eq!(output.status.success(), value["ok"] == true);
        assert_eq!(value["protocolVersion"], 1);
        value
    }
    fn connection(&self) -> String {
        self.call(&["connect", "--window", "42"])["connectionId"]
            .as_str()
            .unwrap()
            .into()
    }
    fn frame(&self, id: &str) -> String {
        self.call(&["observe", "--connection", id])["frameId"]
            .as_str()
            .unwrap()
            .into()
    }
}
impl Drop for Environment {
    fn drop(&mut self) {
        let _ = self.raw(&["daemon", "stop"]);
        for _ in 0..60 {
            if !self.root.join("daemon.sock").exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
#[test]
fn given_separate_processes_when_connect_observe_and_repeated_input_then_connection_persists() {
    let env = Environment::new();
    assert_eq!(env.call(&["status"])["running"], false);
    assert!(!env.root.exists());
    let id = env.connection();
    let frame = env.frame(&id);
    for _ in 0..2 {
        assert_eq!(
            env.call(&[
                "click",
                "--connection",
                &id,
                "--frame",
                &frame,
                "--x",
                "400",
                "--y",
                "300"
            ])["sent"],
            true
        );
    }
    assert_eq!(
        env.call(&["connect", "--window", "42"])["error"]["code"],
        "CONNECTION_BUSY"
    );
    assert!(!env.call(&["status"]).to_string().contains(&id));
    assert_eq!(env.call(&["disconnect", "--connection", &id])["ok"], true);
    assert_eq!(
        env.call(&["observe", "--connection", &id])["error"]["code"],
        "CONNECTION_INVALID"
    );
}
#[test]
fn given_output_file_exists_when_observing_then_original_file_is_not_overwritten() {
    let env = Environment::new();
    let id = env.connection();
    let path = env.root.join("saved.jpg");
    std::fs::write(&path, b"keep me").unwrap();
    let result = env.call(&[
        "observe",
        "--connection",
        &id,
        "--out",
        path.to_str().unwrap(),
    ]);
    assert_eq!(result["error"]["code"], "OUTPUT_EXISTS");
    assert_eq!(std::fs::read(&path).unwrap(), b"keep me");
    let path = env.root.join("new.jpg");
    assert_eq!(
        env.call(&[
            "observe",
            "--connection",
            &id,
            "--out",
            path.to_str().unwrap()
        ])["imagePath"],
        path.to_str().unwrap()
    );
    assert!(path.exists());
    env.call(&["disconnect", "--connection", &id]);
    assert!(path.exists(), "用户主动导出的截图不随 disconnect 删除");
}
#[test]
fn given_bad_arguments_when_invoking_then_json_error_without_starting_daemon() {
    let env = Environment::new();
    for args in [
        &["click", "--x", "oops"][..],
        &["permissions", "--unknown"][..],
        &["windows", "--window", "42"][..],
        &["connect", "--window", "42", "--window", "42"][..],
    ] {
        assert_eq!(env.call(args)["error"]["code"], "INVALID_ARGUMENT");
        assert!(!env.root.exists());
    }
}
#[test]
fn given_native_user_paused_when_input_called_then_public_process_maps_reason_and_keeps_connection()
{
    let env = Environment::new();
    let id = env.connection();
    let frame = env.frame(&id);
    let paused = env.call(&[
        "type",
        "--connection",
        &id,
        "--frame",
        &frame,
        "--text",
        "paused",
    ]);

    assert_eq!(paused["error"]["code"], "FOCUS_LOST");
    assert_eq!(paused["error"]["reason"], "USER_PAUSED");
    let message = paused["error"]["message"].as_str().unwrap();
    assert!(message.contains("已暂停"));
    assert!(message.contains("继续按钮"));
    assert!(message.contains("3 秒倒计时"));
    assert!(message.contains("不会自动恢复"));
    assert!(message.contains("不会重放旧输入"));
    assert!(!paused.to_string().contains("secret fixture detail"));
    assert_eq!(env.call(&["status"])["connected"], true);
    assert_eq!(env.call(&["disconnect", "--connection", &id])["ok"], true);
}

#[test]
fn given_native_eof_when_input_called_then_error_is_visible_and_daemon_exits() {
    let env = Environment::new();
    let id = env.connection();
    let frame = env.frame(&id);
    assert_eq!(
        env.call(&[
            "type",
            "--connection",
            &id,
            "--frame",
            &frame,
            "--text",
            "eof"
        ])["error"]["code"],
        "HELPER_EOF"
    );
}
#[test]
fn given_input_in_progress_when_other_client_requests_then_busy_and_emergency_stop_remain_usable() {
    let env = Environment::new();
    let id = env.connection();
    let frame = env.frame(&id);
    let mut child = env
        .command()
        .args([
            "type",
            "--connection",
            &id,
            "--frame",
            &frame,
            "--text",
            "slow",
        ])
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    // 先等原生边界的就绪信号；提前轮询 status 可能反过来让被测输入收到 BUSY。
    while !env.root.join("input-started").exists() {
        assert!(
            child.try_wait().unwrap().is_none(),
            "被测输入在进入 helper 前已退出"
        );
        assert!(Instant::now() < deadline, "输入没有进入执行状态");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(env.call(&["status"])["error"]["code"], "BUSY");
    assert_eq!(env.call(&["daemon", "stop"])["ok"], true);
    let start = Instant::now();
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::sleep(Duration::from_millis(20));
    }
}
