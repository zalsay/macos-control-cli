use crate::protocol::{Error, Result};
use serde_json::Value;
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
unsafe extern "C" {
    fn kill(pid: i32, signal: i32) -> i32;
}

pub const DECISION_PROTOCOL: &str = "decisions-v1";
#[cfg(test)]
pub(crate) const MODEL: &str = "typesafe/jev-1.13";

#[cfg(test)]
const API_ENDPOINT: &str = "https://openrouter.ai/api/alpha/decisions";
const CURL_EXECUTABLE: &str = "/usr/bin/curl";
const MAX_KEY_BYTES: usize = 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const HTTP_STATUS_TRAILER_BYTES: usize = 4;
const MAX_CAPTURE_BYTES: usize = MAX_RESPONSE_BYTES + HTTP_STATUS_TRAILER_BYTES;
const PROCESS_TIMEOUT: Duration = Duration::from_secs(8);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(10);
const PIPE_DRAIN_TIMEOUT: Duration = Duration::from_millis(100);
const PIPE_CLEANUP_TIMEOUT: Duration = Duration::from_millis(250);

const JEV_KEY_REQUIRED: &str = "JEV_KEY_REQUIRED";
const CANCELLED: &str = "CANCELLED";
const JEV_TIMEOUT: &str = "JEV_TIMEOUT";
const JEV_INVALID_RESPONSE: &str = "JEV_INVALID_RESPONSE";
const JEV_REQUEST_FAILED: &str = "JEV_REQUEST_FAILED";

pub trait Decision: Send {
    fn decide(&mut self, endpoint: &str, key: &str, request: &Value) -> Result<Value>;
    fn set_cancellation(&mut self, _cancelled: Option<Arc<AtomicBool>>) {}
}

#[derive(Default)]
pub struct JevClient {
    cancelled: Option<Arc<AtomicBool>>,
}

impl JevClient {
    pub fn with_cancellation(cancelled: Arc<AtomicBool>) -> Self {
        Self {
            cancelled: Some(cancelled),
        }
    }
}

impl Decision for JevClient {
    fn set_cancellation(&mut self, cancelled: Option<Arc<AtomicBool>>) {
        self.cancelled = cancelled;
    }
    fn decide(&mut self, endpoint: &str, key: &str, request: &Value) -> Result<Value> {
        decide_with_executable_cancellable(
            Path::new(CURL_EXECUTABLE),
            endpoint,
            key,
            request,
            self.cancelled.as_deref(),
        )
    }
}

pub fn resolve_key(explicit: Option<&str>, environment: Option<&str>) -> Result<String> {
    let key = explicit.or(environment).ok_or_else(|| {
        Error::new(
            JEV_KEY_REQUIRED,
            "缺少 API 密钥；请使用 mcc --config set 配置，或通过 --jev-key 显式覆盖本次密钥。",
        )
    })?;
    validate_key(key)?;
    Ok(key.to_owned())
}

fn validate_key(key: &str) -> Result<()> {
    if key.is_empty()
        || key.len() > MAX_KEY_BYTES
        || !key.bytes().all(|byte| byte.is_ascii_graphic())
    {
        return Err(Error::invalid(
            "JEV API 密钥必须为 1 到 1024 个 ASCII 图形字符（不含空格）。",
        ));
    }
    Ok(())
}

#[cfg(all(test, unix))]
fn decide_with_executable(executable: &Path, key: &str, request: &Value) -> Result<Value> {
    decide_with_executable_cancellable(executable, API_ENDPOINT, key, request, None)
}

fn decide_with_executable_cancellable(
    executable: &Path,
    endpoint: &str,
    key: &str,
    request: &Value,
    cancelled: Option<&AtomicBool>,
) -> Result<Value> {
    if is_cancelled(cancelled) {
        return Err(cancelled_error());
    }
    validate_key(key)?;
    crate::config::validate_endpoint(endpoint)?;
    let request_json = serde_json::to_string(request)
        .map_err(|_| jev_error(JEV_REQUEST_FAILED, "无法编码 JEV 请求。"))?;
    if request_json.len() > MAX_REQUEST_BYTES {
        return Err(Error::invalid("JEV 请求超过 64 KiB。"));
    }
    let config = build_curl_config_for_endpoint(endpoint, key, &request_json);
    run_curl_config_with_executable(executable, &config, cancelled)
}

