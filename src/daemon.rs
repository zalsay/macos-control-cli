use crate::native::{Canceller, Helper};
use crate::protocol::{
    read_message, response_for, Error, Result, Scope, PROTOCOL_VERSION, USER_PAUSED_PUBLIC_MESSAGE,
};
use crate::runtime::{helper_path, Runtime};
use crate::service::Service;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::{BufReader, Write};
use std::os::unix::fs::FileTypeExt;
#[cfg(test)]
use std::os::unix::fs::PermissionsExt;
#[cfg(target_os = "macos")]
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
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
    #[serde(default)]
    remote: Option<RemoteContext>,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum RemoteContext {
    Claim {
        owner: String,
    },
    Read {
        owner: String,
        operation: String,
    },
    Call {
        owner: String,
        operation: String,
    },
    Reserve {
        owner: String,
        operation: String,
    },
    Abandon {
        owner: String,
        operation: String,
    },
    Pause {
        owner: String,
        operation: Option<String>,
    },
    State {
        owner: String,
    },
    Release {
        owner: String,
    },
    Recover {
        owner: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        daemon_pid: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        helper_pid: Option<u32>,
    },
}
#[derive(Clone, Copy, PartialEq, Eq)]
struct OwnerIdentity {
    pid: libc::pid_t,
    start_sec: u64,
    start_usec: u64,
}

#[cfg(target_os = "macos")]
fn process_identity(pid: libc::pid_t) -> Result<OwnerIdentity> {
    if pid <= 0 || unsafe { libc::kill(pid, 0) } != 0 {
        return Err(control_error("RECOVERY_REQUIRED"));
    }
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = std::mem::size_of::<libc::proc_bsdinfo>();
    let result = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            size as libc::c_int,
        )
    };
    if result != size as libc::c_int {
        return Err(control_error("RECOVERY_REQUIRED"));
    }
    let info = unsafe { info.assume_init() };
    if info.pbi_pid != pid as u32
        || info.pbi_uid != unsafe { libc::geteuid() }
        || !matches!(info.pbi_status, libc::SRUN | libc::SSLEEP)
        // PROC_FLAG_INEXIT from Darwin's sys/proc_info.h.
        || info.pbi_flags & 0x4 != 0
        || info.pbi_start_tvsec == 0
    {
        return Err(control_error("RECOVERY_REQUIRED"));
    }
    Ok(OwnerIdentity {
        pid,
        start_sec: info.pbi_start_tvsec,
        start_usec: info.pbi_start_tvusec,
    })
}
#[cfg(not(target_os = "macos"))]
fn process_identity(_: libc::pid_t) -> Result<OwnerIdentity> {
    Err(control_error("UNSUPPORTED_PLATFORM"))
}

#[cfg(target_os = "macos")]
fn peer_identity(stream: &UnixStream) -> Result<OwnerIdentity> {
    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut len,
        )
    };
    if result != 0 || len as usize != std::mem::size_of::<libc::pid_t>() {
        return Err(control_error("RECOVERY_REQUIRED"));
    }
    process_identity(pid)
}
#[cfg(not(target_os = "macos"))]
fn peer_identity(_: &UnixStream) -> Result<OwnerIdentity> {
    Err(control_error("UNSUPPORTED_PLATFORM"))
}

struct ActiveOperation {
    id: String,
    cancelled: Arc<AtomicBool>,
    epoch: u64,
    executing: bool,
}
struct CompletedOperation {
    id: String,
    lease: Option<u64>,
}
#[derive(Default)]
struct RemoteControl {
    owner: Option<String>,
    owner_identity: Option<OwnerIdentity>,
    owner_dead: bool,
    watchdog_pause_confirmed: bool,
    active: Option<ActiveOperation>,
    active_read: Option<String>,
    recovery: bool,
    paused_epoch: Option<u64>,
    paused_lease: Option<u64>,
    high_water: u64,
    last_completed: Option<CompletedOperation>,
}
fn control_error(code: &str) -> Error {
    Error::new(code, "远程控制所有权或原生暂停状态不允许此操作")
}
fn valid_capability(value: &str) -> bool {
    (1..=128).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_graphic())
}
fn native_state(canceller: &Canceller) -> Result<Value> {
    let state = canceller.transport("transport-state")?;
    if state["transportPauseVersion"] != 1
        || !state["paused"].is_boolean()
        || !state["recoveryRequired"].is_boolean()
        || state["inputEpoch"].as_u64().is_none()
        || !state
            .get("lease")
            .is_some_and(|v| v.is_null() || v.as_u64().is_some())
        || !matches!(
            state["phase"].as_str(),
            Some("awaitingCountdown" | "countdown" | "running" | "paused")
        )
        || (state["paused"] == true) != (state["phase"] == "paused")
    {
        return Err(control_error("HELPER_UPGRADE_REQUIRED"));
    }
    Ok(state)
}
fn pause_transport(canceller: &Canceller) -> Result<Value> {
    let receipt = canceller
        .transport("transport-pause")
        .map_err(|_| control_error("CANCEL_UNCONFIRMED"))?;
    if receipt["transportPauseVersion"] != 1
        || receipt["paused"] != true
        || receipt["phase"] != "paused"
        || receipt["recovered"] != false
        || receipt["recoveryRequired"] != true
        || receipt["inputEpoch"].as_u64().is_none()
        || !receipt
            .get("lease")
            .is_some_and(|v| v.is_null() || v.as_u64().is_some())
    {
        return Err(control_error("CANCEL_UNCONFIRMED"));
    }
    Ok(receipt)
}
fn remember_pause(control: &mut RemoteControl, state: &Value) {
    if !control.recovery || control.paused_epoch.is_none() {
        control.paused_epoch = state["inputEpoch"].as_u64();
        control.paused_lease = state["lease"].as_u64();
    }
    control.recovery = true;
}
fn reconcile(control: &mut RemoteControl, state: &Value) {
    if control.recovery
        && !control.owner_dead
        && state["paused"] == false
        && state["recoveryRequired"] == false
        && control.paused_lease.is_some()
        && state["lease"].as_u64() == control.paused_lease
        && state["inputEpoch"]
            .as_u64()
            .zip(control.paused_epoch)
            .is_some_and(|(new, old)| new > old)
        && matches!(state["phase"].as_str(), Some("countdown" | "running"))
    {
        control.recovery = false;
        control.paused_epoch = None;
        control.paused_lease = None;
    }
}

