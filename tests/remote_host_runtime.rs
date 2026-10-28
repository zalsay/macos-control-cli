#![cfg(target_os = "macos")]
use std::{
    fs,
    net::{TcpListener, TcpStream},
    os::unix::fs::DirBuilderExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

struct Fixture {
    root: PathBuf,
    host: Option<Child>,
}
impl Fixture {
    fn command(&self) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_mcc"));
        cmd.env("MCC_CONFIG_DIR", self.root.join("config"))
            .env("COPIS_DESKTOP_RUNTIME_DIR", self.root.join("runtime"))
            .env(
                "COPIS_DESKTOP_HELPER",
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/remote-process-helper.sh"),
            )
            .env_remove("JEV_API_KEY")
            .env_remove("OPENROUTER_API_KEY")
            .env_remove("TYPESAFE_API_KEY");
        cmd
    }
    fn run(&self, args: &[&str]) -> serde_json::Value {
        let out = self.command().args(args).output().unwrap();
        serde_json::from_slice(&out.stdout).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(mut host) = self.host.take() {
            unsafe {
                libc::kill(host.id() as i32, libc::SIGTERM);
            }
            let _ = host.wait();
        }
        if self.root.join("runtime/daemon.sock").exists() {
            let _ = self.command().args(["daemon", "stop"]).output();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
#[test]
fn first_remote_windows_starts_only_private_fixture_daemon() {
    let root = PathBuf::from("/tmp").join(format!(
        "mcc-hr-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let mut f = Fixture { root, host: None };
    let tls = f.root.join("tls");
    let token = f.root.join("token");
    let state = f.root.join("state");
    let client = f.root.join("client");
    let text = |p: &Path| p.to_str().unwrap().to_owned();
    assert_eq!(
        f.run(&[
            "host",
            "tls",
            "init",
            "--ip",
            "127.0.0.1",
            "--output-dir",
            &text(&tls)
        ])["ok"],
        true
    );
    assert_eq!(
        f.run(&["host", "token", "init", "--output", &text(&token)])["ok"],
        true
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let host = f
        .command()
        .args([
            "host",
            "start",
            "--listen",
            &address.to_string(),
            "--tls-cert",
            &text(&tls.join("host-cert.pem")),
            "--tls-key",
            &text(&tls.join("host-key.pem")),
            "--token-file",
            &text(&token),
            "--state-dir",
            &text(&state),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    f.host = Some(host);
    let limit = Instant::now() + Duration::from_secs(5);
    while TcpStream::connect(address).is_err() {
        assert!(Instant::now() < limit);
        std::thread::sleep(Duration::from_millis(20));
    }
    let result = f.run(&[
        "--remote",
        &format!("wss://{address}/mcc/v1"),
        "--ca-cert",
        &text(&tls.join("host-ca.pem")),
        "--token-file",
        &text(&token),
        "--remote-state-dir",
        &text(&client),
        "windows",
    ]);
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["windows"][0]["windowId"], 42);
}