fn run_curl_config_with_executable(
    executable: &Path,
    config: &str,
    cancelled: Option<&AtomicBool>,
) -> Result<Value> {
    if is_cancelled(cancelled) {
        return Err(cancelled_error());
    }
    let mut command = Command::new(executable);
    // curl only skips its default config when -q is its first argument.
    command
        .arg("-q")
        .arg("--config")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        // Never expose curl diagnostics, which can contain local or remote details.
        .stderr(Stdio::null())
        .env_remove("TYPESAFE_API_KEY")
        .env_remove("JEV_API_KEY")
        .env_remove("OPENROUTER_API_KEY")
        .env_remove("HTTP_PROXY")
        .env_remove("http_proxy")
        .env_remove("HTTPS_PROXY")
        .env_remove("https_proxy")
        .env_remove("ALL_PROXY")
        .env_remove("all_proxy")
        .env_remove("NO_PROXY")
        .env_remove("no_proxy")
        .env_remove("FTP_PROXY")
        .env_remove("ftp_proxy")
        .env_remove("CURL_CA_BUNDLE")
        .env_remove("SSL_CERT_FILE")
        .env_remove("SSL_CERT_DIR")
        .env_remove("CURL_SSL_BACKEND")
        .env_remove("SSLKEYLOGFILE");
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command
        .spawn()
        .map_err(|_| jev_error(JEV_REQUEST_FAILED, "无法启动 JEV HTTPS 传输。"))?;

    let child_stdin = child.stdin.take().ok_or_else(|| {
        terminate_child(&mut child);
        jev_error(JEV_REQUEST_FAILED, "无法启动 JEV HTTPS 传输。")
    })?;
    let child_stdout = child.stdout.take().ok_or_else(|| {
        terminate_child(&mut child);
        jev_error(JEV_REQUEST_FAILED, "无法启动 JEV HTTPS 传输。")
    })?;

    let child_pid = child.id();
    let oversized = Arc::new(AtomicBool::new(false));
    let reader_oversized = Arc::clone(&oversized);
    let reader = thread::spawn(move || -> std::io::Result<Vec<u8>> {
        let mut output = Vec::with_capacity(MAX_CAPTURE_BYTES + 1);
        child_stdout
            .take((MAX_CAPTURE_BYTES + 1) as u64)
            .read_to_end(&mut output)?;
        if output.len() > MAX_CAPTURE_BYTES {
            reader_oversized.store(true, Ordering::Release);
        }
        Ok(output)
    });

    let config_bytes = config.as_bytes().to_vec();
    let writer = thread::spawn(move || -> std::io::Result<()> {
        let mut child_stdin = child_stdin;
        child_stdin.write_all(&config_bytes)
    });

    let deadline = Instant::now() + PROCESS_TIMEOUT;
    let mut cancelled_request = false;
    let mut timed_out = false;
    let mut output_too_large = false;
    let mut process_error = false;
    let exit_status = loop {
        if is_cancelled(cancelled) {
            cancelled_request = true;
            terminate_child(&mut child);
            break None;
        }
        if oversized.load(Ordering::Acquire) {
            output_too_large = true;
            terminate_child(&mut child);
            break None;
        }
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => {
                process_error = true;
                terminate_child(&mut child);
                break None;
            }
        }
        if Instant::now() >= deadline {
            timed_out = true;
            terminate_child(&mut child);
            break None;
        }
        thread::sleep(PROCESS_POLL_INTERVAL);
    };

    let worker_results = finish_pipe_workers(child_pid, writer, reader);
    output_too_large |= oversized.load(Ordering::Acquire);

    if cancelled_request {
        return Err(cancelled_error());
    }
    if timed_out {
        return Err(jev_error(JEV_TIMEOUT, "JEV 请求超时。"));
    }
    if output_too_large {
        return Err(jev_error(JEV_INVALID_RESPONSE, "JEV 响应超过 64 KiB。"));
    }
    let (writer_result, output_result) = worker_results
        .ok_or_else(|| jev_error(JEV_REQUEST_FAILED, "JEV 传输管道未能及时关闭。"))?;
    if process_error || writer_result.is_err() || output_result.is_err() {
        return Err(jev_error(JEV_REQUEST_FAILED, "JEV 请求失败。"));
    }

    let status = exit_status.ok_or_else(|| jev_error(JEV_REQUEST_FAILED, "JEV 请求失败。"))?;
    if status.code() == Some(28) {
        return Err(jev_error(JEV_TIMEOUT, "JEV 请求超时。"));
    }
    if !status.success() {
        return Err(jev_error(JEV_REQUEST_FAILED, "JEV 请求失败。"));
    }

    parse_curl_output(&output_result.expect("checked above"))
}

