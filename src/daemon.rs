use crate::native::{Canceller, Helper};
use crate::protocol::{
    read_message, response_for, Error, Result, Scope, PROTOCOL_VERSION, USER_PAUSED_PUBLIC_MESSAGE,
};
use crate::runtime::{helper_path, Runtime};
use crate::service::Service;
use serde::Deserialize;
use serde_json::{json, Value};
use std::fs;
use std::io::{BufReader, Write};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Envelope {
    protocol_version: u32,
    #[serde(default)]
    scope: Scope,
    request: Value,
}

pub fn call(runtime: &Runtime, request: Value) -> Result<Value> {
    runtime.validate()?;
    let mut stream =
        UnixStream::connect(&runtime.socket).map_err(|e| Error::io("无法连接后台进程", e))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(55)))
        .and_then(|_| stream.set_write_timeout(Some(Duration::from_secs(5))))
        .map_err(|e| Error::io("无法设置连接超时", e))?;
    let mut bytes = serde_json::to_vec(&client_envelope(runtime.scope, request))
        .map_err(|_| Error::new("PROTOCOL_ERROR", "请求编码失败"))?;
    bytes.push(b'\n');
    stream
        .write_all(&bytes)
        .map_err(|e| Error::io("无法发送请求", e))?;
    let value = read_message(&mut BufReader::new(stream))?
        .ok_or_else(|| Error::new("DAEMON_UNAVAILABLE", "后台进程未返回结果"))?;
    if value["protocolVersion"] != PROTOCOL_VERSION || !value["ok"].is_boolean() {
        return Err(Error::new(
            "PROTOCOL_ERROR",
            "后台进程协议版本或响应格式无效",
        ));
    }
    validate_response_scope(&value, runtime.scope)?;
    if value["ok"] == false {
        return Err(relayed_error(&value["error"])?);
    }
    let mut object = value
        .as_object()
        .cloned()
        .ok_or_else(|| Error::new("PROTOCOL_ERROR", "后台进程未返回对象"))?;
    object.remove("ok");
    object.remove("protocolVersion");
    object.remove("scope");
    Ok(Value::Object(object))
}
fn client_envelope(scope: Scope, request: Value) -> Value {
    let mut envelope = json!({"protocolVersion":PROTOCOL_VERSION,"request":request});
    if scope == Scope::Desktop {
        envelope["scope"] = json!(scope.name());
    }
    envelope
}

fn validate_response_scope(value: &Value, expected: Scope) -> Result<()> {
    let response_scope = value
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("chrome");
    if response_scope == expected.name() {
        Ok(())
    } else {
        Err(Error::new(
            "SCOPE_MISMATCH",
            "后台进程桌面控制模式与当前 CLI 不一致",
        ))
    }
}

fn relayed_error(value: &Value) -> Result<Error> {
    if value["code"] == "FOCUS_LOST" && value["reason"] == "USER_PAUSED" {
        return Ok(Error::new("USER_PAUSED", USER_PAUSED_PUBLIC_MESSAGE));
    }
    serde_json::from_value(value.clone())
        .map_err(|_| Error::new("PROTOCOL_ERROR", "后台进程错误格式无效"))
}