pub fn call(runtime: &Runtime, request: Value) -> Result<Value> {
    call_context(runtime, request, None)
}
fn call_context(runtime: &Runtime, request: Value, remote: Option<RemoteContext>) -> Result<Value> {
    runtime.validate()?;
    let mut stream =
        UnixStream::connect(&runtime.socket).map_err(|e| Error::io("无法连接后台进程", e))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(55)))
        .and_then(|_| stream.set_write_timeout(Some(Duration::from_secs(5))))
        .map_err(|e| Error::io("无法设置连接超时", e))?;
    let mut envelope = client_envelope(runtime.scope, request);
    if let Some(remote) = remote {
        envelope["remote"] =
            serde_json::to_value(remote).map_err(|_| control_error("PROTOCOL_ERROR"))?;
    }
    let mut bytes =
        serde_json::to_vec(&envelope).map_err(|_| Error::new("PROTOCOL_ERROR", "请求编码失败"))?;
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
pub(crate) fn remote_read_only(request: &Value) -> bool {
    match request["action"].as_str() {
        Some("status" | "apps" | "windows" | "observe") => true,
        Some("permissions") => request.get("request").is_none_or(|v| v == false),
        _ => false,
    }
}
pub(crate) fn remote_read(
    runtime: &Runtime,
    owner: &str,
    operation: &str,
    request: Value,
) -> Result<Value> {
    call_context(
        runtime,
        request,
        Some(RemoteContext::Read {
            owner: owner.into(),
            operation: operation.into(),
        }),
    )
}
/// Claim an already-running daemon without starting or replacing its helper.
///
/// The Host must generate a fresh unpredictable owner capability for every
/// claim after release/recovery; do not reuse an earlier capability. Receipts
/// contain `owned`, `daemonPid`, and `helperPid`. Within this owner, operations
/// use nonzero canonical decimal u64 sequence strings, strictly increasing;
/// the Host passes the validated envelope sequence, never a peer-provided ID.
pub fn remote_claim(runtime: &Runtime, owner: &str) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::Claim {
            owner: owner.into(),
        }),
    )
}
/// Dispatch with the validated envelope sequence encoded as a canonical
/// decimal u64. Sequences at or below the owner's high-water mark are rejected.
pub fn remote_call(
    runtime: &Runtime,
    owner: &str,
    operation: &str,
    request: Value,
) -> Result<Value> {
    call_context(
        runtime,
        request,
        Some(RemoteContext::Call {
            owner: owner.into(),
            operation: operation.into(),
        }),
    )
}
pub(crate) fn remote_reserve(runtime: &Runtime, owner: &str, operation: &str) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::Reserve {
            owner: owner.into(),
            operation: operation.into(),
        }),
    )
}
pub(crate) fn remote_abandon(runtime: &Runtime, owner: &str, operation: &str) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::Abandon {
            owner: owner.into(),
            operation: operation.into(),
        }),
    )
}
/// Pause the matching live operation or the latest completed operation, only
/// when no newer operation exists and its original native lease still matches.
pub fn remote_pause(runtime: &Runtime, owner: &str, operation: Option<&str>) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::Pause {
            owner: owner.into(),
            operation: operation.map(str::to_owned),
        }),
    )
}
pub fn remote_control_state(runtime: &Runtime, owner: &str) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::State {
            owner: owner.into(),
        }),
    )
}
/// Release only an idle, owner-matched control whose Service has no connection
/// and whose native helper confirms no lease or pause. This also safely rolls
/// back a failed initial connect; it never invokes native cancel or recovery.
pub fn remote_release(runtime: &Runtime, owner: &str) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::Release {
            owner: owner.into(),
        }),
    )
}
pub fn remote_recover(runtime: &Runtime, owner: &str) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::Recover {
            owner: owner.into(),
            daemon_pid: None,
            helper_pid: None,
        }),
    )
}
/// Recover only if both expected process identities still match this daemon's
/// currently owned helper. For local Host recovery; never expose over WSS.
pub fn remote_recover_checked(
    runtime: &Runtime,
    owner: &str,
    daemon_pid: u32,
    helper_pid: u32,
) -> Result<Value> {
    call_context(
        runtime,
        json!({"action":"remote-control"}),
        Some(RemoteContext::Recover {
            owner: owner.into(),
            daemon_pid: Some(daemon_pid),
            helper_pid: Some(helper_pid),
        }),
    )
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
        .env_remove("JEV_API_KEY")
        .env_remove("OPENROUTER_API_KEY")
        .env_remove("TYPESAFE_API_KEY")
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
fn check_owner_liveness(registry: &mut RemoteControl, canceller: &Canceller) {
    let Some(owner) = registry.owner_identity else {
        return;
    };
    if !registry.owner_dead && process_identity(owner.pid).is_ok_and(|current| current == owner) {
        return;
    }
    registry.owner_dead = true;
    registry.recovery = true;
    if let Some(active) = &registry.active {
        active.cancelled.store(true, Ordering::Release);
    }
    if !registry.watchdog_pause_confirmed {
        if let Ok(receipt) = pause_transport(canceller) {
            remember_pause(registry, &receipt);
            registry.watchdog_pause_confirmed = true;
        }
    }
}
struct WatchdogGuard {
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Drop for WatchdogGuard {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn start_owner_watchdog(control: Arc<Mutex<RemoteControl>>, canceller: Canceller) -> WatchdogGuard {
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = stop.clone();
    let worker = thread::spawn(move || {
        while !worker_stop.load(Ordering::Acquire) {
            if let Ok(mut registry) = control.try_lock() {
                check_owner_liveness(&mut registry, &canceller);
            }
            thread::sleep(Duration::from_millis(25));
        }
    });
    WatchdogGuard {
        stop,
        worker: Some(worker),
    }
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
    let stopping = Arc::new(AtomicBool::new(false));
    let control = Arc::new(Mutex::new(RemoteControl::default()));
    let service = Arc::new(Mutex::new(
        Service::with_scope(helper, runtime.frames.clone(), runtime.scope).with_decider(Box::new(
            crate::jev::JevClient::with_cancellation(stopping.clone()),
        )),
    ));
    let listener = runtime.bind_listener()?;
    let _socket = SocketGuard(runtime.socket.clone());
    let _watchdog = start_owner_watchdog(control.clone(), canceller.clone());
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
                let control = control.clone();
                let scope = runtime.scope;
                workers.push(thread::spawn(move || {
                    let result = handle(&stream, &service, &stopping, &cancel, &control, scope);
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
    stopping: &Arc<AtomicBool>,
    canceller: &Canceller,
    control: &Mutex<RemoteControl>,
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
    if envelope.request == json!({"action":"daemon_stop"}) && envelope.remote.is_none() {
        if let Ok(control) = control.lock() {
            if let Some(active) = &control.active {
                active.cancelled.store(true, Ordering::Release);
            }
        }
        stopping.store(true, Ordering::Release);
        canceller.terminate();
        return Ok(json!({"stopping":true}));
    }
    if stopping.load(Ordering::Acquire) {
        return Err(Error::new("DAEMON_STOPPING", "后台进程正在停止"));
    }
    if let Some(context) = envelope.remote {
        let caller = peer_identity(stream)?;
        return handle_remote(
            context,
            envelope.request,
            service,
            stopping,
            canceller,
            control,
            caller,
        );
    }
    let registry = control
        .lock()
        .map_err(|_| control_error("CANCEL_UNCONFIRMED"))?;
    let action = envelope.request["action"].as_str().unwrap_or("");
    let read_only = matches!(action, "status" | "apps" | "windows")
        || (action == "permissions" && envelope.request["request"] != true);
    if registry.owner.is_some() && !read_only {
        return Err(control_error("BUSY"));
    }
    let mut service = service
        .try_lock()
        .map_err(|_| Error::new("BUSY", "已有动作正在执行，不会排队或重放输入"))?;
    drop(registry);
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
fn next_sequence(registry: &RemoteControl, operation: &str) -> Result<u64> {
    let sequence = operation
        .parse::<u64>()
        .map_err(|_| control_error("OPERATION_REPLAY"))?;
    if sequence == 0 || sequence.to_string() != operation || sequence <= registry.high_water {
        return Err(control_error("OPERATION_REPLAY"));
    }
    Ok(sequence)
}
fn reserve_operation(
    registry: &mut RemoteControl,
    service: &Mutex<Service<Helper>>,
    canceller: &Canceller,
    operation: &str,
) -> Result<()> {
    if !valid_capability(operation) {
        return Err(control_error("NOT_OWNER"));
    }
    if registry.active.is_some() || registry.active_read.is_some() {
        return Err(control_error("BUSY"));
    }
    let sequence = next_sequence(registry, operation)?;
    let _service = service.try_lock().map_err(|_| control_error("BUSY"))?;
    let state = native_state(canceller).map_err(|_| {
        registry.recovery = true;
        control_error("CANCEL_UNCONFIRMED")
    })?;
    if state["paused"] == true {
        remember_pause(registry, &state);
        return Err(control_error("USER_PAUSED"));
    }
    reconcile(registry, &state);
    if registry.recovery || state["recoveryRequired"] == true {
        return Err(control_error("RECOVERY_REQUIRED"));
    }
    let epoch = state["inputEpoch"]
        .as_u64()
        .ok_or_else(|| control_error("CANCEL_UNCONFIRMED"))?;
    registry.high_water = sequence;
    registry.active = Some(ActiveOperation {
        id: operation.into(),
        cancelled: Arc::new(AtomicBool::new(false)),
        epoch,
        executing: false,
    });
    Ok(())
}
fn handle_remote(
    context: RemoteContext,
    request: Value,
    service: &Mutex<Service<Helper>>,
    stopping: &Arc<AtomicBool>,
    canceller: &Canceller,
    control: &Mutex<RemoteControl>,
    caller: OwnerIdentity,
) -> Result<Value> {
    let mut registry = control
        .lock()
        .map_err(|_| control_error("CANCEL_UNCONFIRMED"))?;
    let owner = match &context {
        RemoteContext::Claim { owner }
        | RemoteContext::Read { owner, .. }
        | RemoteContext::Call { owner, .. }
        | RemoteContext::Reserve { owner, .. }
        | RemoteContext::Abandon { owner, .. }
        | RemoteContext::Pause { owner, .. }
        | RemoteContext::State { owner }
        | RemoteContext::Release { owner }
        | RemoteContext::Recover { owner, .. } => owner,
    };
    if !valid_capability(owner) {
        return Err(control_error("NOT_OWNER"));
    }
    if matches!(context, RemoteContext::Claim { .. }) {
        if registry.owner.is_some() {
            return Err(control_error("BUSY"));
        }
        let service = service.try_lock().map_err(|_| control_error("BUSY"))?;
        if service.connected() {
            return Err(control_error("BUSY"));
        }
        let state = native_state(canceller)?;
        if state["paused"] == true || state["recoveryRequired"] == true || !state["lease"].is_null()
        {
            return Err(control_error("RECOVERY_REQUIRED"));
        }
        registry.owner = Some(owner.clone());
        registry.owner_identity = Some(caller);
        registry.owner_dead = false;
        registry.watchdog_pause_confirmed = false;
        registry.high_water = 0;
        registry.last_completed = None;
        return Ok(
            json!({"owned":true,"daemonPid":std::process::id(),"helperPid":canceller.helper_pid()?,"ownerPid":caller.pid}),
        );
    }
    if registry.owner.as_deref() != Some(owner.as_str()) {
        return Err(control_error("NOT_OWNER"));
    }
    let checked_recovery = matches!(
        &context,
        RemoteContext::Recover {
            daemon_pid: Some(_),
            ..
        } | RemoteContext::Recover {
            helper_pid: Some(_),
            ..
        }
    );
    if matches!(context, RemoteContext::Release { .. }) {
        // Release is intentionally side-effect-free on rejection. The independent
        // watchdog, not this request, handles a dead or unverifiable owner.
        let owner_alive = registry.owner_identity.is_some_and(|owner| {
            owner == caller && process_identity(owner.pid).is_ok_and(|current| current == owner)
        });
        if registry.owner_dead || !owner_alive {
            return Err(control_error("RECOVERY_REQUIRED"));
        }
    } else if !checked_recovery {
        check_owner_liveness(&mut registry, canceller);
    }
    if matches!(
        context,
        RemoteContext::Call { .. }
            | RemoteContext::Read { .. }
            | RemoteContext::Reserve { .. }
            | RemoteContext::Abandon { .. }
            | RemoteContext::Release { .. }
    ) && (registry.owner_dead || registry.owner_identity != Some(caller))
    {
        return Err(control_error("RECOVERY_REQUIRED"));
    }
    match context {
        RemoteContext::Claim { .. } => unreachable!(),
        RemoteContext::Read { operation, .. } => {
            if !remote_read_only(&request) {
                return Err(control_error("NOT_OWNER"));
            }
            if registry.active.is_some() || registry.active_read.is_some() {
                return Err(control_error("BUSY"));
            }
            let sequence = next_sequence(&registry, &operation)?;
            let state = native_state(canceller).map_err(|_| {
                registry.recovery = true;
                control_error("CANCEL_UNCONFIRMED")
            })?;
            if state["paused"] == true {
                remember_pause(&mut registry, &state);
            }
            reconcile(&mut registry, &state);
            let mut service = service.try_lock().map_err(|_| control_error("BUSY"))?;
            registry.high_water = sequence;
            registry.active_read = Some(operation.clone());
            registry.last_completed = None;
            drop(registry);
            // A pause can race the read after the state snapshot. Never let a
            // read-side window error run ordinary cancel and destroy a lease.
            let result = service.execute_remote_read(request, true);
            drop(service);
            let mut registry = control
                .lock()
                .map_err(|_| control_error("CANCEL_UNCONFIRMED"))?;
            if registry.active_read.as_deref() == Some(operation.as_str()) {
                registry.active_read = None;
            }
            match native_state(canceller) {
                Ok(state) => {
                    registry.last_completed = Some(CompletedOperation {
                        id: operation,
                        lease: state["lease"].as_u64(),
                    });
                    if state["paused"] == true {
                        remember_pause(&mut registry, &state);
                    }
                }
                Err(_) => {
                    registry.recovery = true;
                    registry.last_completed = None;
                }
            }
            if result.as_ref().err().is_some_and(|e| {
                matches!(
                    e.code.as_str(),
                    "WINDOW_UNAVAILABLE"
                        | "CHROME_WINDOW_UNAVAILABLE"
                        | "HELPER_EOF"
                        | "HELPER_TIMEOUT"
                        | "HELPER_PROTOCOL"
                )
            }) {
                registry.recovery = true;
            }
            result
        }
        RemoteContext::Reserve { operation, .. } => {
            reserve_operation(&mut registry, service, canceller, &operation)?;
            Ok(json!({"reserved":true}))
        }
        RemoteContext::Abandon { operation, .. } => {
            if !registry
                .active
                .as_ref()
                .is_some_and(|a| a.id == operation && !a.executing)
            {
                return Err(control_error("NOT_OWNER"));
            }
            registry.active = None;
            Ok(json!({"abandoned":true}))
        }
        RemoteContext::Pause { operation, .. } => {
            if let Some(expected) = operation {
                if let Some(active) = &registry.active {
                    if active.id != expected {
                        return Err(control_error("NOT_OWNER"));
                    }
                } else if let Some(read) = &registry.active_read {
                    if read != &expected {
                        return Err(control_error("NOT_OWNER"));
                    }
                } else {
                    let completed = registry
                        .last_completed
                        .as_ref()
                        .ok_or_else(|| control_error("NOT_OWNER"))?;
                    if completed.id != expected
                        || expected.parse::<u64>().ok() != Some(registry.high_water)
                    {
                        return Err(control_error("NOT_OWNER"));
                    }
                    let completed_lease = completed.lease;
                    let state = native_state(canceller).map_err(|_| {
                        registry.recovery = true;
                        control_error("CANCEL_UNCONFIRMED")
                    })?;
                    if state["lease"].as_u64() != completed_lease {
                        return Err(control_error("NOT_OWNER"));
                    }
                }
            }
            registry.recovery = true;
            if let Some(active) = &registry.active {
                active.cancelled.store(true, Ordering::Release);
            }
            let receipt = pause_transport(canceller)?;
            remember_pause(&mut registry, &receipt);
            Ok(receipt)
        }
        RemoteContext::State { .. } => {
            let mut state = native_state(canceller).map_err(|_| {
                registry.recovery = true;
                control_error("CANCEL_UNCONFIRMED")
            })?;
            if state["paused"] == true {
                remember_pause(&mut registry, &state);
            }
            reconcile(&mut registry, &state);
            state["recoveryRequired"] =
                json!(registry.recovery || state["recoveryRequired"] == true);
            Ok(state)
        }
        RemoteContext::Release { .. } => {
            if registry.active.is_some() || registry.active_read.is_some() {
                return Err(control_error("BUSY"));
            }
            let service = service.try_lock().map_err(|_| control_error("BUSY"))?;
            let state = native_state(canceller).map_err(|_| {
                registry.recovery = true;
                control_error("CANCEL_UNCONFIRMED")
            })?;
            if service.connected()
                || registry.recovery
                || state["paused"] == true
                || state["recoveryRequired"] == true
                || !state["lease"].is_null()
                || state["phase"] != "awaitingCountdown"
            {
                return Err(control_error("RECOVERY_REQUIRED"));
            }
            registry.owner = None;
            registry.owner_identity = None;
            Ok(json!({"released":true}))
        }
        RemoteContext::Recover {
            daemon_pid,
            helper_pid,
            ..
        } => {
            match (daemon_pid, helper_pid) {
                (Some(expected_daemon), Some(expected_helper)) => {
                    // The registry lock remains held across both checks and the
                    // recovery, so neither owner nor active operation can change.
                    if registry.active.is_some() || registry.active_read.is_some() {
                        return Err(control_error("BUSY"));
                    }
                    let actual_helper = canceller
                        .helper_pid()
                        .map_err(|_| control_error("RECOVERY_REQUIRED"))?;
                    if expected_daemon != std::process::id() || expected_helper != actual_helper {
                        return Err(control_error("RECOVERY_REQUIRED"));
                    }
                    check_owner_liveness(&mut registry, canceller);
                }
                (None, None) => {}
                _ => return Err(control_error("RECOVERY_REQUIRED")),
            }
            registry.recovery = true;
            if registry.active_read.is_some() {
                let paused = pause_transport(canceller)?;
                remember_pause(&mut registry, &paused);
                return Err(control_error("BUSY"));
            }
            if let Some(active) = &registry.active {
                active.cancelled.store(true, Ordering::Release);
                let executing = active.executing;
                let paused = pause_transport(canceller)?;
                remember_pause(&mut registry, &paused);
                if executing {
                    return Err(control_error("BUSY"));
                }
                registry.active = None;
            }
            let mut service = service.try_lock().map_err(|_| control_error("BUSY"))?;
            native_state(canceller).map_err(|_| control_error("CANCEL_UNCONFIRMED"))?;
            let receipt = canceller
                .transport("transport-recover")
                .map_err(|_| control_error("CANCEL_UNCONFIRMED"))?;
            if receipt["transportPauseVersion"] != 1
                || receipt["paused"] != false
                || receipt["recoveryRequired"] != false
                || receipt["phase"] != "awaitingCountdown"
                || receipt["inputEpoch"].as_u64().is_none()
                || !receipt.get("lease").is_some_and(Value::is_null)
            {
                return Err(control_error("CANCEL_UNCONFIRMED"));
            }
            service.clear_remote_connection();
            *registry = RemoteControl::default();
            Ok(json!({"recovered":true}))
        }
        RemoteContext::Call { operation, .. } => {
            if registry.active.is_none() {
                reserve_operation(&mut registry, service, canceller, &operation)?;
            }
            let active = registry
                .active
                .as_mut()
                .ok_or_else(|| control_error("BUSY"))?;
            if active.id != operation || active.executing {
                return Err(control_error("BUSY"));
            }
            if active.cancelled.load(Ordering::Acquire) || registry.recovery {
                return Err(control_error("RECOVERY_REQUIRED"));
            }
            let mut service = service.try_lock().map_err(|_| control_error("BUSY"))?;
            let active = registry
                .active
                .as_mut()
                .ok_or_else(|| control_error("BUSY"))?;
            active.executing = true;
            let epoch = active.epoch;
            let cancelled = active.cancelled.clone();
            let is_connect = request["action"] == "connect";
            let owner_identity = registry
                .owner_identity
                .ok_or_else(|| control_error("RECOVERY_REQUIRED"))?;
            let owner_alive = Arc::new(move || {
                process_identity(owner_identity.pid).is_ok_and(|current| current == owner_identity)
            });
            drop(registry);
            let result = service.execute_remote(
                request,
                epoch,
                cancelled,
                stopping.clone(),
                owner_alive.clone(),
            );
            let still_connected = service.connected();
            drop(service);
            let mut registry = control
                .lock()
                .map_err(|_| control_error("CANCEL_UNCONFIRMED"))?;
            if !owner_alive() {
                registry.owner_dead = true;
                registry.recovery = true;
                if !registry.watchdog_pause_confirmed {
                    if let Ok(receipt) = pause_transport(canceller) {
                        remember_pause(&mut registry, &receipt);
                        registry.watchdog_pause_confirmed = true;
                    }
                }
            }
            let was_cancelled = registry
                .active
                .as_ref()
                .is_some_and(|a| a.id == operation && a.cancelled.load(Ordering::Acquire));
            if registry.active.as_ref().is_some_and(|a| a.id == operation) {
                registry.active = None;
            }
            let result = if was_cancelled && result.is_ok() {
                Err(Error::new("USER_PAUSED", USER_PAUSED_PUBLIC_MESSAGE))
            } else {
                result
            };
            let mut safe_failed_connect = false;
            match native_state(canceller) {
                Ok(state) => {
                    safe_failed_connect = is_connect
                        && result.is_err()
                        && !still_connected
                        && !registry.recovery
                        && !registry.owner_dead
                        && !was_cancelled
                        && state["paused"] == false
                        && state["recoveryRequired"] == false
                        && state["lease"].is_null()
                        && state["phase"] == "awaitingCountdown";
                    registry.last_completed = Some(CompletedOperation {
                        id: operation.clone(),
                        lease: state["lease"].as_u64(),
                    });
                }
                Err(_) => {
                    registry.recovery = true;
                    registry.last_completed = None;
                }
            }
            if result
                .as_ref()
                .err()
                .is_some_and(|e| e.code == "USER_PAUSED")
            {
                match native_state(canceller) {
                    Ok(state) => remember_pause(&mut registry, &state),
                    Err(_) => registry.recovery = true,
                }
            }
            if result.as_ref().err().is_some_and(|e| {
                matches!(
                    e.code.as_str(),
                    "HELPER_EOF" | "HELPER_TIMEOUT" | "HELPER_PROTOCOL"
                ) || (!safe_failed_connect
                    && matches!(
                        e.code.as_str(),
                        "WINDOW_UNAVAILABLE" | "CHROME_WINDOW_UNAVAILABLE"
                    ))
            }) {
                registry.recovery = true;
            }
            result
        }
    }
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
        let stopping = Arc::new(AtomicBool::new(false));
        let control = Mutex::new(RemoteControl::default());
        let (server, mut client) = UnixStream::pair().unwrap();
        serde_json::to_writer(
            &mut client,
            &json!({"protocolVersion":PROTOCOL_VERSION,"scope":"desktop","request":{"action":"daemon_stop"}}),
        ).unwrap();
        client.write_all(b"\n").unwrap();

        let error = handle(
            &server,
            &service,
            &stopping,
            &canceller,
            &control,
            Scope::Chrome,
        )
        .unwrap_err();

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

#[cfg(all(test, target_os = "macos"))]
mod remote_control_tests {
    use super::*;
    use crate::service::Native;
    use std::path::PathBuf;

    struct Fixture {
        service: Mutex<Service<Helper>>,
        cancel: Canceller,
        stopping: Arc<AtomicBool>,
        control: Arc<Mutex<RemoteControl>>,
        root: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            Self::with_decider(None)
        }
        fn with_decider(decider: Option<Box<dyn crate::jev::Decision>>) -> Self {
            Self::with_options(decider, false)
        }
        fn with_options(decider: Option<Box<dyn crate::jev::Decision>>, legacy: bool) -> Self {
            Self::with_startup_delay(decider, legacy, Duration::ZERO)
        }
        fn with_startup_delay(
            decider: Option<Box<dyn crate::jev::Decision>>,
            legacy: bool,
            delay: Duration,
        ) -> Self {
            let root = std::env::temp_dir().join(format!(
                "mcc-backend-{}",
                crate::protocol::random_id().unwrap()
            ));
            std::fs::create_dir(&root).unwrap();
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/fake-helper.sh");
            let wrapper = root.join("helper.sh");
            let quote = |value: &std::path::Path| {
                format!("'{}'", value.to_string_lossy().replace('\'', "'\\''"))
            };
            let startup = if delay.is_zero() {
                String::new()
            } else {
                format!("/bin/sleep {:.3}\n", delay.as_secs_f64())
            };
            std::fs::write(&wrapper, format!("#!/bin/sh\n{}unset COPIS_CHROME_RUNTIME_DIR COPIS_DESKTOP_RUNTIME_DIR\nexport MCC_FAKE_REMOTE_OCR=1\nexport MCC_FAKE_PREPARE_LEASE=1\nexport MCC_FAKE_TRANSPORT_UNSUPPORTED={}\nexport MCC_FAKE_REMOTE_TRACE={}\nexport MCC_FAKE_REMOTE_WINDOW_FAIL={}\nexport MCC_FAKE_REMOTE_RESUME={}\nexport MCC_FAKE_REMOTE_SLOW_WINDOW={}\nexec {} \"$@\"\n", startup, if legacy {1} else {0}, quote(&root.join("clicks")), quote(&root.join("fail-window")), quote(&root.join("resume")), quote(&root.join("slow-window")), quote(&path))).unwrap();
            std::fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
            let mut helper =
                Helper::with_timeout_for_scope(&wrapper, Scope::Chrome, Duration::from_secs(3))
                    .unwrap();
            // The fake process may not have entered its JSONL loop immediately
            // after spawn. Establish readiness within the fixture's 3s budget,
            // without retrying Claim or altering the production sideband timeout.
            let ready = helper
                .request(json!({"action":"permissions","request":false}))
                .unwrap();
            assert_eq!(ready["chromeAutomation"]["requested"], false);
            let cancel = helper.canceller();
            let stopping = Arc::new(AtomicBool::new(false));
            let decider = decider.unwrap_or_else(|| {
                Box::new(crate::jev::JevClient::with_cancellation(stopping.clone()))
            });
            let service = Service::new(helper, root.clone()).with_decider(decider);
            Self {
                service: Mutex::new(service),
                cancel,
                stopping,
                control: Arc::new(Mutex::new(RemoteControl::default())),
                root,
            }
        }
        fn invoke(&self, context: RemoteContext, request: Value) -> Result<Value> {
            handle_remote(
                context,
                request,
                &self.service,
                &self.stopping,
                &self.cancel,
                &self.control,
                process_identity(std::process::id() as libc::pid_t).unwrap(),
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    const OWNER: &str = "test-owner-capability";
    fn owner() -> String {
        OWNER.into()
    }
    #[test]
    fn owner_pause_locks_out_disconnect_and_recovery_requires_original_owner() {
        let f = Fixture::new();
        let claim = f
            .invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        assert_eq!(claim["owned"], true);
        assert!(claim["daemonPid"].as_u64().is_some());
        assert!(claim["helperPid"].as_u64().is_some());
        let connected = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap();
        let connection = connected["connectionId"].as_str().unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: "intruder".into(),
                    operation: None
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("99".into())
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        let paused = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: None,
                },
                json!({}),
            )
            .unwrap();
        assert_eq!(paused["paused"], true);
        assert_eq!(paused["lease"], 1);
        assert!(f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "2".into()
                },
                json!({"action":"disconnect","connectionId":connection})
            )
            .is_err());
        assert!(f
            .invoke(RemoteContext::Release { owner: owner() }, json!({}))
            .is_err());
        assert_eq!(
            f.invoke(
                RemoteContext::Recover {
                    owner: "intruder".into(),
                    daemon_pid: None,
                    helper_pid: None
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        assert_eq!(
            f.invoke(
                RemoteContext::Recover {
                    owner: owner(),
                    daemon_pid: None,
                    helper_pid: None
                },
                json!({})
            )
            .unwrap()["recovered"],
            true
        );
        assert_eq!(
            f.invoke(
                RemoteContext::Claim {
                    owner: "next-owner".into()
                },
                json!({})
            )
            .unwrap()["owned"],
            true
        );
    }
    #[test]
    fn claim_rejects_existing_local_connection_and_no_lease_pause_is_sticky() {
        let f = Fixture::new();
        f.service
            .lock()
            .unwrap()
            .execute(json!({"action":"connect","windowId":42}))
            .unwrap();
        assert_eq!(
            f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
                .unwrap_err()
                .code,
            "BUSY"
        );
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let state = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: None,
                },
                json!({}),
            )
            .unwrap();
        assert!(state["lease"].is_null());
        assert!(f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into()
                },
                json!({"action":"chrome-start"})
            )
            .is_err());
        assert!(f
            .invoke(
                RemoteContext::Claim {
                    owner: "another".into()
                },
                json!({})
            )
            .is_err());
    }
    #[test]
    fn pause_of_reserved_operation_blocks_late_dispatch() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into())
                },
                json!({})
            )
            .unwrap()["paused"],
            true
        );
        assert!(f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into()
                },
                json!({"action":"chrome-start"})
            )
            .is_err());
        f.invoke(
            RemoteContext::Abandon {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
        assert_eq!(
            f.invoke(RemoteContext::State { owner: owner() }, json!({}))
                .unwrap()["recoveryRequired"],
            true
        );
    }
    #[test]
    fn completed_operation_id_cannot_be_reused_to_target_a_later_action() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
        f.invoke(
            RemoteContext::Abandon {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
        assert!(f
            .invoke(
                RemoteContext::Reserve {
                    owner: owner(),
                    operation: "1".into()
                },
                json!({})
            )
            .is_err());
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "2".into(),
            },
            json!({}),
        )
        .unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into())
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        assert_eq!(
            f.invoke(RemoteContext::State { owner: owner() }, json!({}))
                .unwrap()["paused"],
            false
        );
    }
    struct SlowDecision {
        started: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    }
    impl crate::jev::Decision for SlowDecision {
        fn decide(&mut self, _: &str, _: &str, _: &Value) -> Result<Value> {
            self.started.send(()).unwrap();
            self.release.recv_timeout(Duration::from_secs(3)).unwrap();
            Ok(
                json!({"model":"vendor/model","answers":{"target":{"type":"choice","choice":"t0","confidence":0.98,"probabilities":{"t0":0.99,"none":0.01}}}}),
            )
        }
    }
    #[test]
    fn pause_ack_does_not_wait_for_service_lock_and_late_decision_cannot_click() {
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let f = Arc::new(Fixture::with_decider(Some(Box::new(SlowDecision {
            started: started_tx,
            release: release_rx,
        }))));
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let worker = f.clone();
        let thread = std::thread::spawn(move || {
            worker.invoke(RemoteContext::Call {owner:owner(),operation:"2".into()},json!({"action":"click-target","connectionId":connection,"target":"Save","jevKey":"fixture-secret","jevUrl":"https://example.com/decisions","jevModel":"vendor/model","jevProtocol":crate::jev::DECISION_PROTOCOL}))
        });
        started_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("decision must start");
        let start = Instant::now();
        let pause = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("2".into()),
                },
                json!({}),
            )
            .unwrap();
        assert_eq!(pause["paused"], true);
        assert!(
            start.elapsed() < Duration::from_secs(2),
            "pause must not wait for service or decision"
        );
        release_tx.send(()).unwrap();
        assert_eq!(thread.join().unwrap().unwrap_err().code, "USER_PAUSED");
        assert!(
            !f.root.join("clicks").exists(),
            "late decision must not dispatch input"
        );
    }
    #[test]
    fn claim_rejects_old_helper_without_cancel_fallback() {
        let f = Fixture::with_options(None, true);
        assert_eq!(
            f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
                .unwrap_err()
                .code,
            "HELPER_UPGRADE_REQUIRED"
        );
        assert!(f.control.lock().unwrap().owner.is_none());
    }
    #[test]
    fn pause_cancels_only_current_loopback_decision_not_daemon_stopping() {
        use std::io::Read;
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/decisions", listener.local_addr().unwrap());
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut buf = [0u8; 2048];
            assert!(stream.read(&mut buf).unwrap() > 0);
            started_tx.send(()).unwrap();
            let _ = stream.read(&mut buf);
        });
        let f = Arc::new(Fixture::new());
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let worker = f.clone();
        let operation = std::thread::spawn(move || {
            worker.invoke(RemoteContext::Call {owner:owner(),operation:"2".into()},json!({"action":"click-target","connectionId":connection,"target":"Save","jevKey":"fixture-secret","jevUrl":endpoint,"jevModel":"vendor/model","jevProtocol":crate::jev::DECISION_PROTOCOL}))
        });
        started_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("loopback model request must start");
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("2".into())
                },
                json!({})
            )
            .unwrap()["paused"],
            true
        );
        let error = operation.join().unwrap().unwrap_err();
        assert!(matches!(error.code.as_str(), "CANCELLED" | "USER_PAUSED"));
        assert!(!f.stopping.load(Ordering::Acquire));
        assert!(!f.root.join("clicks").exists());
        server.join().unwrap();
    }
    #[test]
    fn completed_response_lost_can_pause_only_most_recent_operation() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Call {
                owner: owner(),
                operation: "1".into(),
            },
            json!({"action":"connect","windowId":42}),
        )
        .unwrap();
        let paused = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into()),
                },
                json!({}),
            )
            .unwrap();
        assert_eq!(paused["paused"], true);
        assert_eq!(paused["lease"], 1);
    }
    #[test]
    fn old_completed_operation_cannot_pause_new_active_or_new_completed() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Call {
                owner: owner(),
                operation: "1".into(),
            },
            json!({"action":"connect","windowId":42}),
        )
        .unwrap();
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "2".into(),
            },
            json!({}),
        )
        .unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into())
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        f.invoke(
            RemoteContext::Call {
                owner: owner(),
                operation: "2".into(),
            },
            json!({"action":"status"}),
        )
        .unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into())
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("2".into())
                },
                json!({})
            )
            .unwrap()["paused"],
            true
        );
    }
    #[test]
    fn operation_counter_remains_usable_beyond_4096_and_rejects_stale() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        {
            let mut control = f.control.lock().unwrap();
            control.high_water = 4096;
        }
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "4097".into(),
            },
            json!({}),
        )
        .unwrap();
        f.invoke(
            RemoteContext::Abandon {
                owner: owner(),
                operation: "4097".into(),
            },
            json!({}),
        )
        .unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Reserve {
                    owner: owner(),
                    operation: "4000".into()
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "OPERATION_REPLAY"
        );
    }
    #[test]
    fn public_remote_api_uses_existing_fake_daemon_and_never_recreates_it() {
        const CHILD: &str = "MCC_REMOTE_BACKEND_TEST_CHILD";
        if std::env::var_os(CHILD).is_none() {
            let root = std::path::PathBuf::from(format!(
                "/tmp/mcc-backend-api-{}",
                &crate::protocol::random_id().unwrap()[..12]
            ));
            let helper = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/fake-helper.sh");
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "daemon::remote_control_tests::public_remote_api_uses_existing_fake_daemon_and_never_recreates_it", "--nocapture"])
                .env(CHILD, "1").env("COPIS_CHROME_RUNTIME_DIR", &root).env("COPIS_CHROME_HELPER", helper).env("MCC_CONFIG_DIR", root.join("config"))
                .output().unwrap();
            let _ = fs::remove_dir_all(&root);
            assert!(
                output.status.success(),
                "child failed: {} {}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }
        struct Running {
            runtime: Runtime,
            thread: Option<std::thread::JoinHandle<Result<Value>>>,
        }
        impl Drop for Running {
            fn drop(&mut self) {
                let _ = stop(&self.runtime);
                if let Some(thread) = self.thread.take() {
                    let _ = thread.join();
                }
            }
        }
        let runtime = Runtime::from_env_for_scope(Scope::Chrome).unwrap();
        let other = Runtime {
            root: runtime.root.clone(),
            frames: runtime.frames.clone(),
            socket: runtime.socket.clone(),
            scope: runtime.scope,
        };
        let thread = std::thread::spawn(move || run(&other));
        let guard = Running {
            runtime,
            thread: Some(thread),
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !guard.runtime.socket.exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(guard.runtime.socket.exists());
        let claimed = remote_claim(&guard.runtime, OWNER).unwrap();
        assert_eq!(claimed["owned"], true);
        let connected = crate::execution::execute_remote_request(
            json!({"action":"connect","windowId":42}),
            Scope::Chrome,
            OWNER,
            "1",
        )
        .unwrap();
        let connection = connected["connectionId"].as_str().unwrap();
        assert_eq!(
            call(
                &guard.runtime,
                json!({"action":"disconnect","connectionId":connection})
            )
            .unwrap_err()
            .code,
            "BUSY"
        );
        let paused = remote_pause(&guard.runtime, OWNER, Some("1")).unwrap();
        assert_eq!(paused["paused"], true);
        assert!(
            paused["lease"].is_null(),
            "connect alone does not create a native execution lease"
        );
        let observation = crate::execution::execute_remote_request(
            json!({"action":"observe","connectionId":connection}),
            Scope::Chrome,
            OWNER,
            "2",
        )
        .unwrap();
        assert!(observation["frameId"].is_string());
        assert_eq!(
            remote_control_state(&guard.runtime, OWNER).unwrap()["paused"],
            true
        );
        assert!(crate::execution::execute_remote_request(
            json!({"action":"observe","connectionId":connection}),
            Scope::Chrome,
            "intruder",
            "2"
        )
        .is_err());
        assert!(remote_release(&guard.runtime, OWNER).is_err());
        assert_eq!(
            remote_control_state(&guard.runtime, "intruder")
                .unwrap_err()
                .code,
            "NOT_OWNER"
        );
        assert_eq!(
            remote_recover(&guard.runtime, OWNER).unwrap()["recovered"],
            true
        );
        assert_eq!(
            remote_claim(&guard.runtime, "new-owner").unwrap()["owned"],
            true
        );
        let config = crate::config::Store::new(std::path::PathBuf::from(
            std::env::var_os("MCC_CONFIG_DIR").unwrap(),
        ));
        config
            .execute(
                &[
                    "set",
                    "jev",
                    "--url",
                    "https://example.com/decisions",
                    "--model",
                    "fixture/model",
                    "--api-key-stdin",
                ]
                .map(str::to_owned),
                b"fixture-secret".as_slice(),
            )
            .unwrap();
        config
            .execute(&["disable", "jev"].map(str::to_owned), std::io::empty())
            .unwrap();
        assert_eq!(
            crate::execution::execute_remote_request(
                json!({"action":"click-target","connectionId":"fake","target":"Save"}),
                Scope::Chrome,
                "new-owner",
                "1"
            )
            .unwrap_err()
            .code,
            "MODEL_DISABLED"
        );
        assert_eq!(
            remote_call(
                &guard.runtime,
                "new-owner",
                "2",
                json!({"action":"connect","windowId":999})
            )
            .unwrap_err()
            .code,
            "WINDOW_UNAVAILABLE"
        );
        assert_eq!(
            remote_release(&guard.runtime, "new-owner").unwrap()["released"],
            true
        );
        assert_eq!(
            remote_claim(&guard.runtime, "after-rollback").unwrap()["owned"],
            true
        );
        let connection = remote_call(
            &guard.runtime,
            "after-rollback",
            "1",
            json!({"action":"connect","windowId":42}),
        )
        .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        remote_call(
            &guard.runtime,
            "after-rollback",
            "2",
            json!({"action":"disconnect","connectionId":connection}),
        )
        .unwrap();
        assert_eq!(
            remote_release(&guard.runtime, "after-rollback").unwrap()["released"],
            true
        );
        let socket = guard.runtime.socket.clone();
        drop(guard);
        assert!(!socket.exists());
        assert!(crate::execution::execute_remote_request(
            json!({"action":"status"}),
            Scope::Chrome,
            "new-owner",
            "4"
        )
        .is_err());
        assert!(
            !socket.exists(),
            "remote entry may not recreate daemon/helper"
        );
    }
    #[test]
    fn local_recover_first_pauses_active_operation_before_returning_busy() {
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let f = Arc::new(Fixture::with_decider(Some(Box::new(SlowDecision {
            started: started_tx,
            release: release_rx,
        }))));
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let worker = f.clone();
        let thread = std::thread::spawn(move || {
            worker.invoke(RemoteContext::Call {owner:owner(),operation:"2".into()},json!({"action":"click-target","connectionId":connection,"target":"Save","jevKey":"fixture-secret","jevUrl":"https://example.com/decisions","jevModel":"vendor/model","jevProtocol":crate::jev::DECISION_PROTOCOL}))
        });
        started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Recover {
                    owner: owner(),
                    daemon_pid: None,
                    helper_pid: None
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "BUSY"
        );
        let state = f
            .invoke(RemoteContext::State { owner: owner() }, json!({}))
            .unwrap();
        assert_eq!(state["paused"], true);
        assert_eq!(state["recoveryRequired"], true);
        release_tx.send(()).unwrap();
        assert!(thread.join().unwrap().is_err());
        assert!(!f.root.join("clicks").exists());
        assert_eq!(
            f.invoke(
                RemoteContext::Recover {
                    owner: owner(),
                    daemon_pid: None,
                    helper_pid: None
                },
                json!({})
            )
            .unwrap()["recovered"],
            true
        );
    }
    #[test]
    fn paused_owner_can_observe_without_releasing_pause_or_lease() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let pause = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into()),
                },
                json!({}),
            )
            .unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Read {
                    owner: "intruder".into(),
                    operation: "2".into()
                },
                json!({"action":"observe","connectionId":connection})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        let observation = f
            .invoke(
                RemoteContext::Read {
                    owner: owner(),
                    operation: "2".into(),
                },
                json!({"action":"observe","connectionId":connection}),
            )
            .unwrap();
        assert!(observation["frameId"].is_string());
        let state = f
            .invoke(RemoteContext::State { owner: owner() }, json!({}))
            .unwrap();
        assert_eq!(state["paused"], true);
        assert_eq!(state["lease"], pause["lease"]);
        assert_eq!(state["inputEpoch"], pause["inputEpoch"]);
        assert!(f
            .invoke(
                RemoteContext::Read {
                    owner: owner(),
                    operation: "2".into()
                },
                json!({"action":"disconnect","connectionId":connection})
            )
            .is_err());
        assert!(f
            .invoke(
                RemoteContext::Read {
                    owner: owner(),
                    operation: "2".into()
                },
                json!({"action":"permissions","request":true})
            )
            .is_err());
        assert!(f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "2".into()
                },
                json!({"action":"disconnect","connectionId":connection})
            )
            .is_err());
    }
    #[test]
    fn recovery_reconciliation_requires_same_lease_and_advanced_epoch() {
        let mut control = RemoteControl {
            recovery: true,
            paused_epoch: Some(7),
            paused_lease: Some(42),
            ..RemoteControl::default()
        };
        for state in [
            json!({"paused":false,"recoveryRequired":false,"lease":99,"inputEpoch":8,"phase":"running"}),
            json!({"paused":false,"recoveryRequired":false,"lease":42,"inputEpoch":7,"phase":"running"}),
            json!({"paused":false,"recoveryRequired":false,"lease":42,"inputEpoch":8,"phase":"awaitingCountdown"}),
        ] {
            reconcile(&mut control, &state);
            assert!(control.recovery);
        }
        reconcile(
            &mut control,
            &json!({"paused":false,"recoveryRequired":false,"lease":42,"inputEpoch":8,"phase":"countdown"}),
        );
        assert!(!control.recovery);
        let mut no_lease = RemoteControl {
            recovery: true,
            paused_epoch: Some(7),
            paused_lease: None,
            ..RemoteControl::default()
        };
        reconcile(
            &mut no_lease,
            &json!({"paused":false,"recoveryRequired":false,"lease":null,"inputEpoch":8,"phase":"running"}),
        );
        assert!(no_lease.recovery);
    }
    #[test]
    fn operation_sequence_rejects_noncanonical_zero_and_overflow() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        for operation in ["0", "01", "-1", "abc", "18446744073709551616"] {
            assert!(f
                .invoke(
                    RemoteContext::Reserve {
                        owner: owner(),
                        operation: operation.into()
                    },
                    json!({})
                )
                .is_err());
        }
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
    }
    #[test]
    fn old_completed_operation_does_not_pause_after_newer_read() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Call {
                owner: owner(),
                operation: "1".into(),
            },
            json!({"action":"connect","windowId":42}),
        )
        .unwrap();
        f.invoke(
            RemoteContext::Read {
                owner: owner(),
                operation: "2".into(),
            },
            json!({"action":"status"}),
        )
        .unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into())
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        assert_eq!(
            f.invoke(RemoteContext::State { owner: owner() }, json!({}))
                .unwrap()["paused"],
            false
        );
    }
    #[test]
    fn paused_observe_window_loss_preserves_native_lease_and_recovery() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let pause = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into()),
                },
                json!({}),
            )
            .unwrap();
        fs::write(f.root.join("fail-window"), b"fixture").unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Read {
                    owner: owner(),
                    operation: "2".into()
                },
                json!({"action":"observe","connectionId":connection})
            )
            .unwrap_err()
            .code,
            "WINDOW_UNAVAILABLE"
        );
        let state = f
            .invoke(RemoteContext::State { owner: owner() }, json!({}))
            .unwrap();
        assert_eq!(state["paused"], true);
        assert_eq!(state["lease"], pause["lease"]);
        assert_eq!(state["recoveryRequired"], true);
        assert!(f.service.lock().unwrap().connected());
    }
    #[test]
    fn same_lease_local_resume_advances_epoch_without_new_helper() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let paused = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into()),
                },
                json!({}),
            )
            .unwrap();
        fs::write(f.root.join("resume"), b"fake local user").unwrap();
        let resumed = f
            .invoke(RemoteContext::State { owner: owner() }, json!({}))
            .unwrap();
        assert_eq!(resumed["lease"], paused["lease"]);
        assert!(resumed["inputEpoch"].as_u64().unwrap() > paused["inputEpoch"].as_u64().unwrap());
        assert_eq!(resumed["phase"], "countdown");
        assert_eq!(resumed["recoveryRequired"], false);
        assert!(f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "2".into()
                },
                json!({"action":"disconnect","connectionId":connection})
            )
            .is_ok());
    }
    #[test]
    fn pause_correlates_inflight_read_and_rejects_older_operation() {
        let f = Arc::new(Fixture::new());
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        fs::write(f.root.join("slow-window"), b"fixture").unwrap();
        let worker = f.clone();
        let thread = std::thread::spawn(move || {
            worker.invoke(
                RemoteContext::Read {
                    owner: owner(),
                    operation: "2".into(),
                },
                json!({"action":"observe","connectionId":connection}),
            )
        });
        let deadline = Instant::now() + Duration::from_secs(3);
        while !f.root.join("slow-window.started").exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(f.root.join("slow-window.started").exists());
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into())
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        let start = Instant::now();
        assert_eq!(
            f.invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("2".into())
                },
                json!({})
            )
            .unwrap()["paused"],
            true
        );
        assert!(start.elapsed() < Duration::from_millis(1500));
        assert!(thread.join().unwrap().is_ok());
        assert_eq!(
            f.invoke(RemoteContext::State { owner: owner() }, json!({}))
                .unwrap()["paused"],
            true
        );
    }
    #[test]
    fn claim_rejects_native_pause_without_existing_lease() {
        let f = Fixture::new();
        assert_eq!(
            f.cancel.transport("transport-pause").unwrap()["paused"],
            true
        );
        assert_eq!(
            f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
                .unwrap_err()
                .code,
            "RECOVERY_REQUIRED"
        );
    }
    #[test]
    fn owner_death_immediately_before_model_result_never_dispatches_click() {
        struct ChildGuard(std::process::Child);
        impl Drop for ChildGuard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut child = ChildGuard(
            std::process::Command::new("/bin/sleep")
                .arg("30")
                .spawn()
                .unwrap(),
        );
        let identity = process_identity(child.0.id() as libc::pid_t).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let f = Arc::new(Fixture::with_decider(Some(Box::new(SlowDecision {
            started: started_tx,
            release: release_rx,
        }))));
        handle_remote(
            RemoteContext::Claim { owner: owner() },
            json!({}),
            &f.service,
            &f.stopping,
            &f.cancel,
            &f.control,
            identity,
        )
        .unwrap();
        let connected = handle_remote(
            RemoteContext::Call {
                owner: owner(),
                operation: "1".into(),
            },
            json!({"action":"connect","windowId":42}),
            &f.service,
            &f.stopping,
            &f.cancel,
            &f.control,
            identity,
        )
        .unwrap();
        let connection = connected["connectionId"].as_str().unwrap().to_owned();
        let worker = f.clone();
        let thread = std::thread::spawn(move || {
            handle_remote(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "2".into(),
                },
                json!({"action":"click-target","connectionId":connection,"target":"Save","jevKey":"fixture-secret","jevUrl":"https://example.com/decisions","jevModel":"vendor/model","jevProtocol":crate::jev::DECISION_PROTOCOL}),
                &worker.service,
                &worker.stopping,
                &worker.cancel,
                &worker.control,
                identity,
            )
        });
        started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        release_tx.send(()).unwrap();
        assert!(thread.join().unwrap().is_err());
        assert!(!f.root.join("clicks").exists());
    }
    #[test]
    fn watchdog_fails_closed_when_pid_start_identity_changes() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let original = f.control.lock().unwrap().owner_identity.unwrap();
        let forged = OwnerIdentity {
            start_usec: original.start_usec.wrapping_add(1),
            ..original
        };
        let control = Arc::new(Mutex::new(RemoteControl {
            owner: Some(owner()),
            owner_identity: Some(forged),
            ..RemoteControl::default()
        }));
        let guard = start_owner_watchdog(control.clone(), f.cancel.clone());
        let deadline = Instant::now() + Duration::from_secs(3);
        while !control.lock().unwrap().watchdog_pause_confirmed && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(control.lock().unwrap().owner_dead);
        assert!(control.lock().unwrap().recovery);
        assert!(control.lock().unwrap().watchdog_pause_confirmed);
        assert_eq!(
            f.cancel.transport("transport-state").unwrap()["paused"],
            true
        );
        drop(guard);
    }
    #[test]
    fn owner_death_without_lease_locks_setup_until_local_recovery() {
        struct ChildGuard(std::process::Child);
        impl Drop for ChildGuard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut child = ChildGuard(
            std::process::Command::new("/bin/sleep")
                .arg("30")
                .spawn()
                .unwrap(),
        );
        let identity = process_identity(child.0.id() as libc::pid_t).unwrap();
        let f = Fixture::new();
        handle_remote(
            RemoteContext::Claim { owner: owner() },
            json!({}),
            &f.service,
            &f.stopping,
            &f.cancel,
            &f.control,
            identity,
        )
        .unwrap();
        let guard = start_owner_watchdog(f.control.clone(), f.cancel.clone());
        child.0.kill().unwrap();
        // Do not reap yet: the watchdog must also reject a still-zombie PID.
        let deadline = Instant::now() + Duration::from_secs(3);
        while !f.control.lock().unwrap().watchdog_pause_confirmed && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        let state = f
            .invoke(RemoteContext::State { owner: owner() }, json!({}))
            .unwrap();
        assert_eq!(state["paused"], true);
        assert!(state["lease"].is_null());
        assert_eq!(state["recoveryRequired"], true);
        child.0.wait().unwrap();
        assert!(f
            .invoke(
                RemoteContext::Claim {
                    owner: "new-owner".into()
                },
                json!({})
            )
            .is_err());
        assert!(f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into()
                },
                json!({"action":"chrome-start"})
            )
            .is_err());
        assert_eq!(
            f.invoke(
                RemoteContext::Recover {
                    owner: owner(),
                    daemon_pid: None,
                    helper_pid: None
                },
                json!({})
            )
            .unwrap()["recovered"],
            true
        );
        drop(guard);
    }
    #[test]
    fn stopped_owner_process_is_not_treated_as_a_safe_live_host() {
        struct ChildGuard(std::process::Child);
        impl Drop for ChildGuard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut child = ChildGuard(
            std::process::Command::new("/bin/sleep")
                .arg("30")
                .spawn()
                .unwrap(),
        );
        let pid = child.0.id() as libc::pid_t;
        let identity = process_identity(pid).unwrap();
        let f = Fixture::new();
        handle_remote(
            RemoteContext::Claim { owner: owner() },
            json!({}),
            &f.service,
            &f.stopping,
            &f.cancel,
            &f.control,
            identity,
        )
        .unwrap();
        assert_eq!(unsafe { libc::kill(pid, libc::SIGSTOP) }, 0);
        let mut state = 0;
        assert_eq!(
            unsafe { libc::waitpid(pid, &mut state, libc::WUNTRACED) },
            pid
        );
        assert!(libc::WIFSTOPPED(state));
        let guard = start_owner_watchdog(f.control.clone(), f.cancel.clone());
        let deadline = Instant::now() + Duration::from_secs(1);
        while !f.control.lock().unwrap().watchdog_pause_confirmed && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            f.control.lock().unwrap().watchdog_pause_confirmed,
            "stopped Host must be fail-closed"
        );
        assert_eq!(unsafe { libc::kill(pid, libc::SIGCONT) }, 0);
        assert!(
            f.control.lock().unwrap().owner_dead,
            "continuation must not silently recover"
        );
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        drop(guard);
    }
    #[test]
    fn checked_recover_rejects_wrong_pids_without_touching_pause_or_lease() {
        let f = Fixture::new();
        let claim = f
            .invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Call {
                owner: owner(),
                operation: "1".into(),
            },
            json!({"action":"connect","windowId":42}),
        )
        .unwrap();
        let before = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: Some("1".into()),
                },
                json!({}),
            )
            .unwrap();
        let daemon = claim["daemonPid"].as_u64().unwrap() as u32;
        let helper = claim["helperPid"].as_u64().unwrap() as u32;
        for (expected_daemon, expected_helper) in [
            (Some(daemon.wrapping_add(1)), Some(helper)),
            (Some(daemon), Some(helper.wrapping_add(1))),
            (Some(daemon), None),
            (None, Some(helper)),
        ] {
            let err = f
                .invoke(
                    RemoteContext::Recover {
                        owner: owner(),
                        daemon_pid: expected_daemon,
                        helper_pid: expected_helper,
                    },
                    json!({}),
                )
                .unwrap_err();
            assert_eq!(err.code, "RECOVERY_REQUIRED");
            let current = f
                .invoke(RemoteContext::State { owner: owner() }, json!({}))
                .unwrap();
            for field in ["paused", "phase", "lease", "inputEpoch", "recoveryRequired"] {
                assert_eq!(current[field], before[field], "{field}");
            }
            assert!(f.service.lock().unwrap().connected());
        }
        assert_eq!(
            f.invoke(
                RemoteContext::Recover {
                    owner: owner(),
                    daemon_pid: Some(daemon),
                    helper_pid: Some(helper)
                },
                json!({})
            )
            .unwrap()["recovered"],
            true
        );
        assert!(!f.service.lock().unwrap().connected());
    }
    #[test]
    fn checked_recover_does_not_cancel_or_pause_active_operation() {
        let f = Fixture::new();
        let claim = f
            .invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
        let cancel = f
            .control
            .lock()
            .unwrap()
            .active
            .as_ref()
            .unwrap()
            .cancelled
            .clone();
        let result = f.invoke(
            RemoteContext::Recover {
                owner: owner(),
                daemon_pid: Some(claim["daemonPid"].as_u64().unwrap() as u32),
                helper_pid: Some(claim["helperPid"].as_u64().unwrap() as u32),
            },
            json!({}),
        );
        assert_eq!(result.unwrap_err().code, "BUSY");
        assert!(!cancel.load(Ordering::Acquire));
        assert_eq!(
            f.cancel.transport("transport-state").unwrap()["paused"],
            false
        );
        assert!(f.control.lock().unwrap().active.is_some());
    }
    #[test]
    fn checked_recover_during_live_decision_returns_busy_without_cancelling_it() {
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let f = Arc::new(Fixture::with_decider(Some(Box::new(SlowDecision {
            started: started_tx,
            release: release_rx,
        }))));
        let claim = f
            .invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let daemon = claim["daemonPid"].as_u64().unwrap() as u32;
        let helper = claim["helperPid"].as_u64().unwrap() as u32;
        let connection = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":42}),
            )
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let worker = f.clone();
        let thread = std::thread::spawn(move || {
            worker.invoke(RemoteContext::Call {owner:owner(),operation:"2".into()},json!({"action":"click-target","connectionId":connection,"target":"Save","jevKey":"fixture-secret","jevUrl":"https://example.com/decisions","jevModel":"vendor/model","jevProtocol":crate::jev::DECISION_PROTOCOL}))
        });
        started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        let cancel = f
            .control
            .lock()
            .unwrap()
            .active
            .as_ref()
            .unwrap()
            .cancelled
            .clone();
        for (dp, hp) in [(daemon.wrapping_add(1), helper), (daemon, helper)] {
            let error = f
                .invoke(
                    RemoteContext::Recover {
                        owner: owner(),
                        daemon_pid: Some(dp),
                        helper_pid: Some(hp),
                    },
                    json!({}),
                )
                .unwrap_err();
            assert_eq!(error.code, "BUSY");
            assert!(!cancel.load(Ordering::Acquire));
            assert_eq!(
                f.cancel.transport("transport-state").unwrap()["paused"],
                false
            );
        }
        release_tx.send(()).unwrap();
        assert!(thread.join().unwrap().is_ok());
        assert_eq!(fs::read(f.root.join("clicks")).unwrap(), b"click\n");
    }
    #[test]
    fn failed_initial_connect_without_lease_can_release_without_resetting_native_state() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let error = f
            .invoke(
                RemoteContext::Call {
                    owner: owner(),
                    operation: "1".into(),
                },
                json!({"action":"connect","windowId":999}),
            )
            .unwrap_err();
        assert_eq!(error.code, "WINDOW_UNAVAILABLE");
        assert!(!f.service.lock().unwrap().connected());
        let before = f.cancel.transport("transport-state").unwrap();
        assert!(before["lease"].is_null());
        assert_eq!(before["paused"], false);
        assert_eq!(
            f.invoke(RemoteContext::Release { owner: owner() }, json!({}))
                .unwrap()["released"],
            true
        );
        let after = f.cancel.transport("transport-state").unwrap();
        assert_eq!(
            before, after,
            "release must not cancel or reset the helper phase"
        );
        assert_eq!(
            f.invoke(
                RemoteContext::Claim {
                    owner: "next-owner".into()
                },
                json!({})
            )
            .unwrap()["owned"],
            true
        );
    }
    #[test]
    fn release_without_disconnect_rejects_pause_active_connection_and_unknown_state() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let before = f.cancel.transport("transport-state").unwrap();
        assert_eq!(
            f.invoke(
                RemoteContext::Release {
                    owner: "intruder".into()
                },
                json!({})
            )
            .unwrap_err()
            .code,
            "NOT_OWNER"
        );
        {
            struct ChildGuard(std::process::Child);
            impl Drop for ChildGuard {
                fn drop(&mut self) {
                    let _ = self.0.kill();
                    let _ = self.0.wait();
                }
            }
            let child = ChildGuard(
                std::process::Command::new("/bin/sleep")
                    .arg("30")
                    .spawn()
                    .unwrap(),
            );
            let other = process_identity(child.0.id() as libc::pid_t).unwrap();
            assert_eq!(
                handle_remote(
                    RemoteContext::Release { owner: owner() },
                    json!({}),
                    &f.service,
                    &f.stopping,
                    &f.cancel,
                    &f.control,
                    other
                )
                .unwrap_err()
                .code,
                "RECOVERY_REQUIRED"
            );
        }
        assert_eq!(f.cancel.transport("transport-state").unwrap(), before);
        f.control.lock().unwrap().active_read = Some("1".into());
        assert_eq!(
            f.invoke(RemoteContext::Release { owner: owner() }, json!({}))
                .unwrap_err()
                .code,
            "BUSY"
        );
        assert_eq!(f.cancel.transport("transport-state").unwrap(), before);
        f.control.lock().unwrap().active_read = None;
        f.invoke(
            RemoteContext::Reserve {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
        let cancel = f
            .control
            .lock()
            .unwrap()
            .active
            .as_ref()
            .unwrap()
            .cancelled
            .clone();
        assert_eq!(
            f.invoke(RemoteContext::Release { owner: owner() }, json!({}))
                .unwrap_err()
                .code,
            "BUSY"
        );
        assert!(!cancel.load(Ordering::Acquire));
        assert_eq!(f.cancel.transport("transport-state").unwrap(), before);
        f.invoke(
            RemoteContext::Abandon {
                owner: owner(),
                operation: "1".into(),
            },
            json!({}),
        )
        .unwrap();
        let pause = f
            .invoke(
                RemoteContext::Pause {
                    owner: owner(),
                    operation: None,
                },
                json!({}),
            )
            .unwrap();
        assert!(pause["lease"].is_null());
        assert!(f
            .invoke(RemoteContext::Release { owner: owner() }, json!({}))
            .is_err());
        let state = f
            .invoke(RemoteContext::State { owner: owner() }, json!({}))
            .unwrap();
        for field in ["paused", "lease", "phase", "inputEpoch", "recoveryRequired"] {
            assert_eq!(state[field], pause[field], "{field}");
        }
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.invoke(
            RemoteContext::Call {
                owner: owner(),
                operation: "1".into(),
            },
            json!({"action":"connect","windowId":42}),
        )
        .unwrap();
        // A real connect may have no native lease until the first input.
        // Model that state in the fake helper while retaining Service's connection.
        let state = f.cancel.transport("transport-recover").unwrap();
        assert!(state["lease"].is_null());
        let before = f.cancel.transport("transport-state").unwrap();
        assert!(f
            .invoke(RemoteContext::Release { owner: owner() }, json!({}))
            .is_err());
        assert!(f.service.lock().unwrap().connected());
        assert_eq!(f.cancel.transport("transport-state").unwrap(), before);
        assert_eq!(f.control.lock().unwrap().owner.as_deref(), Some(OWNER));
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        f.cancel.terminate();
        assert!(f
            .invoke(RemoteContext::Release { owner: owner() }, json!({}))
            .is_err());
        assert_eq!(f.control.lock().unwrap().owner.as_deref(), Some(OWNER));
    }
    #[test]
    fn unsafe_owner_identity_release_refuses_without_triggering_native_pause() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let before = f.cancel.transport("transport-state").unwrap();
        let original = f.control.lock().unwrap().owner_identity.unwrap();
        let forged = OwnerIdentity {
            start_usec: original.start_usec.wrapping_add(1),
            ..original
        };
        f.control.lock().unwrap().owner_identity = Some(forged);
        let result = handle_remote(
            RemoteContext::Release { owner: owner() },
            json!({}),
            &f.service,
            &f.stopping,
            &f.cancel,
            &f.control,
            forged,
        );
        assert!(result.is_err());
        assert_eq!(f.cancel.transport("transport-state").unwrap(), before);
        assert_eq!(f.control.lock().unwrap().owner.as_deref(), Some(OWNER));
    }
    #[test]
    fn claim_without_any_connection_can_release_without_native_mutation() {
        let f = Fixture::new();
        f.invoke(RemoteContext::Claim { owner: owner() }, json!({}))
            .unwrap();
        let before = f.cancel.transport("transport-state").unwrap();
        assert!(before["lease"].is_null());
        assert_eq!(
            f.invoke(RemoteContext::Release { owner: owner() }, json!({}))
                .unwrap()["released"],
            true
        );
        assert_eq!(f.cancel.transport("transport-state").unwrap(), before);
        assert!(f.control.lock().unwrap().owner.is_none());
    }
    #[test]
    fn delayed_fake_helper_is_ready_before_first_claim_without_changing_native_state() {
        let started = Instant::now();
        let f = Fixture::with_startup_delay(None, false, Duration::from_millis(2200));
        assert!(
            started.elapsed() >= Duration::from_millis(2100),
            "fixture must wait for the injected startup delay"
        );
        let claim = f.invoke(RemoteContext::Claim { owner: owner() }, json!({}));
        assert!(
            claim.is_ok(),
            "first Claim failed after {:?}: {:?}",
            started.elapsed(),
            claim.err()
        );
        let state = f.cancel.transport("transport-state").unwrap();
        assert_eq!(state["paused"], false);
        assert_eq!(state["recoveryRequired"], false);
        assert_eq!(state["phase"], "awaitingCountdown");
        assert_eq!(state["inputEpoch"], 0);
        assert!(state["lease"].is_null());
    }
}
