use crate::protocol::{read_message, Error, Result};
use crate::service::Native;
use serde_json::{json, Value};
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
    #[cfg(unix)]
    shutdown: Arc<(UnixStream, UnixStream)>,
}
impl Canceller {
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
}
impl Helper {
    pub fn spawn(path: &Path) -> Result<Self> {
        Self::with_timeout(path, Duration::from_secs(45))
    }
    pub fn with_timeout(path: &Path, timeout: Duration) -> Result<Self> {
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
        #[cfg(unix)]
        command
            .stdin(Stdio::from(OwnedFd::from(child_stdin)))
            .stdout(Stdio::from(OwnedFd::from(child_stdout)));
        #[cfg(not(unix))]
        command.stdin(Stdio::piped()).stdout(Stdio::piped());
        // 原生进程 stderr 不可信，不能把可能回显的文本或连接信息写入 daemon.log。
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
            #[cfg(unix)]
            shutdown,
        };
        let reader_overflowed = overflowed.clone();
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
        })
    }
    pub fn canceller(&self) -> Canceller {
        self.canceller.clone()
    }
}
impl Native for Helper {
    fn request(&mut self, mut request: Value) -> Result<Value> {
        if self.canceller.terminating.load(Ordering::Acquire) {
            return Err(Error::new("HELPER_EOF", "原生 helper 已停止"));
        }
        if self.overflowed.load(Ordering::Acquire) {
            return Err(Error::new("HELPER_PROTOCOL", "原生 helper 响应队列溢出"));
        }
        let deadline = Instant::now() + self.timeout;
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
