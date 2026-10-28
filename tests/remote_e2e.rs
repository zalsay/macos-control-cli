use copis_chrome::remote::credentials;
use std::{
    net::{TcpListener, TcpStream},
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
struct ChildGuard(Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
#[test]
fn loopback_real_cli_status_twice_without_a_local_helper() {
    let id = copis_chrome::protocol::random_id().unwrap();
    let root = PathBuf::from(format!("/tmp/mcc-e2e-{}-{}", std::process::id(), &id[..8]));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let _fixture = Fixture(root.clone());
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let reserve = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = reserve.local_addr().unwrap();
    drop(reserve);
    let binary = env!("CARGO_BIN_EXE_mcc");
    let runtime = root.join("no-runtime");
    let helper = root.join("no-helper");
    let host_state = root.join("host");
    let client_state = root.join("client");
    let config = root.join("config");
    let host = Command::new(binary)
        .args([
            "host",
            "start",
            "--listen",
            &addr.to_string(),
            "--tls-cert",
            cert.certificate.to_str().unwrap(),
            "--tls-key",
            cert.private_key.to_str().unwrap(),
            "--token-file",
            token.to_str().unwrap(),
            "--state-dir",
            host_state.to_str().unwrap(),
        ])
        .env("MCC_CONFIG_DIR", &config)
        .env("COPIS_DESKTOP_RUNTIME_DIR", &runtime)
        .env("COPIS_DESKTOP_HELPER", &helper)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut host = ChildGuard(host);
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if TcpStream::connect_timeout(&addr, Duration::from_millis(100)).is_ok() {
            break;
        }
        if let Some(status) = host.0.try_wait().unwrap() {
            panic!("host exited before listening: {status}");
        }
        assert!(Instant::now() < deadline, "host did not listen");
        std::thread::sleep(Duration::from_millis(30));
    }
    let url = format!("wss://{addr}/mcc/v1");
    for _ in 0..2 {
        let output = Command::new(binary)
            .args([
                "--remote",
                &url,
                "--ca-cert",
                cert.ca_cert.to_str().unwrap(),
                "--token-file",
                token.to_str().unwrap(),
                "--remote-state-dir",
                client_state.to_str().unwrap(),
                "status",
            ])
            .env("MCC_CONFIG_DIR", &config)
            .env("COPIS_DESKTOP_RUNTIME_DIR", &runtime)
            .env("COPIS_DESKTOP_HELPER", &helper)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "remote CLI failed: {}",
            String::from_utf8_lossy(&output.stdout)
        );
        let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value["ok"], true);
        assert_eq!(value["running"], false);
    }
    assert!(
        !runtime.exists(),
        "read-only test must not start a daemon or helper"
    );
}
