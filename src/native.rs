use crate::protocol::{read_message, Error, Result, Scope};
use crate::service::Native;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufReader, Write};
#[cfg(unix)]
use std::net::Shutdown;
#[cfg(unix)]
use std::os::{fd::OwnedFd, unix::net::UnixStream};
use std::path::Path;
#[cfg(not(unix))]
use std::process::ChildStdin;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[cfg(unix)]
type Input = UnixStream;
#[cfg(not(unix))]
type Input = ChildStdin;

#[derive(Clone)]
pub struct Canceller {
    child: Arc<Mutex<Child>>,
    stdin: Arc<Mutex<Input>>,
    cancelled: Arc<AtomicBool>,
    terminating: Arc<AtomicBool>,
    sideband: Arc<Mutex<HashMap<String, mpsc::SyncSender<Value>>>>,
    #[cfg(unix)]
    shutdown: Arc<(UnixStream, UnixStream)>,
}
impl Canceller {
    pub(crate) fn helper_pid(&self) -> Result<u32> {
        self.child
            .lock()
            .map(|child| child.id())
            .map_err(|_| Error::new("HELPER_EOF", "原生 helper 不可用"))
    }
    pub(crate) fn transport(&self, action: &str) -> Result<Value> {
        if !matches!(
            action,
            "transport-state" | "transport-pause" | "transport-recover"
        ) || self.terminating.load(Ordering::Acquire)
        {
            return Err(Error::new("CANCEL_UNCONFIRMED", "无法确认原生传输控制状态"));
        }
        let id = format!(
            "transport-{}",
            crate::protocol::random_id()
                .map_err(|_| Error::new("CANCEL_UNCONFIRMED", "无法确认原生传输控制状态"))?
        );
        let (sender, receiver) = mpsc::sync_channel(1);
        self.sideband
            .lock()
            .map_err(|_| Error::new("CANCEL_UNCONFIRMED", "无法确认原生传输控制状态"))?
            .insert(id.clone(), sender);
        let result = (|| {
            let mut input = self
                .stdin
                .try_lock()
                .map_err(|_| Error::new("CANCEL_UNCONFIRMED", "无法确认原生传输控制状态"))?;
            #[cfg(unix)]
            input
                .set_write_timeout(Some(Duration::from_secs(2)))
                .map_err(|_| Error::new("CANCEL_UNCONFIRMED", "无法确认原生传输控制状态"))?;
            let bytes = format!("{}\n", json!({"id":id,"action":action}));
            input
                .write_all(bytes.as_bytes())
                .map_err(|_| Error::new("CANCEL_UNCONFIRMED", "无法确认原生传输控制状态"))?;
            drop(input);
            let response = receiver
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| Error::new("CANCEL_UNCONFIRMED", "无法确认原生传输控制状态"))?;
            if response["ok"] == true && response["data"].is_object() {
                Ok(response["data"].clone())
            } else {
                Err(Error::new(
                    "HELPER_UPGRADE_REQUIRED",
                    "原生 helper 不支持安全传输控制",
                ))
            }
        })();
        if let Ok(mut pending) = self.sideband.lock() {
            pending.remove(&id);
        }
        result
    }
    pub fn terminate(&self) {
        if self.terminating.swap(true, Ordering::AcqRel) {
            return;
        }
        // 绝不等待正在写入的 stdin 锁；卡住的写入由 shutdown/kill 解锁。
        if let Ok(mut stdin) = self.stdin.try_lock() {
            #[cfg(unix)]
            let _ = stdin.set_write_timeout(Some(Duration::from_millis(20)));
            let _ = stdin.write_all(b"{\"id\":\"cancel\",\"action\":\"cancel\"}\n");
            let _ = stdin.flush();
        }
        // Swift 的 cancel 回执在 held key/mouse 同步释放后发送，不能立即 SIGKILL。
        let deadline = Instant::now() + Duration::from_millis(250);
        while !self.cancelled.load(Ordering::Acquire) && Instant::now() < deadline {
            if self
                .child
                .lock()
                .is_ok_and(|mut child| child.try_wait().ok().flatten().is_some())
            {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        if let Ok(mut child) = self.child.lock() {
            let _ = child.kill();
        }
        #[cfg(unix)]
        {
            // 即使 helper 的后代仍持有管道，也必须唤醒读写线程，保证 Drop 可 join。
            let _ = self.shutdown.0.shutdown(Shutdown::Both);
            let _ = self.shutdown.1.shutdown(Shutdown::Both);
        }
    }
}
pub struct Helper {
    canceller: Canceller,
    receiver: mpsc::Receiver<Result<Value>>,
    reader: Option<JoinHandle<()>>,
    sequence: u64,
    timeout: Duration,
    overflowed: Arc<AtomicBool>,
    input_epoch: Option<u64>,
    owner_guard: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
}
impl Helper {
    pub fn spawn(path: &Path) -> Result<Self> {
        Self::spawn_for_scope(path, Scope::Chrome)
    }
    pub fn spawn_for_scope(path: &Path, scope: Scope) -> Result<Self> {
        Self::with_timeout_for_scope(path, scope, Duration::from_secs(45))
    }
    pub fn with_timeout(path: &Path, timeout: Duration) -> Result<Self> {
        Self::with_timeout_for_scope(path, Scope::Chrome, timeout)
    }
    pub fn with_timeout_for_scope(path: &Path, scope: Scope, timeout: Duration) -> Result<Self> {
        #[cfg(unix)]
        let (stdin, child_stdin) =
            UnixStream::pair().map_err(|e| Error::io("无法创建原生输入通道", e))?;
        #[cfg(unix)]
        let (stdout, child_stdout) =
            UnixStream::pair().map_err(|e| Error::io("无法创建原生输出通道", e))?;
        #[cfg(unix)]
        let shutdown = Arc::new((
            stdin
                .try_clone()
                .map_err(|e| Error::io("无法复制输入通道", e))?,
            stdout
                .try_clone()
                .map_err(|e| Error::io("无法复制输出通道", e))?,
        ));
        let mut command = Command::new(path);
        command
            .env_remove("JEV_API_KEY")
            .env_remove("OPENROUTER_API_KEY")
            .env_remove("TYPESAFE_API_KEY");
        #[cfg(unix)]
        command
            .stdin(Stdio::from(OwnedFd::from(child_stdin)))
            .stdout(Stdio::from(OwnedFd::from(child_stdout)));
        #[cfg(not(unix))]
        command.stdin(Stdio::piped()).stdout(Stdio::piped());
        // 原生进程 stderr 不可信，不能把可能回显的文本或连接信息写入 daemon.log。
        if scope == Scope::Desktop {
            command.arg("--desktop");
        }
        let child = command
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| Error::io("无法启动 Swift helper", e))?;
        #[cfg(not(unix))]
        let mut child = child;
        #[cfg(not(unix))]
        let stdin = child.stdin.take().expect("已配置 stdin 管道");
        #[cfg(not(unix))]
        let stdout = child.stdout.take().expect("已配置 stdout 管道");
        let cancelled = Arc::new(AtomicBool::new(false));
        let overflowed = Arc::new(AtomicBool::new(false));
        let canceller = Canceller {
            child: Arc::new(Mutex::new(child)),
            stdin: Arc::new(Mutex::new(stdin)),
            cancelled: cancelled.clone(),
            terminating: Arc::new(AtomicBool::new(false)),
            sideband: Arc::new(Mutex::new(HashMap::new())),
            #[cfg(unix)]
            shutdown,
        };
        let reader_overflowed = overflowed.clone();
        let reader_sideband = canceller.sideband.clone();
        let (sender, receiver) = mpsc::sync_channel(8);
        let reader = std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let message = match read_message(&mut reader) {
                    Ok(Some(value)) => Ok(value),
                    Ok(None) => Err(Error::new(
                        "HELPER_EOF",
                        "原生 helper 已退出；本连接失效，请重新连接",
                    )),
                    Err(_) => Err(Error::new(
                        "HELPER_PROTOCOL",
                        "原生 helper 返回了无效协议数据",
                    )),
                };
                // Sideband acknowledgements have unique IDs and bypass the action queue.
                if let Ok(value) = &message {
                    if let Some(id) = value["id"]
                        .as_str()
                        .filter(|id| id.starts_with("transport-"))
                    {
                        if let Ok(mut pending) = reader_sideband.lock() {
                            if let Some(sender) = pending.remove(id) {
                                let _ = sender.try_send(value.clone());
                            }
                        }
                        continue;
                    }
                }
                // ack 独立于响应队列；满队列不能阻止紧急取消确认。
                if message.as_ref().is_ok_and(|value| {
                    value["id"] == "cancel"
                        && value["ok"] == true
                        && value["data"]["cancelled"] == true
                }) {
                    cancelled.store(true, Ordering::Release);
                    continue;
                }
                let terminal = message.is_err();
                match sender.try_send(message) {
                    Ok(()) => {}
                    Err(mpsc::TrySendError::Full(_)) => {
                        reader_overflowed.store(true, Ordering::Release);
                    }
                    Err(mpsc::TrySendError::Disconnected(_)) => break,
                }
                if terminal {
                    break;
                }
            }
        });
        Ok(Self {
            canceller,
            receiver,
            reader: Some(reader),
            sequence: 0,
            timeout,
            overflowed,
            input_epoch: None,
            owner_guard: None,
        })
    }
    pub fn canceller(&self) -> Canceller {
        self.canceller.clone()
    }
}
impl Native for Helper {
    fn set_input_epoch(&mut self, epoch: Option<u64>) {
        self.input_epoch = epoch;
    }
    fn set_owner_guard(&mut self, guard: Option<Arc<dyn Fn() -> bool + Send + Sync>>) {
        self.owner_guard = guard;
    }
    fn request(&mut self, mut request: Value) -> Result<Value> {
        if self.owner_guard.as_ref().is_some_and(|alive| !alive()) {
            return Err(Error::new(
                "USER_PAUSED",
                crate::protocol::USER_PAUSED_PUBLIC_MESSAGE,
            ));
        }
        if self.canceller.terminating.load(Ordering::Acquire) {
            return Err(Error::new("HELPER_EOF", "原生 helper 已停止"));
        }
        if self.overflowed.load(Ordering::Acquire) {
            return Err(Error::new("HELPER_PROTOCOL", "原生 helper 响应队列溢出"));
        }
        let deadline = Instant::now() + self.timeout;
        if let Some(epoch) = self.input_epoch {
            if request["action"] == "cancel" {
                request["action"] = json!("transport-disconnect");
                request["expectedInputEpoch"] = json!(epoch);
            }
            if matches!(
                request["action"].as_str(),
                Some("click" | "scroll" | "type" | "press" | "select-file" | "chrome-start")
            ) {
                request["expectedInputEpoch"] = json!(epoch);
            }
        }
        self.sequence += 1;
        let id = self.sequence.to_string();
        request["id"] = json!(id);
        let mut bytes = serde_json::to_vec(&request)
            .map_err(|_| Error::new("HELPER_PROTOCOL", "无法编码原生请求"))?;
        bytes.push(b'\n');
        if bytes.len() > crate::protocol::MAX_MESSAGE_BYTES {
            return Err(Error::new("MESSAGE_TOO_LARGE", "原生请求超过 64KiB"));
        }
        {
            let mut stdin = self
                .canceller
                .stdin
                .lock()
                .map_err(|_| Error::new("HELPER_EOF", "原生输入管道已关闭"))?;
            let mut remaining = bytes.as_slice();
            while !remaining.is_empty() {
                #[cfg(unix)]
                stdin
                    .set_write_timeout(Some(
                        deadline
                            .saturating_duration_since(Instant::now())
                            .max(Duration::from_millis(1)),
                    ))
                    .map_err(|_| Error::new("HELPER_EOF", "原生输入管道已关闭"))?;
                match stdin.write(remaining) {
                    Ok(0) => return Err(Error::new("HELPER_EOF", "原生输入管道已关闭")),
                    Ok(count) => remaining = &remaining[count..],
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                        ) =>
                    {
                        drop(stdin);
                        self.canceller.terminate();
                        return Err(Error::new("HELPER_TIMEOUT", "原生请求写入超时"));
                    }
                    Err(_) => return Err(Error::new("HELPER_EOF", "原生 helper 输入管道已关闭")),
                }
                if Instant::now() >= deadline {
                    drop(stdin);
                    self.canceller.terminate();
                    return Err(Error::new("HELPER_TIMEOUT", "原生请求写入超时"));
                }
            }
        }
        let message = self
            .receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .map_err(|error| {
                self.canceller.terminate();
                match error {
                    mpsc::RecvTimeoutError::Timeout => {
                        Error::new("HELPER_TIMEOUT", "原生调用超时；本连接失效，请重新连接")
                    }
                    mpsc::RecvTimeoutError::Disconnected => {
                        Error::new("HELPER_EOF", "原生 helper 已退出")
                    }
                }
            })??;
        if message["id"] != id {
            return Err(Error::new("HELPER_PROTOCOL", "原生响应 ID 不匹配"));
        }
        if message["ok"] == true {
            if !message["data"].is_object() {
                return Err(Error::new("HELPER_PROTOCOL", "原生响应缺少 data 对象"));
            }
            Ok(message["data"].clone())
        } else if message["ok"] == false {
            let error: Error = serde_json::from_value(message["error"].clone())
                .map_err(|_| Error::new("HELPER_PROTOCOL", "原生错误格式无效"))?;
            Err(error)
        } else {
            Err(Error::new("HELPER_PROTOCOL", "原生响应缺少 ok 布尔值"))
        }
    }
}
impl Drop for Helper {
    fn drop(&mut self) {
        self.canceller.terminate();
        if let Ok(mut child) = self.canceller.child.lock() {
            let _ = child.wait();
        }
        // reader 使用 try_send，且输出通道已 shutdown，join 不再等待队列消费或后代 EOF。
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

#[cfg(all(test, unix))]
mod transport_tests {
    use super::*;
    #[test]
    fn transport_sideband_has_distinct_ack_and_preserves_state() {
        use std::os::unix::fs::PermissionsExt;
        struct Temp(std::path::PathBuf);
        impl Drop for Temp {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let dir = Temp(std::env::temp_dir().join(format!(
            "mcc-native-sideband-{}",
            crate::protocol::random_id().unwrap()
        )));
        std::fs::create_dir(&dir.0).unwrap();
        let fake =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-helper.sh");
        let quoted = fake.to_string_lossy().replace('\'', "'\\''");
        let path = dir.0.join("helper.sh");
        std::fs::write(&path, format!("#!/bin/sh\nunset COPIS_CHROME_RUNTIME_DIR COPIS_DESKTOP_RUNTIME_DIR\nexport MCC_FAKE_TRANSPORT_WRONG_ACK=1\nexec '{}' \"$@\"\n", quoted)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut helper = Helper::with_timeout(&path, Duration::from_secs(2)).unwrap();
        let cancel = helper.canceller();
        let initial = cancel.transport("transport-state").unwrap();
        assert_eq!(initial["transportPauseVersion"], 1);
        assert_eq!(initial["paused"], false);
        helper.set_input_epoch(Some(0));
        let receipt = cancel.transport("transport-pause").unwrap();
        assert_eq!(receipt["paused"], true);
        assert_eq!(
            helper.request(json!({"action":"click"})).unwrap_err().code,
            "USER_PAUSED"
        );
        assert_eq!(receipt["recovered"], false);
        assert_eq!(
            cancel.transport("transport-state").unwrap()["recoveryRequired"],
            true
        );
        let state = cancel.transport("transport-recover").unwrap();
        assert_eq!(state["recoveryRequired"], false);
        assert_eq!(
            helper.request(json!({"action":"click"})).unwrap_err().code,
            "USER_PAUSED"
        );
        helper.set_input_epoch(None);
        assert_eq!(
            helper
                .request(json!({"action":"permissions","request":false}))
                .unwrap()["screenRecording"],
            true
        );
    }
}