fn finish_pipe_workers(
    child_pid: u32,
    writer: thread::JoinHandle<std::io::Result<()>>,
    reader: thread::JoinHandle<std::io::Result<Vec<u8>>>,
) -> Option<(std::io::Result<()>, std::io::Result<Vec<u8>>)> {
    let drain_deadline = Instant::now() + PIPE_DRAIN_TIMEOUT;
    while (!writer.is_finished() || !reader.is_finished()) && Instant::now() < drain_deadline {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }

    if !writer.is_finished() || !reader.is_finished() {
        kill_process_group(child_pid);
        let cleanup_deadline = Instant::now() + PIPE_CLEANUP_TIMEOUT;
        while (!writer.is_finished() || !reader.is_finished()) && Instant::now() < cleanup_deadline
        {
            thread::sleep(PROCESS_POLL_INTERVAL);
        }
    }

    if !writer.is_finished() || !reader.is_finished() {
        // Dropping the handles detaches any worker still blocked on an escaped descendant.
        return None;
    }
    let writer_result = writer.join().ok()?;
    let reader_result = reader.join().ok()?;
    Some((writer_result, reader_result))
}

#[cfg(unix)]
fn kill_process_group(child_pid: u32) {
    if let Ok(pid) = i32::try_from(child_pid) {
        // Each curl child is placed in a private process group; negative PID signals that group.
        unsafe {
            let _ = kill(-pid, 9);
        }
    }
}

#[cfg(not(unix))]
fn kill_process_group(_child_pid: u32) {}

fn terminate_child(child: &mut Child) {
    kill_process_group(child.id());
    let _ = child.kill();
    let _ = child.wait();
}

fn build_curl_config_for_endpoint(endpoint: &str, key: &str, request_json: &str) -> String {
    let auth_header = format!("Authorization: Bearer {key}");
    let mut config = String::new();
    config.push_str("silent\nshow-error\n");
    config.push_str("connect-timeout = 3\nmax-time = 8\nretry = 0\n");
    config.push_str("max-redirs = 0\nnoproxy = \"*\"\nproto = \"=https\"\ntlsv1.2\n");
    if endpoint
        .get(..7)
        .is_some_and(|s| s.eq_ignore_ascii_case("http://"))
    {
        config.push_str("proto = \"=http\"\n");
    }
    config.push_str(&format!("url = {}\n", curl_config_quote(endpoint)));
    config.push_str("request = \"POST\"\n");
    config.push_str(&format!("header = {}\n", curl_config_quote(&auth_header)));
    config.push_str(&format!(
        "header = {}\n",
        curl_config_quote("Content-Type: application/json")
    ));
    config.push_str(&format!(
        "header = {}\n",
        curl_config_quote("Accept: application/json")
    ));
    config.push_str(&format!(
        "data-binary = {}\n",
        curl_config_quote(request_json)
    ));
    config.push_str("write-out = \"\\n%{http_code}\"\n");
    config
}

