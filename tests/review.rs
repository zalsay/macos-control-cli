#![cfg(unix)]
use copis_chrome::native::Helper;
use copis_chrome::protocol::random_id;
use copis_chrome::runtime::Runtime;
use copis_chrome::service::Native;
use serde_json::json;
use std::fs;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::{symlink, DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

// macOS 并行冷启动曾在 dyld 入口停留超过 2s；初始化与真正的动作超时分别计时。
const STARTUP_TIMEOUT: Duration = Duration::from_secs(8);
const WRAPPER_TIMEOUT: Duration = Duration::from_secs(12);
const SCENARIO_TIMEOUT: Duration = Duration::from_secs(3);
const PHASE_ENV: &str = "COPIS_REVIEW_PHASE";

fn process_state(pid: u32) -> String {
    Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "pid=,ppid=,stat=,etime="])
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .unwrap_or_else(|_| format!("pid={pid}，无法读取状态"))
}

struct Fixture {
    root: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(format!("/tmp/cc-review-{}", random_id().unwrap()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self { root }
    }
    fn runtime(&self) -> Runtime {
        Runtime {
            root: self.root.clone(),
            socket: self.root.join("daemon.sock"),
            frames: self.root.join("frames"),
        }
    }
    fn helper(&self, script: &str) -> Helper {
        let path = self.root.join("helper.sh");
        fs::write(
            &path,
            format!("#!/bin/sh\nprintf ready > \"$0.ready\"\n{script}\n"),
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        let ready = path.with_extension("sh.ready");
        if let Some(phase) = std::env::var_os(PHASE_ENV) {
            fs::write(
                phase,
                format!(
                    "initializing; ready={}; testPid={}",
                    ready.display(),
                    std::process::id()
                ),
            )
            .unwrap();
        }
        let helper = Helper::with_timeout(&path, Duration::from_millis(180)).unwrap();
        let started = Instant::now();
        while !ready.exists() {
            assert!(
                started.elapsed() < STARTUP_TIMEOUT,
                "假 helper 初始化超过 {STARTUP_TIMEOUT:?}；尚未发送动作；ready={}；测试进程状态(pid/ppid/stat/etime)={}",
                ready.display(), process_state(std::process::id())
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        if let Some(phase) = std::env::var_os(PHASE_ENV) {
            fs::write(phase, "ready").unwrap();
        }
        helper
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if std::thread::panicking() {
            eprintln!("保留失败 fixture 供诊断：{}", self.root.display());
        } else {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

// 卡死回归在隔离子进程运行，失败也不会无限阻塞 cargo test。
fn bounded(name: &str, scenario: impl FnOnce()) {
    if std::env::var("COPIS_REVIEW_CASE").ok().as_deref() == Some(name) {
        scenario();
        return;
    }
    let control = Fixture::new();
    let phase = control.root.join("phase");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", name, "--nocapture"])
        .env("COPIS_REVIEW_CASE", name)
        .env(PHASE_ENV, &phase)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let wrapper_deadline = Instant::now() + WRAPPER_TIMEOUT;
    let mut scenario_deadline = None;
    loop {
        if scenario_deadline.is_none()
            && fs::read_to_string(&phase).ok().as_deref() == Some("ready")
        {
            scenario_deadline = Some(Instant::now() + SCENARIO_TIMEOUT);
        }
        if child.try_wait().unwrap().is_some() {
            let output = child.wait_with_output().unwrap();
            assert!(
                !String::from_utf8_lossy(&output.stderr).contains("SENSITIVE_REVIEW_PAYLOAD"),
                "helper stderr 泄漏敏感输入"
            );
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }
        if Instant::now()
            >= scenario_deadline
                .unwrap_or(wrapper_deadline)
                .min(wrapper_deadline)
        {
            let state = process_state(child.id());
            let phase_state =
                fs::read_to_string(&phase).unwrap_or_else(|_| "子测试尚未开始初始化 helper".into());
            let _ = child.kill();
            let _ = child.wait();
            if scenario_deadline.is_some() {
                panic!("{name}: helper 就绪后，动作/清理或取消超过 {SCENARIO_TIMEOUT:?}；测试进程状态={state}");
            }
            panic!(
                "{name}: 子测试/helper 初始化超出 wrapper 总预算 {WRAPPER_TIMEOUT:?}，尚未开始动作；{phase_state}；测试进程状态={state}；phase={}",
                phase.display()
            );
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn given_cancel_when_helper_releases_held_input_then_ack_precedes_kill() {
    let fixture = Fixture::new();
    let marker = fixture.root.join("released");
    let helper = fixture.helper(&format!(
        r#"
while IFS= read -r line; do
  case "$line" in
    *'"action":"cancel"'*)
      sleep 0.08
      printf released > '{}'
      printf '{{"id":"cancel","ok":true,"data":{{"cancelled":true}}}}\n'
      ;;
  esac
done
"#,
        marker.display()
    ));
    helper.canceller().terminate();
    assert!(
        marker.exists(),
        "强杀前必须允许 helper 同步释放 held 输入并确认 cancel"
    );
}

#[test]
fn given_full_response_queue_when_cancelled_then_reader_still_observes_ack() {
    bounded(
        "given_full_response_queue_when_cancelled_then_reader_still_observes_ack",
        || {
            let fixture = Fixture::new();
            let marker = fixture.root.join("released");
            let helper = fixture.helper(&format!(r#"
i=0
while [ "$i" -lt 24 ]; do
  printf '{{"id":"unsolicited","ok":true,"data":{{}}}}\n'
  i=$((i + 1))
done
while IFS= read -r line; do
  case "$line" in
    *'"action":"cancel"'*) sleep 0.08; printf released > '{}'; printf '{{"id":"cancel","ok":true,"data":{{"cancelled":true}}}}\n' ;;
  esac
done
"#, marker.display()));
            std::thread::sleep(Duration::from_millis(60));
            let start = Instant::now();
            helper.canceller().terminate();
            assert!(marker.exists());
            assert!(
                start.elapsed() < Duration::from_millis(220),
                "队列饱和也必须及时观察到 ack，而非等到 250ms 强杀"
            );
            drop(helper);
        },
    );
}

#[test]
fn given_helper_not_reading_when_request_fills_stdin_then_timeout_and_stop_are_bounded() {
    bounded(
        "given_helper_not_reading_when_request_fills_stdin_then_timeout_and_stop_are_bounded",
        || {
            let fixture = Fixture::new();
            let mut helper = fixture.helper("sleep 5");
            let start = Instant::now();
            let error = helper
                .request(json!({"action":"type","text":"a".repeat(60_000)}))
                .unwrap_err();
            assert_eq!(error.code, "HELPER_TIMEOUT");
            drop(helper);
            assert!(start.elapsed() < Duration::from_secs(2));
        },
    );
}

#[test]
fn given_descendant_holds_stdout_when_helper_times_out_then_reader_cleanup_is_bounded() {
    bounded(
        "given_descendant_holds_stdout_when_helper_times_out_then_reader_cleanup_is_bounded",
        || {
            let fixture = Fixture::new();
            let mut helper = fixture.helper("IFS= read -r line\nsleep 5 &\nexit 0");
            let start = Instant::now();
            assert!(helper.request(json!({"action":"windows"})).is_err());
            drop(helper);
            assert!(start.elapsed() < Duration::from_secs(2));
        },
    );
}

#[test]
fn given_non_utf8_runtime_when_preparing_then_it_returns_error_without_panicking() {
    let fixture = Fixture::new();
    let runtime = Runtime {
        root: fixture.root.join(std::ffi::OsString::from_vec(vec![0xff])),
        socket: fixture.root.join("socket"),
        frames: fixture.root.join("frames"),
    };
    assert_eq!(runtime.prepare().unwrap_err().code, "INVALID_ARGUMENT");
}

#[test]
fn given_symlink_or_public_socket_when_validating_then_connection_is_rejected() {
    let fixture = Fixture::new();
    let runtime = fixture.runtime();
    runtime.prepare().unwrap();
    let target = fixture.root.join("target.sock");
    let _listener = UnixListener::bind(&target).unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
    symlink(&target, &runtime.socket).unwrap();
    assert_eq!(runtime.validate().unwrap_err().code, "INSECURE_RUNTIME");
    fs::remove_file(&runtime.socket).unwrap();
    let _listener = UnixListener::bind(&runtime.socket).unwrap();
    fs::set_permissions(&runtime.socket, fs::Permissions::from_mode(0o666)).unwrap();
    assert_eq!(runtime.validate().unwrap_err().code, "INSECURE_RUNTIME");
}

#[test]
fn given_hardlinked_daemon_log_when_opened_then_unrelated_file_is_not_written() {
    let fixture = Fixture::new();
    let runtime = fixture.runtime();
    runtime.prepare().unwrap();
    let target = fixture.root.join("keep");
    fs::write(&target, b"original").unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
    fs::hard_link(&target, fixture.root.join("daemon.log")).unwrap();
    assert_eq!(runtime.log().unwrap_err().code, "INSECURE_RUNTIME");
    assert_eq!(fs::read(&target).unwrap(), b"original");
}

#[test]
#[cfg(target_os = "macos")]
fn given_start_loser_when_winner_takes_longer_than_200ms_then_start_waits_for_winner() {
    let fixture = Fixture::new();
    let runtime = fixture.runtime();
    runtime.prepare().unwrap();
    let _lock = runtime.lock().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_copis-chrome"))
        .args(["daemon", "start"])
        .env("COPIS_CHROME_RUNTIME_DIR", &runtime.root)
        .env(
            "COPIS_CHROME_HELPER",
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-helper.sh"),
        )
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(700));
    let _listener = UnixListener::bind(&runtime.socket).unwrap();
    fs::set_permissions(&runtime.socket, fs::Permissions::from_mode(0o600)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
}

#[test]
fn given_oversized_native_request_when_sent_then_it_is_rejected_before_pipe_write() {
    bounded(
        "given_oversized_native_request_when_sent_then_it_is_rejected_before_pipe_write",
        || {
            let fixture = Fixture::new();
            let mut helper = fixture.helper("sleep 5");
            let error = helper
                .request(json!({"action":"type","text":"a".repeat(200_000)}))
                .unwrap_err();
            assert_eq!(error.code, "MESSAGE_TOO_LARGE");
        },
    );
}

#[test]
fn given_helper_echoes_sensitive_stdin_to_stderr_then_no_secret_reaches_logs() {
    bounded(
        "given_helper_echoes_sensitive_stdin_to_stderr_then_no_secret_reaches_logs",
        || {
            let fixture = Fixture::new();
            let mut helper = fixture.helper(
                r#"
IFS= read -r line
printf '%s' "$line" >&2
printf '{"id":"1","ok":true,"data":{"sent":true}}\n'
"#,
            );
            helper
                .request(json!({"action":"type","text":"SENSITIVE_REVIEW_PAYLOAD"}))
                .unwrap();
        },
    );
}

#[test]
fn given_concurrent_start_logs_when_first_handle_writes_later_then_existing_log_is_not_overwritten()
{
    use std::io::Write;
    let fixture = Fixture::new();
    let runtime = fixture.runtime();
    runtime.prepare().unwrap();
    let mut first = runtime.log().unwrap();
    let mut second = runtime.log().unwrap();
    second.write_all(b"second\n").unwrap();
    first.write_all(b"first\n").unwrap();
    assert_eq!(
        fs::read(fixture.root.join("daemon.log")).unwrap(),
        b"second\nfirst\n"
    );
}
