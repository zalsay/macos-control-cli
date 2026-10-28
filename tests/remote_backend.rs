#![cfg(target_os = "macos")]
use copis_chrome::{
    daemon::{remote_call, remote_claim, remote_control_state, remote_recover_checked, run, stop},
    protocol::Scope,
    runtime::Runtime,
};
use serde_json::json;
use std::{
    fs,
    io::Write,
    time::{Duration, Instant},
};

#[test]
fn owner_process_death_pauses_slow_decision_without_host_drop() {
    use std::io::Read;
    use std::net::TcpListener;
    use std::process::{Child, Command, Stdio};
    const MODE: &str = "MCC_OWNER_DEATH_TEST_MODE";
    const NAME: &str = "owner_process_death_pauses_slow_decision_without_host_drop";
    const CAP: &str = "owner-death-test-capability";
    let mode = std::env::var(MODE).ok();
    if mode.as_deref() == Some("daemon") {
        run(&Runtime::from_env_for_scope(Scope::Chrome).unwrap()).unwrap();
        return;
    }
    if mode.as_deref() == Some("owner") {
        let runtime = Runtime::from_env_for_scope(Scope::Chrome).unwrap();
        let claimed = remote_claim(&runtime, CAP).unwrap();
        assert_eq!(claimed["ownerPid"], std::process::id());
        fs::write(
            runtime.root.join("claim-receipt.json"),
            serde_json::to_vec(&claimed).unwrap(),
        )
        .unwrap();
        let connection = remote_call(
            &runtime,
            CAP,
            "1",
            json!({"action":"connect","windowId":42}),
        )
        .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let endpoint = std::env::var("MCC_OWNER_DEATH_ENDPOINT").unwrap();
        let _ = remote_call(
            &runtime,
            CAP,
            "2",
            json!({"action":"click-target","connectionId":connection,"target":"Save","jevKey":"fixture-key","jevUrl":endpoint,"jevModel":"vendor/model","jevProtocol":copis_chrome::jev::DECISION_PROTOCOL}),
        );
        return;
    }
    struct Children {
        runtime: Runtime,
        daemon: Option<Child>,
        owner: Option<Child>,
    }
    impl Drop for Children {
        fn drop(&mut self) {
            if let Some(mut owner) = self.owner.take() {
                let _ = owner.kill();
                let _ = owner.wait();
            }
            let _ = stop(&self.runtime);
            if let Some(mut daemon) = self.daemon.take() {
                let _ = daemon.kill();
                let _ = daemon.wait();
            }
            let _ = fs::remove_dir_all(&self.runtime.root);
        }
    }
    let root = std::path::PathBuf::from(format!(
        "/tmp/mcc-death-{}",
        &copis_chrome::protocol::random_id().unwrap()[..12]
    ));
    let runtime = Runtime {
        root: root.clone(),
        frames: root.join("frames"),
        socket: root.join("daemon.sock"),
        scope: Scope::Chrome,
    };
    let fake =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-helper.sh");
    let exe = std::env::current_exe().unwrap();
    let daemon = Command::new(&exe)
        .args(["--exact", NAME, "--nocapture"])
        .env(MODE, "daemon")
        .env("COPIS_CHROME_RUNTIME_DIR", &root)
        .env("COPIS_CHROME_HELPER", fake)
        .env("MCC_FAKE_REMOTE_OCR", "1")
        .env(
            "MCC_FAKE_PREPARE_LEASE",
            std::env::var("MCC_OWNER_LEASE_CASE").unwrap_or_else(|_| "1".into()),
        )
        .env("MCC_FAKE_REMOTE_TRACE", root.join("clicks"))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut children = Children {
        runtime,
        daemon: Some(daemon),
        owner: None,
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while !children.runtime.socket.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        children.runtime.socket.exists(),
        "fixture daemon did not start"
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}/decisions", listener.local_addr().unwrap());
    children.owner = Some(
        Command::new(&exe)
            .args(["--exact", NAME, "--nocapture"])
            .env(MODE, "owner")
            .env("COPIS_CHROME_RUNTIME_DIR", &root)
            .env("MCC_OWNER_DEATH_ENDPOINT", endpoint)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut model = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(e) => panic!("fake decision did not start: {e}"),
        }
    };
    model
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    // Same-user possession of the capability does not impersonate the Host PID.
    assert_eq!(
        remote_call(&children.runtime, CAP, "3", json!({"action":"status"}))
            .unwrap_err()
            .code,
        "RECOVERY_REQUIRED"
    );
    let mut buf = [0u8; 1024];
    assert!(model.read(&mut buf).unwrap() > 0);
    let mut owner = children.owner.take().unwrap();
    owner.kill().unwrap();
    owner.wait().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    let state = loop {
        let state = remote_control_state(&children.runtime, CAP).unwrap();
        if state["paused"] == true {
            break state;
        }
        if Instant::now() >= deadline {
            panic!("daemon did not independently pause after owner SIGKILL");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(state["recoveryRequired"], true);
    assert!(
        children
            .daemon
            .as_mut()
            .unwrap()
            .try_wait()
            .unwrap()
            .is_none(),
        "original daemon must remain alive"
    );
    if std::env::var("MCC_OWNER_LEASE_CASE").as_deref() == Ok("0") {
        assert!(state["lease"].is_null());
    } else {
        assert_eq!(state["lease"], 1);
    }
    let body = r#"{"model":"vendor/model","answers":{"target":{"type":"choice","choice":"t0","confidence":0.98,"probabilities":{"t0":0.99,"none":0.01}}}}"#;
    let reply = format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = model.write_all(reply.as_bytes());
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        !root.join("clicks").exists(),
        "late model result must not dispatch click"
    );
    assert_eq!(
        remote_call(&children.runtime, CAP, "3", json!({"action":"status"}))
            .unwrap_err()
            .code,
        "RECOVERY_REQUIRED"
    );
    let claim: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("claim-receipt.json")).unwrap()).unwrap();
    let daemon_pid = claim["daemonPid"].as_u64().unwrap() as u32;
    let helper_pid = claim["helperPid"].as_u64().unwrap() as u32;
    for (wrong_daemon, wrong_helper) in [
        (daemon_pid.wrapping_add(1), helper_pid),
        (daemon_pid, helper_pid.wrapping_add(1)),
    ] {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let error = remote_recover_checked(&children.runtime, CAP, wrong_daemon, wrong_helper)
                .unwrap_err();
            if error.code == "BUSY" && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(10));
                continue;
            }
            assert_eq!(error.code, "RECOVERY_REQUIRED");
            break;
        }
        let after = remote_control_state(&children.runtime, CAP).unwrap();
        for field in ["paused", "phase", "inputEpoch", "lease", "recoveryRequired"] {
            assert_eq!(after[field], state[field], "{field}");
        }
    }
    assert_eq!(
        remote_recover_checked(&children.runtime, CAP, daemon_pid, helper_pid).unwrap()
            ["recovered"],
        true
    );
}

#[test]
fn owner_death_before_first_native_lease_fails_closed() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "owner_process_death_pauses_slow_decision_without_host_drop",
            "--nocapture",
        ])
        .env("MCC_OWNER_LEASE_CASE", "0")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "no-lease child failed: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