fn curl_config_quote(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for character in value.chars() {
        match character {
            '\\' => quoted.push_str("\\\\"),
            '"' => quoted.push_str("\\\""),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            '\u{000b}' => quoted.push_str("\\v"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

fn parse_curl_output(output: &[u8]) -> Result<Value> {
    if output.len() > MAX_CAPTURE_BYTES {
        return Err(jev_error(JEV_INVALID_RESPONSE, "JEV 响应超过 64 KiB。"));
    }
    if output.len() < HTTP_STATUS_TRAILER_BYTES {
        return Err(jev_error(JEV_REQUEST_FAILED, "JEV 请求失败。"));
    }
    let status_start = output.len() - 3;
    if output[status_start - 1] != b'\n' || !output[status_start..].iter().all(u8::is_ascii_digit) {
        return Err(jev_error(JEV_REQUEST_FAILED, "JEV 请求失败。"));
    }
    let status = std::str::from_utf8(&output[status_start..])
        .ok()
        .and_then(|digits| digits.parse::<u16>().ok())
        .unwrap_or(0);
    match status {
        200..=299 => {}
        401 | 403 => {
            return Err(jev_error("JEV_AUTH_FAILED", "JEV 身份验证失败。"));
        }
        429 => {
            return Err(jev_error(
                "JEV_RATE_LIMITED",
                "JEV 请求过于频繁，已达到速率限制。",
            ))
        }
        500..=599 => {
            return Err(jev_error("JEV_UNAVAILABLE", "JEV 服务暂不可用。"));
        }
        _ => {
            return Err(jev_error(JEV_REQUEST_FAILED, "JEV 请求失败。"));
        }
    }

    let body = &output[..status_start - 1];
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(jev_error(JEV_INVALID_RESPONSE, "JEV 响应超过 64 KiB。"));
    }
    serde_json::from_slice(body)
        .map_err(|_| jev_error(JEV_INVALID_RESPONSE, "JEV 返回的 JSON 响应无效。"))
}

fn jev_error(code: &str, message: &str) -> Error {
    Error::new(code, message)
}

fn is_cancelled(cancelled: Option<&AtomicBool>) -> bool {
    cancelled.is_some_and(|flag| flag.load(Ordering::Acquire))
}

fn cancelled_error() -> Error {
    jev_error(CANCELLED, "JEV 请求已取消。")
}

#[cfg(all(test, unix))]
mod tests {
    use super::{
        decide_with_executable, decide_with_executable_cancellable, resolve_key, JevClient,
        API_ENDPOINT, CURL_EXECUTABLE, MAX_REQUEST_BYTES,
    };
    use serde_json::json;
    use std::ffi::OsString;
    use std::fs;
    use std::io::{Error as IoError, ErrorKind, Read, Write};
    use std::net::TcpListener;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct Fixture {
        dir: PathBuf,
        executable: PathBuf,
    }

    struct EnvironmentRestore(Vec<(&'static str, Option<OsString>)>);

    impl EnvironmentRestore {
        fn set(values: &[(&'static str, &'static str)]) -> Self {
            let original = values
                .iter()
                .map(|(name, value)| {
                    let old = std::env::var_os(name);
                    std::env::set_var(name, value);
                    (*name, old)
                })
                .collect();
            Self(original)
        }
    }

    impl Drop for EnvironmentRestore {
        fn drop(&mut self) {
            for (name, value) in self.0.drain(..) {
                match value {
                    Some(value) => std::env::set_var(name, value),
                    None => std::env::remove_var(name),
                }
            }
        }
    }

    impl Fixture {
        fn new(script: &str, response: Option<&[u8]>) -> Self {
            let id = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir()
                .join(format!("jev-transport-test-{}-{id}", std::process::id()));
            fs::create_dir(&dir).expect("create fixture directory");
            let executable = dir.join("fake-curl");
            fs::write(
                &executable,
                format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"${{0%/*}}/argv\"\n{script}\n"),
            )
            .expect("write fake curl");
            let mut permissions = fs::metadata(&executable)
                .expect("stat fake curl")
                .permissions();
            permissions.set_mode(0o700);
            fs::set_permissions(&executable, permissions).expect("make fake curl executable");
            if let Some(response) = response {
                fs::write(dir.join("response"), response).expect("write fake response");
            }
            Self { dir, executable }
        }

        fn path(&self, name: &str) -> PathBuf {
            self.dir.join(name)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    fn response_fixture(bytes: &[u8]) -> Fixture {
        Fixture::new(
            "cat > \"${0%/*}/config\"\ncat \"${0%/*}/response\"",
            Some(bytes),
        )
    }

    fn invoke(fixture: &Fixture, key: &str) -> crate::protocol::Result<serde_json::Value> {
        decide_with_executable(
            &fixture.executable,
            key,
            &json!({"question": "a \"quoted\" line\\tail\nnext", "count": 2}),
        )
    }

    fn error_code<T: std::fmt::Debug>(result: crate::protocol::Result<T>) -> String {
        result.expect_err("request should fail").code
    }

    #[test]
    fn cancelled_before_start_does_not_spawn_the_transport() {
        let missing_executable = std::env::temp_dir().join("jev-cancelled-no-spawn");
        let cancelled = AtomicBool::new(true);
        let error = super::decide_with_executable_cancellable(
            &missing_executable,
            API_ENDPOINT,
            "valid-key",
            &json!({"question": "decide"}),
            Some(&cancelled),
        )
        .unwrap_err();
        assert_eq!(error.code, "CANCELLED");

        let mut client = JevClient::with_cancellation(Arc::new(AtomicBool::new(true)));
        let error = crate::jev::Decision::decide(
            &mut client,
            API_ENDPOINT,
            "valid-key",
            &json!({"question": "decide"}),
        )
        .unwrap_err();
        assert_eq!(error.code, "CANCELLED");
    }

    #[test]
    fn cancellation_during_transport_kills_and_reaps_child_quickly() {
        let fixture = Fixture::new(
            "echo $$ > \"${0%/*}/pid\"\ncat > /dev/null\nexec sleep 30",
            None,
        );
        let cancelled = Arc::new(AtomicBool::new(false));
        let thread_cancelled = Arc::clone(&cancelled);
        let executable = fixture.executable.clone();
        let request = json!({"question": "decide"});
        let worker = std::thread::spawn(move || {
            decide_with_executable_cancellable(
                &executable,
                API_ENDPOINT,
                "valid-key",
                &request,
                Some(thread_cancelled.as_ref()),
            )
        });

        let pid_path = fixture.path("pid");
        let startup_deadline = Instant::now() + Duration::from_secs(5);
        while !pid_path.exists() && Instant::now() < startup_deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        if !pid_path.exists() {
            let result = worker.join().expect("transport worker should exit");
            panic!("fake transport did not start; result: {result:?}");
        }

        let cancelled_at = Instant::now();
        cancelled.store(true, Ordering::Release);
        let error = worker
            .join()
            .expect("transport worker should exit")
            .unwrap_err();
        assert_eq!(error.code, "CANCELLED");
        assert!(cancelled_at.elapsed() < Duration::from_secs(1));

        let pid = fs::read_to_string(pid_path).expect("fake child wrote its pid");
        let status = std::process::Command::new("/bin/kill")
            .args(["-0", pid.trim()])
            .stderr(std::process::Stdio::null())
            .status()
            .expect("check cancelled process");
        assert!(!status.success(), "cancelled child should have been reaped");
    }

    #[test]
    fn resolves_explicit_key_before_environment_key() {
        assert_eq!(
            resolve_key(Some("explicit"), Some("environment")).unwrap(),
            "explicit"
        );
        assert_eq!(
            resolve_key(None, Some("environment")).unwrap(),
            "environment"
        );
    }

    #[test]
    fn reports_missing_key_without_exposing_a_secret() {
        let error = resolve_key(None, None).unwrap_err();
        assert_eq!(error.code, "JEV_KEY_REQUIRED");
        assert!(error.message.contains("--jev-key"));
        assert!(error.message.contains("--config"));
        assert!(!error.to_string().contains("secret"));
    }

    #[test]
    fn rejects_invalid_keys_as_sanitized_invalid_arguments() {
        for key in [
            "",
            "has\ncontrol-secret-marker",
            "non-ascii-密-secret-marker",
            "has space",
        ] {
            let error = resolve_key(Some(key), Some("fallback-secret")).unwrap_err();
            assert_eq!(error.code, "INVALID_ARGUMENT");
            if !key.is_empty() {
                assert!(!error.to_string().contains(key));
            }
            assert!(!error.to_string().contains("fallback-secret"));
        }
        let too_long = "k".repeat(1025);
        let error = resolve_key(Some(&too_long), None).unwrap_err();
        assert_eq!(error.code, "INVALID_ARGUMENT");
        assert!(!error.to_string().contains(&too_long));
        assert_eq!(
            resolve_key(Some(&"k".repeat(1024)), None).unwrap().len(),
            1024
        );
    }

    #[test]
    fn rejects_oversized_request_before_spawning_transport() {
        let missing_executable = std::env::temp_dir().join("jev-no-spawn-for-large-request");
        let error = decide_with_executable(
            &missing_executable,
            "valid-key",
            &json!({"input": "x".repeat(65_536)}),
        )
        .unwrap_err();
        assert_eq!(error.code, "INVALID_ARGUMENT");
    }

    #[test]
    fn rejects_explicit_invalid_key_instead_of_falling_back() {
        assert_eq!(
            resolve_key(Some(""), Some("valid-fallback"))
                .unwrap_err()
                .code,
            "INVALID_ARGUMENT"
        );
    }

    fn serve_one_request(listener: TcpListener) -> std::io::Result<(String, Vec<u8>)> {
        listener.set_nonblocking(true)?;
        let accept_deadline = Instant::now() + Duration::from_secs(3);
        let (mut stream, _) = loop {
            match listener.accept() {
                Ok(connection) => break connection,
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    if Instant::now() >= accept_deadline {
                        return Err(IoError::new(ErrorKind::TimedOut, "accept timed out"));
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(error) => return Err(error),
            }
        };
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;

        let mut request = Vec::new();
        let mut expected_length = None;
        loop {
            let mut chunk = [0_u8; 4096];
            let count = stream.read(&mut chunk)?;
            if count == 0 {
                break;
            }
            request.extend_from_slice(&chunk[..count]);
            if request.len() > MAX_REQUEST_BYTES + 16 * 1024 {
                return Err(IoError::new(ErrorKind::InvalidData, "request too large"));
            }
            if expected_length.is_none() {
                if let Some(header_end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                    let header_text = String::from_utf8_lossy(&request[..header_end]);
                    let content_length = header_text
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().ok())
                                .flatten()
                        })
                        .ok_or_else(|| IoError::new(ErrorKind::InvalidData, "missing length"))?;
                    expected_length = Some(header_end + 4 + content_length);
                }
            }
            if expected_length.is_some_and(|length| request.len() >= length) {
                break;
            }
        }

        let header_end = request
            .windows(4)
            .position(|part| part == b"\r\n\r\n")
            .ok_or_else(|| IoError::new(ErrorKind::InvalidData, "missing headers"))?;
        let end =
            expected_length.ok_or_else(|| IoError::new(ErrorKind::InvalidData, "missing body"))?;
        if request.len() < end {
            return Err(IoError::new(ErrorKind::UnexpectedEof, "truncated body"));
        }
        let headers = String::from_utf8_lossy(&request[..header_end]).into_owned();
        let body = request[header_end + 4..end].to_vec();
        let response_body = br#"{"decision":"loopback-ok"}"#;
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            response_body.len()
        )?;
        stream.write_all(response_body)?;
        Ok((headers, body))
    }

    #[test]
    fn real_curl_loopback_posts_escaped_json_and_bearer_header() {
        assert!(Path::new(CURL_EXECUTABLE).is_file());
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback listener");
        let address = listener.local_addr().expect("loopback address");
        let server = std::thread::spawn(move || serve_one_request(listener));

        let key = "loopback-placeholder-key";
        let request = json!({"text": "中文 \"引号\"\\路径\n第二行"});
        let endpoint = format!("http://{address}/decision");
        let response =
            crate::jev::Decision::decide(&mut JevClient::default(), &endpoint, key, &request)
                .expect("real curl should use the configured endpoint without path rewriting");
        assert_eq!(response, json!({"decision": "loopback-ok"}));

        let (headers, body) = server
            .join()
            .expect("loopback server thread should exit")
            .expect("loopback server should receive one request");
        let headers = headers.to_ascii_lowercase();
        assert!(headers.starts_with("post /decision http/1.1\r\n"));
        assert!(headers.contains("authorization: bearer loopback-placeholder-key"));
        assert!(headers.contains("content-type: application/json"));
        assert_eq!(body, serde_json::to_string(&request).unwrap().as_bytes());
    }

    #[test]
    fn posts_using_config_stdin_without_putting_the_key_in_argv() {
        let fixture = response_fixture(b"{\"decision\":\"allow\"}\n200");
        let key = "key-with-\\-and-\"quotes\"";
        assert_eq!(invoke(&fixture, key).unwrap(), json!({"decision": "allow"}));

        let argv = fs::read_to_string(fixture.path("argv")).expect("captured argv");
        assert_eq!(argv.lines().collect::<Vec<_>>(), ["-q", "--config", "-"]);
        assert!(!argv.contains(key));
        let config = fs::read_to_string(fixture.path("config")).expect("captured config");
        assert!(config.contains("https://openrouter.ai/api/alpha/decisions"));
        assert!(!config.contains("api.typesafe.ai") && !config.contains("chat/completions"));
        assert!(config.contains("Authorization: Bearer key-with-\\\\-and-\\\"quotes\\\""));
        let request = json!({"question": "a \"quoted\" line\\tail\nnext", "count": 2});
        let request_json = serde_json::to_string(&request).unwrap();
        assert!(config.contains(&format!(
            "data-binary = {}",
            super::curl_config_quote(&request_json)
        )));
    }

    #[test]
    fn maps_auth_rate_limit_server_and_other_http_statuses() {
        for (status, expected) in [
            (401, "JEV_AUTH_FAILED"),
            (403, "JEV_AUTH_FAILED"),
            (429, "JEV_RATE_LIMITED"),
            (500, "JEV_UNAVAILABLE"),
            (503, "JEV_UNAVAILABLE"),
            (400, "JEV_REQUEST_FAILED"),
            (302, "JEV_REQUEST_FAILED"),
        ] {
            let response = format!("{{\"remote\":\"do-not-leak\"}}\n{status}");
            let fixture = response_fixture(response.as_bytes());
            let error = invoke(&fixture, "test-secret").unwrap_err();
            assert_eq!(error.code, expected, "HTTP {status}");
            assert!(!error.to_string().contains("do-not-leak"));
            assert!(!error.to_string().contains("test-secret"));
        }
    }

    #[test]
    fn rejects_malformed_json_without_echoing_response_content() {
        let fixture = response_fixture(b"remote-secret-body\n200");
        let error = invoke(&fixture, "test-secret").unwrap_err();
        assert_eq!(error.code, "JEV_INVALID_RESPONSE");
        assert!(!error.to_string().contains("remote-secret-body"));
        assert!(!error.to_string().contains("test-secret"));
    }

    #[test]
    fn rejects_responses_larger_than_64_kib() {
        let fixture = Fixture::new(
            "cat > /dev/null\nhead -c 65537 /dev/zero\nprintf '\\n200'",
            None,
        );
        assert_eq!(
            error_code(invoke(&fixture, "test-secret")),
            "JEV_INVALID_RESPONSE"
        );
    }

    #[test]
    fn removes_api_keys_from_the_child_environment() {
        let _guard = ENV_LOCK.lock().expect("environment lock");
        let _restore = EnvironmentRestore::set(&[
            ("OPENROUTER_API_KEY", "openrouter-secret"),
            ("TYPESAFE_API_KEY", "parent-typesafe-secret"),
            ("JEV_API_KEY", "parent-jev-secret"),
            ("SSLKEYLOGFILE", "/tmp/jev-test-sslkeylog"),
            ("HTTPS_PROXY", "https://proxy.example.invalid"),
            ("https_proxy", "https://proxy.example.invalid"),
            ("ALL_PROXY", "https://proxy.example.invalid"),
            ("all_proxy", "https://proxy.example.invalid"),
        ]);
        let fixture = Fixture::new(
            "cat > /dev/null\nif [ \"${OPENROUTER_API_KEY+x}\" = x ] || [ \"${TYPESAFE_API_KEY+x}\" = x ] || [ \"${JEV_API_KEY+x}\" = x ] || [ \"${SSLKEYLOGFILE+x}\" = x ] || [ \"${HTTPS_PROXY+x}\" = x ] || [ \"${https_proxy+x}\" = x ] || [ \"${ALL_PROXY+x}\" = x ] || [ \"${all_proxy+x}\" = x ]; then printf '{\"bad\":true}\n200'; else printf '{\"clean\":true}\n200'; fi",
            None,
        );
        assert_eq!(
            invoke(&fixture, "request-secret").unwrap(),
            json!({"clean": true})
        );
    }

    #[test]
    fn bounds_process_lifetime_and_reaps_timed_out_child() {
        let fixture = Fixture::new(
            "echo $$ > \"${0%/*}/pid\"\ncat > /dev/null\nexec sleep 30",
            None,
        );
        let start = Instant::now();
        let error = invoke(&fixture, "test-secret").unwrap_err();
        assert_eq!(error.code, "JEV_TIMEOUT");
        assert!(start.elapsed() < Duration::from_secs(10));

        let pid = fs::read_to_string(fixture.path("pid")).expect("fake child wrote its pid");
        let status = std::process::Command::new("/bin/kill")
            .args(["-0", pid.trim()])
            .stderr(std::process::Stdio::null())
            .status()
            .expect("check timed-out process");
        assert!(!status.success(), "timed-out child should have been reaped");
    }

    #[test]
    fn bounds_pipe_cleanup_when_a_descendant_inherits_pipes() {
        let fixture = Fixture::new("cat > /dev/null\n(sleep 30) &\nexit 0", None);
        let start = Instant::now();
        let error = invoke(&fixture, "test-secret").unwrap_err();
        assert_eq!(error.code, "JEV_REQUEST_FAILED");
        assert!(
            start.elapsed() < Duration::from_secs(2),
            "pipe cleanup elapsed: {:?}",
            start.elapsed()
        );
    }

    #[test]
    fn maps_curl_timeout_and_sanitizes_stderr() {
        let timeout = Fixture::new("cat > /dev/null\nexit 28", None);
        assert_eq!(error_code(invoke(&timeout, "secret")), "JEV_TIMEOUT");

        let failure = Fixture::new(
            "cat > /dev/null\nprintf '%s\\n' 'stderr-secret-body' >&2\nexit 7",
            None,
        );
        let error = invoke(&failure, "request-secret").unwrap_err();
        assert_eq!(error.code, "JEV_REQUEST_FAILED");
        assert!(!error.to_string().contains("stderr-secret-body"));
        assert!(!error.to_string().contains("request-secret"));
    }

    #[test]
    fn sanitizes_low_level_process_failures() {
        let fixture = Fixture {
            dir: std::env::temp_dir().join("jev-missing-executable-test"),
            executable: std::env::temp_dir().join("jev-curl-definitely-missing"),
        };
        assert_eq!(error_code(invoke(&fixture, "secret")), "JEV_REQUEST_FAILED");
    }
}