fn available(runtime: &Runtime) -> Result<bool> {
    if !runtime.root.exists() {
        return Ok(false);
    }
    runtime.validate()?;
    match UnixStream::connect(&runtime.socket) {
        Ok(_) => Ok(true),
        Err(e)
            if matches!(
                e.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            ) =>
        {
            Ok(false)
        }
        Err(e) => Err(Error::io("无法探测后台进程", e)),
    }
}
pub fn status(runtime: &Runtime) -> Result<Value> {
    if available(runtime)? {
        call(runtime, json!({"action":"status"}))
    } else {
        Ok(json!({"running":false,"connected":false}))
    }
}
pub fn start(runtime: &Runtime) -> Result<Value> {
    if available(runtime)? {
        call(runtime, json!({"action":"status"}))?;
        return Ok(json!({"running":true}));
    }
    helper_path(runtime.scope)?;
    runtime.prepare()?;
    let stderr = runtime.log()?;
    let executable = std::env::current_exe().map_err(|e| Error::io("无法定位 CLI", e))?;
    let mut child = Command::new(executable)
        .args(["daemon", "run"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(stderr)
        .spawn()
        .map_err(|e| Error::io("无法启动后台进程", e))?;
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if available(runtime)? {
            return Ok(json!({"running":true}));
        }
        if child
            .try_wait()
            .map_err(|e| Error::io("无法检查后台进程", e))?
            .is_some()
        {
            // 启动失败者不限制为 200ms：获锁者可能仍在初始化，等待同一 8s 截止点。
            match runtime.lock() {
                Err(error) if error.code == "DAEMON_ALREADY_RUNNING" => {}
                _ => {
                    return Err(Error::new(
                        "DAEMON_START_FAILED",
                        "后台进程启动失败；请检查私有运行目录中的 daemon.log",
                    ))
                }
            }
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::new("DAEMON_START_FAILED", "后台进程启动超时"));
        }
        thread::sleep(Duration::from_millis(40));
    }
}
pub fn stop(runtime: &Runtime) -> Result<Value> {
    if !available(runtime)? {
        return Ok(json!({"running":false}));
    }
    call(runtime, json!({"action":"daemon_stop"}))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while available(runtime)? {
        if Instant::now() >= deadline {
            return Err(Error::new(
                "DAEMON_STOP_TIMEOUT",
                "后台进程尚未退出，请检查 daemon.log",
            ));
        }
        thread::sleep(Duration::from_millis(30));
    }
    Ok(json!({"running":false}))
}
struct SocketGuard(std::path::PathBuf);
impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub fn run(runtime: &Runtime) -> Result<Value> {
    runtime.prepare()?;
    let _lock = runtime.lock()?;
    if let Ok(meta) = fs::symlink_metadata(&runtime.socket) {
        if !meta.file_type().is_socket() {
            return Err(Error::new(
                "INSECURE_RUNTIME",
                "socket 路径被其他文件占用，拒绝删除",
            ));
        }
        fs::remove_file(&runtime.socket).map_err(|e| Error::io("无法清理旧 socket", e))?;
    }
    for entry in fs::read_dir(&runtime.frames).map_err(|e| Error::io("无法检查截图目录", e))?
    {
        let entry = entry.map_err(|e| Error::io("无法读取截图目录", e))?;
        if entry.file_type().is_ok_and(|t| t.is_file())
            && entry.path().extension().is_some_and(|v| v == "jpg")
        {
            let _ = fs::remove_file(entry.path());
        }
    }
    let helper = Helper::spawn_for_scope(&helper_path(runtime.scope)?, runtime.scope)?;
    let canceller = helper.canceller();
    let service = Arc::new(Mutex::new(Service::with_scope(
        helper,
        runtime.frames.clone(),
        runtime.scope,
    )));
    let stopping = Arc::new(AtomicBool::new(false));
    let listener =
        UnixListener::bind(&runtime.socket).map_err(|e| Error::io("无法创建本地 socket", e))?;
    let _socket = SocketGuard(runtime.socket.clone());
    fs::set_permissions(&runtime.socket, fs::Permissions::from_mode(0o600))
        .map_err(|e| Error::io("无法保护 socket", e))?;
    listener
        .set_nonblocking(true)
        .map_err(|e| Error::io("无法设置 socket 模式", e))?;
    let mut workers: Vec<thread::JoinHandle<()>> = Vec::new();
    while !stopping.load(Ordering::Acquire) {
        let mut index = 0;
        while index < workers.len() {
            if workers[index].is_finished() {
                let _ = workers.swap_remove(index).join();
            } else {
                index += 1;
            }
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                // macOS 的 accept 可能继承 listener 的非阻塞标志；大回执不能在 8KiB 后因 EAGAIN 被截断。
                if configure_client_stream(&stream).is_err() {
                    continue;
                }
                if workers.len() >= 16 {
                    let _ = write_response(
                        &mut stream,
                        Err(Error::new("BUSY", "本地连接过多，请稍后重试")),
                        runtime.scope,
                    );
                    continue;
                }
                let service = service.clone();
                let stopping = stopping.clone();
                let cancel = canceller.clone();
                let scope = runtime.scope;
                workers.push(thread::spawn(move || {
                    let result = handle(&stream, &service, &stopping, &cancel, scope);
                    let _ = write_response(&mut stream, result, scope);
                }));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10))
            }
            Err(e) => {
                canceller.terminate();
                return Err(Error::io("无法接受本地连接", e));
            }
        }
    }
    canceller.terminate();
    for worker in workers {
        let _ = worker.join();
    }
    drop(service);
    Ok(json!({"running":false}))
}
fn configure_client_stream(stream: &UnixStream) -> Result<()> {
    stream
        .set_nonblocking(false)
        .and_then(|_| stream.set_read_timeout(Some(Duration::from_secs(2))))
        .and_then(|_| stream.set_write_timeout(Some(Duration::from_secs(2))))
        .map_err(|e| Error::io("无法配置本地连接", e))
}

