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
        assert!(
            value.get("scope").is_none(),
            "Chrome 响应须保持旧 JSONL 格式"
        );
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

#[test]
fn given_desktop_entry_when_using_private_fake_runtime_then_apps_filter_and_fixed_identity_work() {
    let env = DesktopEnvironment::new();
    let status = env.call(&["status"]);
    assert_eq!(status["scope"], "desktop");
    assert!(
        !env.chrome_root.exists(),
        "desktop 模式不得读取或创建 Chrome runtime"
    );

    let apps = env.call(&["apps"]);
    assert_eq!(apps["apps"][0]["bundleId"], "com.google.Chrome");
    let windows = env.call(&["windows", "--app", "com.google.Chrome"]);
    assert_eq!(windows["windows"].as_array().unwrap().len(), 1);
    let connection = env.call(&["connect", "--window", "42"])["connectionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let frame = env.call(&["observe", "--connection", &connection])["frameId"]
        .as_str()
        .unwrap()
        .to_owned();
    for args in [
        vec![
            "click",
            "--connection",
            &connection,
            "--frame",
            &frame,
            "--x",
            "10",
            "--y",
            "10",
        ],
        vec![
            "scroll",
            "--connection",
            &connection,
            "--frame",
            &frame,
            "--x",
            "10",
            "--y",
            "10",
            "--delta-y",
            "20",
        ],
        vec![
            "type",
            "--connection",
            &connection,
            "--frame",
            &frame,
            "--text",
            "fixture",
        ],
        vec![
            "press",
            "--connection",
            &connection,
            "--frame",
            &frame,
            "--key",
            "Enter",
        ],
    ] {
        assert_eq!(env.call(&args)["sent"], true);
    }
    assert_eq!(
        std::fs::read_to_string(env.root.join("helper-mode")).unwrap(),
        "desktop"
    );
    env.call(&["disconnect", "--connection", &connection]);
    assert!(
        !env.chrome_root.exists(),
        "通用运行期间不能创建 Chrome runtime"
    );
}

#[test]
fn given_chrome_entry_when_running_legacy_protocol_then_no_scope_is_added_to_output() {
    let env = Environment::new();
    let status = env.call(&["status"]);
    assert!(status.get("scope").is_none(), "Chrome 保持旧响应信封格式");
}

struct DesktopEnvironment {
    root: PathBuf,
    chrome_root: PathBuf,
}
impl DesktopEnvironment {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/tmp/desktop-cli-test-{}",
            copis_chrome::protocol::random_id().unwrap()
        ));
        let chrome_root = root.with_extension("chrome-runtime");
        Self { root, chrome_root }
    }
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_desktop-control"));
        command
            .env("COPIS_DESKTOP_RUNTIME_DIR", &self.root)
            .env("COPIS_CHROME_RUNTIME_DIR", &self.chrome_root)
            .env(
                "COPIS_CHROME_HELPER",
                format!(
                    "{}/tests/fixtures/fake-helper.sh",
                    env!("CARGO_MANIFEST_DIR")
                ),
            )
            .env(
                "COPIS_DESKTOP_HELPER",
                format!(
                    "{}/tests/fixtures/fake-helper.sh",
                    env!("CARGO_MANIFEST_DIR")
                ),
            );
        command
    }
    fn call(&self, args: &[&str]) -> Value {
        let output = self.command().args(args).output().unwrap();
        let value: Value = serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
            panic!(
                "{args:?}: {error}; stdout={:?}; stderr={:?}",
                output.stdout, output.stderr
            )
        });
        assert_eq!(output.status.success(), value["ok"] == true);
        assert_eq!(value["protocolVersion"], 1);
        assert_eq!(value["scope"], "desktop");
        value
    }
}
impl Drop for DesktopEnvironment {
    fn drop(&mut self) {
        let _ = self.command().args(["daemon", "stop"]).output();
        for _ in 0..60 {
            if !self.root.join("daemon.sock").exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = std::fs::remove_dir_all(&self.root);
        let _ = std::fs::remove_dir_all(&self.chrome_root);
    }
}

#[test]
fn given_desktop_daemon_when_chrome_scope_requests_emergency_stop_then_daemon_remains_running() {
    let env = DesktopEnvironment::new();
    let mut desktop = env.command();
    let started = desktop.args(["daemon", "start"]).output().unwrap();
    let started: Value = serde_json::from_slice(&started.stdout).unwrap();
    assert_eq!(started["ok"], true);

    let output = Command::new(env!("CARGO_BIN_EXE_copis-chrome"))
        .args(["daemon", "stop"])
        .env("COPIS_CHROME_RUNTIME_DIR", &env.root)
        .output()
        .unwrap();
    let mismatch: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(mismatch["error"]["code"], "SCOPE_MISMATCH");
    assert!(!output.status.success());

    let status = env.call(&["status"]);
    assert_eq!(status["running"], true);
    assert_eq!(status["scope"], "desktop");
    env.call(&["daemon", "stop"]);
}

#[test]
fn permissions_query_and_explicit_request_report_chrome_automation() {
    let env = Environment::new();
    for (args, requested) in [
        (&["permissions"][..], false),
        (&["permissions", "--request"][..], true),
    ] {
        let result = env.call(args);
        assert_eq!(result["ok"], true);
        assert_eq!(result["chromeAutomation"]["target"], "com.google.Chrome");
        assert_eq!(result["chromeAutomation"]["requested"], requested);
        assert_eq!(result["chromeAutomation"]["granted"], true);
    }
}
