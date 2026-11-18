use crate::store::{Result, Settings};
use serde::Serialize;
use serde_json::Value;
use std::{
    io::BufReader,
    net::SocketAddr,
    path::Path,
    process::{Child, Command, Stdio},
    sync::{mpsc, Mutex},
    time::{Duration, Instant},
};

#[derive(Clone, Serialize)]
pub struct State {
    pub phase: &'static str,
    pub listen: Option<String>,
    pub message: Option<String>,
}
struct Running {
    child: Child,
    rx: mpsc::Receiver<Value>,
    started: Instant,
    listen: String,
    ready: bool,
    stopping: bool,
    recovery: bool,
    final_response: Option<Value>,
}
#[derive(Default)]
pub struct Host(Mutex<Process>);
#[derive(Default)]
struct Process {
    running: Option<Running>,
    last_message: Option<String>,
    closing: bool,
}

pub fn command(executable: &Path, shared: &Path) -> Command {
    let mut cmd = Command::new(executable);
    cmd.env("MCC_CONFIG_DIR", shared).stdin(Stdio::null());
    cmd
}
fn error_response(value: &Value) -> Option<String> {
    let code = value["error"]["code"].as_str()?;
    let message = value["error"]["message"]
        .as_str()
        .unwrap_or("Host 操作失败");
    Some(format!("{code}：{message}"))
}
impl Host {
    pub fn start(&self, executable: &Path, shared: &Path, settings: &Settings) -> Result<State> {
        let mut p = self.0.lock().map_err(|_| "Host 管理状态不可用")?;
        p.refresh()?;
        if p.closing || p.running.is_some() {
            return Err("已存在本面板启动的 Host，或 App 正在关闭".into());
        }
        let h = &settings.host;
        let addr = SocketAddr::new(h.address, h.port).to_string();
        let mut child = command(executable, shared)
            .env("MCC_HOST_READY", "1")
            .args(["host", "start", "--listen", &addr, "--tls-cert"])
            .arg(&h.certificate)
            .arg("--tls-key")
            .arg(&h.private_key)
            .arg("--token-file")
            .arg(&h.token_file)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;
        let stdout = child.stdout.take().expect("piped stdout");
        let (tx, rx) = mpsc::sync_channel(4);
        std::thread::spawn(move || {
            let mut input = BufReader::new(stdout);
            while let Ok(Some(value)) = copis_chrome::protocol::read_message(&mut input) {
                if tx.send(value).is_err() {
                    break;
                }
            }
        });
        p.last_message = None;
        p.running = Some(Running {
            child,
            rx,
            started: Instant::now(),
            listen: addr,
            ready: false,
            stopping: false,
            recovery: false,
            final_response: None,
        });
        Ok(p.state())
    }
    pub fn state(&self) -> Result<State> {
        let mut p = self.0.lock().map_err(|_| "Host 管理状态不可用")?;
        p.refresh()?;
        Ok(p.state())
    }
    pub fn stop(&self) -> Result<State> {
        let mut p = self.0.lock().map_err(|_| "Host 管理状态不可用")?;
        p.refresh()?;
        if let Some(ref mut child) = p.running {
            child.stop()?;
        }
        Ok(p.state())
    }
    pub fn prepare_exit(&self) -> Result<bool> {
        let mut p = self.0.lock().map_err(|_| "Host 管理状态不可用")?;
        p.closing = true;
        p.refresh()?;
        let Some(ref mut child) = p.running else {
            return Ok(false);
        };
        child.stop()?;
        Ok(true)
    }
}
impl Running {
    fn read(&mut self) {
        while let Ok(value) = self.rx.try_recv() {
            if value["hostReady"] == true && value["listen"].as_str() == Some(&self.listen) {
                self.ready = true;
                self.recovery = value["recoveryRequired"] == true;
            } else {
                self.final_response = Some(value);
            }
        }
    }
    fn stop(&mut self) -> Result<()> {
        if !self.stopping {
            // No wait/reap occurs between inspecting and signalling this owned child.
            if unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) } != 0 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() != Some(libc::ESRCH) {
                    return Err(error.to_string());
                }
            }
            self.stopping = true;
        }
        Ok(())
    }
}
impl Process {
    fn refresh(&mut self) -> Result<()> {
        let Some(ref mut h) = self.running else {
            return Ok(());
        };
        h.read();
        if let Some(status) = h.child.try_wait().map_err(|e| e.to_string())? {
            // Collect the final JSON after wait, allowing the pipe reader a brief scheduling window.
            if h.final_response.is_none() {
                if let Ok(value) = h.rx.recv_timeout(Duration::from_millis(100)) {
                    h.final_response = Some(value);
                }
            }
            h.read();
            self.last_message = h
                .final_response
                .as_ref()
                .and_then(error_response)
                .or_else(|| self.last_message.take())
                .or_else(|| (!status.success()).then(|| format!("Host 退出：{status}")));
            self.running = None;
        } else if !h.ready && !h.stopping && h.started.elapsed() >= Duration::from_secs(8) {
            self.last_message = Some("未收到 Host 监听回执；请检查是否选用了本版本构建包".into());
            h.stop()?;
        }
        Ok(())
    }
    fn state(&self) -> State {
        match &self.running {
            Some(h) => State {
                phase: if h.stopping {
                    "stopping"
                } else if h.ready {
                    "running"
                } else {
                    "starting"
                },
                listen: Some(h.listen.clone()),
                message: self.last_message.clone().or_else(|| {
                    (h.ready && h.recovery)
                        .then(|| "Host 已监听，但旧会话需要按 MCC 原流程恢复".into())
                }),
            },
            None => State {
                phase: "stopped",
                listen: None,
                message: self.last_message.clone(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{private_dir, HostConfig};
    use std::{
        fs,
        net::{TcpListener, TcpStream},
        path::PathBuf,
    };

    struct Temp(PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn await_state(host: &Host, phase: &str) -> State {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let state = host.state().unwrap();
            if state.phase == phase {
                return state;
            }
            assert!(
                Instant::now() < deadline,
                "expected {phase}, got {}: {:?}",
                state.phase,
                state.message
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    #[test]
    #[ignore = "requires the built MCC CLI; set MCC_PANEL_TEST_CLI"]
    fn real_host_reports_ready_not_port_conflict_and_stops_only_owned_child() {
        use copis_chrome::remote::credentials;
        let executable = PathBuf::from(std::env::var_os("MCC_PANEL_TEST_CLI").unwrap());
        let temp = Temp(std::env::temp_dir().join(copis_chrome::protocol::random_id().unwrap()));
        private_dir(&temp.0).unwrap();
        let tls = credentials::initialize_tls(&["127.0.0.1".into()], &temp.0.join("tls")).unwrap();
        let token_file = temp.0.join("host.token");
        credentials::initialize_token(&token_file).unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&token_file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let other = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = other.local_addr().unwrap();
        let mut settings = Settings {
            bin_dir: executable.parent().unwrap().into(),
            host: HostConfig {
                address: address.ip(),
                port: address.port(),
                certificate: tls.certificate,
                private_key: tls.private_key,
                token_file,
            },
        };
        let host = Host::default();
        host.start(&executable, &temp.0, &settings).unwrap();
        let failure = await_state(&host, "stopped");
        assert!(failure.message.unwrap().contains("REMOTE_LISTEN_FAILED"));
        assert!(TcpStream::connect(address).is_ok());
        let available = TcpListener::bind("127.0.0.1:0").unwrap();
        let ready_address = available.local_addr().unwrap();
        settings.host.port = ready_address.port();
        drop(available);
        host.start(&executable, &temp.0, &settings).unwrap();
        assert_eq!(
            await_state(&host, "running").listen.as_deref(),
            Some(ready_address.to_string().as_str())
        );
        assert!(TcpStream::connect(ready_address).is_ok());
        host.stop().unwrap();
        assert!(await_state(&host, "stopped").message.is_none());
        assert!(TcpStream::connect(ready_address).is_err());
        assert!(TcpStream::connect(address).is_ok());
    }
}