fn handle(
    stream: &UnixStream,
    service: &Mutex<Service<Helper>>,
    stopping: &AtomicBool,
    canceller: &Canceller,
    scope: Scope,
) -> Result<Value> {
    let request =
        read_message(&mut BufReader::new(stream))?.ok_or_else(|| Error::invalid("请求为空"))?;
    let envelope: Envelope = serde_json::from_value(request)
        .map_err(|_| Error::new("PROTOCOL_ERROR", "请求信封格式无效"))?;
    if envelope.protocol_version != PROTOCOL_VERSION {
        return Err(Error::new("PROTOCOL_VERSION_MISMATCH", "不支持的协议版本"));
    }
    if envelope.scope != scope {
        return Err(Error::new(
            "SCOPE_MISMATCH",
            "请求桌面控制模式与后台进程不一致",
        ));
    }
    if envelope.request == json!({"action":"daemon_stop"}) {
        stopping.store(true, Ordering::Release);
        canceller.terminate();
        return Ok(json!({"stopping":true}));
    }
    if stopping.load(Ordering::Acquire) {
        return Err(Error::new("DAEMON_STOPPING", "后台进程正在停止"));
    }
    let mut service = service
        .try_lock()
        .map_err(|_| Error::new("BUSY", "已有动作正在执行，不会排队或重放输入"))?;
    let result = service.execute(envelope.request);
    if result.as_ref().err().is_some_and(|e| {
        matches!(
            e.code.as_str(),
            "HELPER_EOF" | "HELPER_TIMEOUT" | "HELPER_PROTOCOL"
        )
    }) {
        stopping.store(true, Ordering::Release);
    }
    result
}
fn write_response(stream: &mut UnixStream, result: Result<Value>, scope: Scope) -> Result<()> {
    let mut bytes = serde_json::to_vec(&response_for(result, scope))
        .map_err(|_| Error::new("PROTOCOL_ERROR", "响应编码失败"))?;
    bytes.push(b'\n');
    stream
        .write_all(&bytes)
        .map_err(|e| Error::io("无法写入本地响应", e))
}

#[cfg(test)]
mod relayed_error_tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn given_legacy_chrome_daemon_when_building_client_envelope_then_omit_scope() {
        assert_eq!(
            client_envelope(Scope::Chrome, json!({"action":"status"})),
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "request": {"action":"status"}
            })
        );
        assert_eq!(
            client_envelope(Scope::Desktop, json!({"action":"status"}))["scope"],
            "desktop"
        );
    }

    #[test]
    fn given_desktop_stop_envelope_when_chrome_daemon_handles_it_then_scope_mismatch_does_not_stop_daemon(
    ) {
        let root = std::env::temp_dir().join(format!(
            "scope-stop-{}",
            crate::protocol::random_id().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let helper_path = root.join("helper.sh");
        fs::write(&helper_path, "#!/bin/sh\nsleep 5\n").unwrap();
        fs::set_permissions(&helper_path, fs::Permissions::from_mode(0o700)).unwrap();
        let helper = Helper::with_timeout(&helper_path, Duration::from_secs(1)).unwrap();
        let canceller = helper.canceller();
        let service = Arc::new(Mutex::new(Service::new(helper, root.join("frames"))));
        let stopping = AtomicBool::new(false);
        let (server, mut client) = UnixStream::pair().unwrap();
        serde_json::to_writer(
            &mut client,
            &json!({"protocolVersion":PROTOCOL_VERSION,"scope":"desktop","request":{"action":"daemon_stop"}}),
        ).unwrap();
        client.write_all(b"\n").unwrap();

        let error = handle(&server, &service, &stopping, &canceller, Scope::Chrome).unwrap_err();

        assert_eq!(error.code, "SCOPE_MISMATCH");
        assert!(!stopping.load(Ordering::Acquire));
        drop(service);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn given_legacy_envelope_without_scope_when_decoding_then_treat_it_as_chrome() {
        let envelope: Envelope = serde_json::from_value(json!({
            "protocolVersion": PROTOCOL_VERSION,
            "request": {"action":"daemon_stop"}
        }))
        .unwrap();
        assert_eq!(envelope.scope, Scope::Chrome);
        let legacy_response = json!({"protocolVersion":PROTOCOL_VERSION,"ok":true});
        assert!(validate_response_scope(&legacy_response, Scope::Chrome).is_ok());
    }

    #[test]
    fn given_desktop_daemon_response_without_scope_when_relaying_then_reject_as_mismatch() {
        let runtime = Runtime {
            root: PathBuf::from("/tmp/desktop-runtime"),
            socket: PathBuf::from("/tmp/desktop-runtime/daemon.sock"),
            frames: PathBuf::from("/tmp/desktop-runtime/frames"),
            scope: Scope::Desktop,
        };
        let value = json!({"protocolVersion":PROTOCOL_VERSION,"ok":true,"running":true});
        assert_eq!(
            validate_response_scope(&value, runtime.scope)
                .unwrap_err()
                .code,
            "SCOPE_MISMATCH"
        );
        let desktop = json!({"protocolVersion":PROTOCOL_VERSION,"scope":"desktop","ok":true});
        assert!(validate_response_scope(&desktop, runtime.scope).is_ok());
    }

    #[test]
    fn given_response_larger_than_socket_buffer_when_sending_then_preserve_whole_json_line() {
        use std::io::Read;
        let (mut sender, mut receiver) = UnixStream::pair().unwrap();
        sender.set_nonblocking(true).unwrap();
        configure_client_stream(&sender).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let value = json!({"ocr":{"items":[{"text":"字".repeat(6000)}]}});
        let expected = response_for(Ok(value.clone()), Scope::Chrome);
        let writer =
            std::thread::spawn(move || write_response(&mut sender, Ok(value), Scope::Chrome));
        std::thread::sleep(Duration::from_millis(50));
        let mut bytes = Vec::new();
        receiver.read_to_end(&mut bytes).unwrap();
        writer.join().unwrap().unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&bytes).unwrap(), expected);
        assert_eq!(bytes.last(), Some(&b'\n'));
    }

    #[test]
    fn given_focus_lost_with_user_paused_reason_when_decoding_then_restore_internal_code_safely() {
        let error = relayed_error(&json!({
            "code":"FOCUS_LOST",
            "reason":"USER_PAUSED",
            "message":"untrusted helper message"
        }))
        .unwrap();
        assert_eq!(error.code, "USER_PAUSED");
        assert_eq!(error.message, USER_PAUSED_PUBLIC_MESSAGE);
    }

    #[test]
    fn given_focus_lost_without_reason_when_decoding_then_keep_code_even_with_paused_copy() {
        let error = relayed_error(&json!({
            "code":"FOCUS_LOST",
            "message":USER_PAUSED_PUBLIC_MESSAGE
        }))
        .unwrap();
        assert_eq!(error.code, "FOCUS_LOST");
        assert_eq!(error.message, USER_PAUSED_PUBLIC_MESSAGE);
    }

    #[test]
    fn given_other_focus_lost_reason_when_decoding_then_keep_original_error() {
        let error = relayed_error(&json!({
            "code":"FOCUS_LOST",
            "reason":"OTHER",
            "message":"焦点已变化"
        }))
        .unwrap();
        assert_eq!(error.code, "FOCUS_LOST");
        assert_eq!(error.message, "焦点已变化");
    }
}
