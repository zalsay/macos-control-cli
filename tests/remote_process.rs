#![cfg(target_os = "macos")]
//! Black-box loopback coverage. The helper only simulates native operations.
use serde_json::Value;
use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    os::unix::fs::{symlink, DirBuilderExt, PermissionsExt},
    os::unix::process::CommandExt,
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc, Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

static NEXT: AtomicUsize = AtomicUsize::new(0);
static RESERVED_PORTS: OnceLock<Mutex<HashSet<u16>>> = OnceLock::new();
const LIMIT: Duration = Duration::from_secs(15);

fn test_cli() -> PathBuf {
    match std::env::var_os("MCC_REMOTE_TEST_CLI") {
        Some(path) => {
            let path = PathBuf::from(path);
            assert!(
                path.is_absolute(),
                "MCC_REMOTE_TEST_CLI must be an absolute path"
            );
            path
        }
        None => PathBuf::from(env!("CARGO_BIN_EXE_mcc")),
    }
}

fn finish(mut child: Child, limit: Duration) -> Output {
    let end = Instant::now() + limit;
    loop {
        if child.try_wait().expect("wait for CLI").is_some() {
            return child.wait_with_output().expect("collect CLI");
        }
        if Instant::now() >= end {
            let _ = child.kill();
            let output = child.wait_with_output().expect("reap timed out CLI");
            panic!(
                "CLI timed out: stdout={} stderr={}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
fn run(cmd: &mut Command) -> Output {
    finish(
        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn CLI"),
        LIMIT,
    )
}
fn json(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "invalid JSON {e}: stdout={} stderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    })
}
fn ok(out: &Output) -> Value {
    let v = json(out);
    assert!(
        out.status.success(),
        "{v} stderr={}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(v["ok"], true, "{v}");
    v
}
fn s(p: &Path) -> &str {
    p.to_str().unwrap()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ProcessIdentity {
    pid: i32,
    uid: u32,
    group: i32,
    started_sec: u64,
    started_usec: u64,
}
fn process_identity(pid: i32) -> Option<ProcessIdentity> {
    if pid <= 0 {
        return None;
    }
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>();
    let count = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size as i32,
        )
    };
    let group = unsafe { libc::getpgid(pid) };
    if count != size as i32
        || info.pbi_pid != pid as u32
        || group <= 0
        || info.pbi_pgid != group as u32
    {
        return None;
    }
    Some(ProcessIdentity {
        pid,
        uid: info.pbi_uid,
        group,
        started_sec: info.pbi_start_tvsec,
        started_usec: info.pbi_start_tvusec,
    })
}
fn signal_verified_group(group: i32, owned: &[ProcessIdentity]) -> bool {
    if group <= 0
        || !owned
            .iter()
            .any(|old| old.group == group && process_identity(old.pid) == Some(*old))
    {
        return false;
    }
    // Never signal a guessed or stale group: at least one captured original
    // member must still match PID, start time, uid, and current pgid.
    unsafe { libc::kill(-group, libc::SIGKILL) == 0 }
}

struct ProcessGuard {
    root: PathBuf,
    host: Option<Child>,
    port: u16,
    groups: Vec<i32>,
    owned: Mutex<Vec<ProcessIdentity>>,
}
impl ProcessGuard {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/tmp/mcc-rp-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        // Binding to port 0 and immediately releasing it can otherwise assign
        // the same port to concurrent fixtures in this test binary.
        let ports = RESERVED_PORTS.get_or_init(|| Mutex::new(HashSet::new()));
        let port = loop {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            if ports.lock().unwrap().insert(port) {
                break port;
            }
        };
        Self {
            root,
            host: None,
            port,
            groups: Vec::new(),
            owned: Mutex::new(Vec::new()),
        }
    }
    fn command(&self, host: bool) -> Command {
        let mut c = Command::new(test_cli());
        c.current_dir(&self.root)
            .env_remove("JEV_API_KEY")
            .env_remove("OPENROUTER_API_KEY")
            .env_remove("TYPESAFE_API_KEY")
            .env_remove("MCC_FAKE_REMOTE_OCR")
            .env(
                "MCC_CONFIG_DIR",
                self.root
                    .join(if host { "host-config" } else { "client-config" }),
            )
            .env(
                "COPIS_DESKTOP_RUNTIME_DIR",
                self.root.join(if host {
                    "host-runtime"
                } else {
                    "client-runtime"
                }),
            )
            .env(
                "COPIS_DESKTOP_HELPER",
                if host {
                    format!(
                        "{}/tests/fixtures/remote-process-helper.sh",
                        env!("CARGO_MANIFEST_DIR")
                    )
                } else {
                    "/must-not-start".into()
                },
            );
        if host && self.root.join("fixture-ocr").exists() {
            c.env("MCC_FAKE_REMOTE_OCR", "1");
        }
        c
    }
    fn init(&self) {
        for name in ["tls", "wrong-tls"] {
            ok(&run(self.command(true).args([
                "host",
                "tls",
                "init",
                "--ip",
                "127.0.0.1",
                "--output-dir",
                s(&self.root.join(name)),
            ])));
        }
        for name in ["token", "wrong-token"] {
            ok(&run(self.command(true).args([
                "host",
                "token",
                "init",
                "--output",
                s(&self.root.join(name)),
            ])));
        }
    }
    fn start(&mut self) {
        self.start_with_root(None);
    }
    fn start_with_root(&mut self, allowed_root: Option<&Path>) {
        let mut c = self.command(true);
        let log = fs::File::create(self.root.join("host.log")).unwrap();
        // All processes spawned by this private Host inherit a test-only group.
        unsafe {
            c.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
        c.args([
            "host",
            "start",
            "--listen",
            &format!("127.0.0.1:{}", self.port),
            "--tls-cert",
            s(&self.root.join("tls/host-cert.pem")),
            "--tls-key",
            s(&self.root.join("tls/host-key.pem")),
            "--token-file",
            s(&self.root.join("token")),
            "--state-dir",
            s(&self.root.join("host-state")),
        ]);
        if let Some(root) = allowed_root {
            c.args(["--files-root", s(root)]);
        }
        let child = c
            .stdin(Stdio::null())
            .stdout(Stdio::from(log.try_clone().unwrap()))
            .stderr(Stdio::from(log))
            .spawn()
            .unwrap();
        self.groups.push(child.id() as i32);
        self.host = Some(child);
        let end = Instant::now() + LIMIT;
        loop {
            if let Some(status) = self.host.as_mut().unwrap().try_wait().unwrap() {
                panic!(
                    "host exited {status}: {}",
                    fs::read_to_string(self.root.join("host.log")).unwrap_or_default()
                );
            }
            // lsof is only used to identify this child’s listener; a bare TCP
            // connection could accidentally reach a different test Host.
            let listener = run(Command::new("/usr/sbin/lsof").args([
                "-nP",
                "-a",
                "-p",
                &self.host.as_ref().unwrap().id().to_string(),
                &format!("-iTCP:{}", self.port),
                "-sTCP:LISTEN",
                "-t",
            ]));
            if listener.status.success() && TcpStream::connect(("127.0.0.1", self.port)).is_ok() {
                break;
            }
            assert!(
                Instant::now() < end,
                "host readiness timeout: {}",
                fs::read_to_string(self.root.join("host.log")).unwrap_or_default()
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn capture_owned(&self) {
        let journal = match fs::read(self.root.join("host-state/host.json")) {
            Ok(data) => data,
            Err(_) => return,
        };
        let journal: Value = match serde_json::from_slice(&journal) {
            Ok(v) => v,
            Err(_) => return,
        };
        let mut captured = self.owned.lock().unwrap_or_else(|e| e.into_inner());
        for key in ["daemonPid", "helperPid"] {
            let Some(pid) = journal[key].as_i64().and_then(|n| i32::try_from(n).ok()) else {
                continue;
            };
            // Do not silently replace a captured PID identity if it is reused.
            if captured.iter().any(|old| old.pid == pid) {
                continue;
            }
            if let Some(identity) = process_identity(pid) {
                if identity.uid == unsafe { libc::geteuid() }
                    && self.groups.contains(&identity.group)
                {
                    captured.push(identity);
                }
            }
        }
    }
    fn stop_host(&mut self) {
        self.capture_owned();
        if let Some(mut child) = self.host.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    fn remote_command(&self, state: &str, ca: &str, token: &str, args: &[&str]) -> Command {
        let mut command = self.command(false);
        command
            .args([
                "--remote",
                &format!("wss://127.0.0.1:{}/mcc/v1", self.port),
                "--ca-cert",
                s(&self.root.join(ca)),
                "--token-file",
                s(&self.root.join(token)),
                "--remote-state-dir",
                s(&self.root.join(state)),
            ])
            .args(args);
        command
    }
    fn remote(&self, state: &str, ca: &str, token: &str, args: &[&str]) -> Output {
        let mut output = run(&mut self.remote_command(state, ca, token, args));
        self.capture_owned();
        if !output.status.success() {
            if let Ok(log) = fs::read(self.root.join("host.log")) {
                output.stderr.extend_from_slice(b"\n[test Host log]\n");
                output.stderr.extend_from_slice(&log);
            }
        }
        output
    }
    fn isolated(&self) {
        assert!(!self.root.join("client-runtime").exists());
        assert!(!self.root.join("client-config/models.toml").exists());
    }
    fn native(&self) -> String {
        fs::read_to_string(self.root.join("host-runtime/native-requests.ndjson"))
            .unwrap_or_default()
    }
}
impl Drop for ProcessGuard {
    fn drop(&mut self) {
        self.stop_host();
        if self.root.join("host-runtime/daemon.sock").exists() {
            // Restrict shutdown to the runtime created by this test, never the user's daemon.
            let _ = std::panic::catch_unwind(|| run(self.command(true).args(["daemon", "stop"])));
            let until = Instant::now() + Duration::from_secs(3);
            while self.root.join("host-runtime/daemon.sock").exists() && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        if self.root.join("host-runtime/daemon.sock").exists() {
            let owned = self.owned.lock().unwrap_or_else(|e| e.into_inner());
            let mut signalled = false;
            for &group in &self.groups {
                signalled |= signal_verified_group(group, &owned);
            }
            // A socket can outlive its process. Preserve evidence whether or not
            // the verified fallback could be signalled; never guess or claim reaping.
            eprintln!(
                "test cleanup unconfirmed; verified group signal={signalled}; retained {}",
                self.root.display()
            );
        } else {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

#[test]
fn authentication_failures_never_start_host_daemon_or_client_runtime() {
    let mut f = ProcessGuard::new();
    f.init();
    f.start();
    // Prove the same live Host accepts valid WSS before interpreting either
    // negative as an authentication/CA check rather than a transport failure.
    let probe = ok(&f.remote("probe", "tls/host-ca.pem", "token", &["status"]));
    assert_eq!(
        probe["running"], false,
        "read-only probe must not start daemon"
    );
    assert!(!f.root.join("host-runtime/daemon.sock").exists());
    for (ca, token) in [
        ("wrong-tls/host-ca.pem", "token"),
        ("tls/host-ca.pem", "wrong-token"),
    ] {
        let out = f.remote("client-state", ca, token, &["connect", "--window", "42"]);
        assert!(
            !out.status.success(),
            "authentication unexpectedly succeeded: {}",
            json(&out)
        );
        assert!(!f.root.join("host-runtime/daemon.sock").exists());
        assert!(f.native().is_empty());
        f.isolated();
    }
}

#[test]
fn offline_remote_does_not_fall_back_to_local_runtime() {
    let f = ProcessGuard::new();
    f.init();
    let out = f.remote(
        "client-state",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    );
    assert!(!out.status.success());
    f.isolated();
}

#[test]
fn independent_cli_processes_preserve_connection_frame_and_host_model_policy() {
    let mut f = ProcessGuard::new();
    f.init();
    let cfg = f.root.join("host-config");
    fs::DirBuilder::new().mode(0o700).create(&cfg).unwrap();
    let cloud = TcpListener::bind("127.0.0.1:0").unwrap();
    cloud.set_nonblocking(true).unwrap();
    let models = cfg.join("models.toml");
    fs::write(&models, format!("default_model = 'jev'\n[models.jev]\nenabled = false\nurl = 'http://{}/decisions'\napi_key = 'fixture-only'\nmodel = 'fixture'\n", cloud.local_addr().unwrap())).unwrap();
    fs::set_permissions(models, fs::Permissions::from_mode(0o600)).unwrap();
    f.start();
    let call = |args: &[&str]| f.remote("client-state", "tls/host-ca.pem", "token", args);
    let connect = ok(&call(&["connect", "--window", "42"]));
    assert_eq!(connect["scope"], "desktop");
    let id = connect["connectionId"].as_str().expect("connectionId");
    let observed = ok(&call(&["observe", "--connection", id]));
    assert_eq!(observed["scope"], "desktop");
    let frame = observed["frameId"].as_str().expect("frameId");
    let image = PathBuf::from(observed["imagePath"].as_str().expect("local imagePath"));
    assert_eq!(
        fs::metadata(&image).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let mut data = Vec::new();
    fs::File::open(&image)
        .unwrap()
        .read_to_end(&mut data)
        .unwrap();
    // Structurally framed fixture, not a decoded real screen capture.
    assert_eq!(
        data,
        [
            0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0x04, 0xb0, 0x06, 0x40, 1, 1, 0x11, 0, 0xff, 0xda, 0,
            8, 1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9,
        ]
    );
    assert_eq!(observed["width"], 1600);
    assert_eq!(observed["height"], 1200);
    let clicked = ok(&call(&[
        "click",
        "--connection",
        id,
        "--frame",
        frame,
        "--x",
        "10",
        "--y",
        "10",
    ]));
    assert_eq!(clicked["sent"], true);
    assert_eq!(clicked["scope"], "desktop");
    let before = f.native();
    let disabled = json(&call(&[
        "click-target",
        "--connection",
        id,
        "--target",
        "保存",
    ]));
    assert_eq!(disabled["error"]["code"], "MODEL_DISABLED", "{disabled}");
    let after = f.native();
    for line in after[before.len()..].lines() {
        let request: Value = serde_json::from_str(line).expect("native request JSON");
        assert!(
            !matches!(request["action"].as_str(), Some("observe" | "ocr")),
            "disabled model invoked native capture/OCR: {request}"
        );
    }
    assert!(
        cloud.accept().is_err(),
        "disabled model must not contact the fake cloud"
    );
    let other = json(&f.remote(
        "other-state",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    assert_ne!(
        other["ok"], true,
        "another session must not seize control: {other}"
    );
    ok(&call(&["disconnect", "--connection", id]));
    f.isolated();
}

#[test]
fn simultaneous_other_sessions_cannot_steal_existing_control() {
    let mut f = ProcessGuard::new();
    f.init();
    f.start();
    let owner = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    let id = owner["connectionId"].as_str().unwrap();
    std::thread::scope(|scope| {
        let a = scope.spawn(|| {
            f.remote(
                "other-a",
                "tls/host-ca.pem",
                "token",
                &["connect", "--window", "42"],
            )
        });
        let b = scope.spawn(|| {
            f.remote(
                "other-b",
                "tls/host-ca.pem",
                "token",
                &["connect", "--window", "42"],
            )
        });
        for output in [a.join().unwrap(), b.join().unwrap()] {
            assert!(
                !output.status.success(),
                "another session seized control: {}",
                json(&output)
            );
        }
    });
    ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["observe", "--connection", id],
    ));
    ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["disconnect", "--connection", id],
    ));
    f.isolated();
}

#[test]
fn host_restart_does_not_resume_old_control_implicitly() {
    let mut f = ProcessGuard::new();
    f.init();
    f.start();
    let owner = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    let id = owner["connectionId"].as_str().unwrap().to_owned();
    let frame = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["observe", "--connection", &id],
    ));
    let frame = frame["frameId"].as_str().unwrap().to_owned();
    f.stop_host();
    f.start();
    let before = f.native();
    let out = f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &[
            "click",
            "--connection",
            &id,
            "--frame",
            &frame,
            "--x",
            "10",
            "--y",
            "10",
        ],
    );
    assert!(
        !out.status.success(),
        "restart must require recovery: {}",
        json(&out)
    );
    assert!(
        !f.native()[before.len()..].contains("\"action\":\"click\""),
        "restart dispatched input"
    );
    let fresh = f.remote(
        "fresh",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    );
    assert!(!fresh.status.success());
    let recovery = json(&fresh);
    assert_eq!(recovery["error"]["code"], "RECOVERY_REQUIRED", "{recovery}");
    f.isolated();
}

#[test]
fn invalid_server_protocol_does_not_fall_back_to_local_runtime() {
    let f = ProcessGuard::new();
    f.init();
    let listener = TcpListener::bind(("127.0.0.1", f.port)).unwrap();
    listener.set_nonblocking(true).unwrap();
    let server = std::thread::spawn(move || {
        let until = Instant::now() + LIMIT;
        loop {
            match listener.accept() {
                Ok((mut socket, _)) => {
                    socket
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut hello = [0_u8; 3];
                    socket
                        .read_exact(&mut hello)
                        .expect("client must send a TLS ClientHello");
                    assert_eq!(hello[0], 0x16, "not a TLS handshake record");
                    assert_eq!(hello[1], 0x03, "not a TLS record version");
                    socket
                        .set_write_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    socket.write_all(b"not TLS or WebSocket\n").unwrap();
                    return;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < until => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                Err(e) => panic!("fake server accept: {e}"),
            }
        }
    });
    let out = f.remote(
        "client-state",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    );
    server.join().unwrap();
    assert!(!out.status.success());
    f.isolated();
}

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[test]
fn fallback_signals_only_a_matching_captured_process_identity() {
    let mut command = Command::new("/bin/sleep");
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
    let mut child = OwnedChild(command.arg("30").spawn().unwrap());
    let pid = child.0.id() as i32;
    let identity = process_identity(pid).expect("capture owned child identity");
    let mut stale = identity;
    stale.started_usec ^= 1;
    let mut wrong_uid = identity;
    wrong_uid.uid ^= 1;
    let mut wrong_group = identity;
    wrong_group.group ^= 1;
    for wrong in [stale, wrong_uid, wrong_group] {
        assert!(!signal_verified_group(pid, &[wrong]));
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "mismatched identity must not be signalled"
        );
    }
    assert!(signal_verified_group(pid, &[identity]));
    let end = Instant::now() + Duration::from_secs(3);
    loop {
        if child.0.try_wait().unwrap().is_some() {
            break;
        }
        assert!(Instant::now() < end, "verified owned child was not killed");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn native_action_count(f: &ProcessGuard, action: &str) -> usize {
    f.native()
        .lines()
        .filter(|line| {
            serde_json::from_str::<Value>(line)
                .ok()
                .is_some_and(|v| v["action"] == action)
        })
        .count()
}

#[test]
fn remote_file_selection_requires_allowed_root_and_blocks_escape() {
    let mut f = ProcessGuard::new();
    f.init();
    let root = f.root.join("allowed");
    fs::create_dir(&root).unwrap();
    let inside = root.join("inside.txt");
    let outside = f.root.join("outside.txt");
    fs::write(&inside, b"fixture").unwrap();
    fs::write(&outside, b"fixture").unwrap();
    let escape = root.join("escape");
    symlink(&outside, &escape).unwrap();
    f.start_with_root(Some(&root));
    let owner = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    {
        let owned = f.owned.lock().unwrap();
        assert!(
            owned.len() >= 2,
            "capture daemon/helper PID, uid, start time and pgid from Host journal: {owned:?}"
        );
        assert!(owned.iter().all(|p| process_identity(p.pid) == Some(*p)));
    }
    let id = owner["connectionId"].as_str().unwrap();
    for path in [&outside, &escape] {
        let out = f.remote(
            "owner",
            "tls/host-ca.pem",
            "token",
            &["select-file", "--connection", id, "--path", s(path)],
        );
        assert!(!out.status.success());
        let v = json(&out);
        assert_eq!(v["error"]["code"], "FILE_NOT_ALLOWED", "{v}");
        assert_eq!(native_action_count(&f, "select-file"), 0);
    }
    let selected = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["select-file", "--connection", id, "--path", s(&inside)],
    ));
    assert_eq!(selected["selected"], true);
    assert_eq!(selected["dialogClosed"], true);
    assert_eq!(native_action_count(&f, "select-file"), 1);
    ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["disconnect", "--connection", id],
    ));
    f.isolated();
}

#[test]
fn remote_file_selection_without_configured_root_is_denied_before_native() {
    let mut f = ProcessGuard::new();
    f.init();
    let file = f.root.join("file.txt");
    fs::write(&file, b"fixture").unwrap();
    f.start();
    let owner = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    let id = owner["connectionId"].as_str().unwrap();
    let out = f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["select-file", "--connection", id, "--path", s(&file)],
    );
    assert!(!out.status.success());
    let v = json(&out);
    assert_eq!(v["error"]["code"], "FILE_NOT_ALLOWED", "{v}");
    assert_eq!(native_action_count(&f, "select-file"), 0);
    ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["disconnect", "--connection", id],
    ));
    f.isolated();
}

#[test]
fn stale_socket_without_captured_identity_never_kills_and_preserves_diagnostics() {
    use std::os::unix::net::UnixListener;
    let mut child_command = Command::new("/bin/sleep");
    unsafe {
        child_command.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
    let mut child = OwnedChild(child_command.arg("30").spawn().unwrap());
    let mut f = ProcessGuard::new();
    f.groups.push(child.0.id() as i32);
    let root = f.root.clone();
    let runtime = root.join("host-runtime");
    fs::DirBuilder::new().mode(0o700).create(&runtime).unwrap();
    drop(UnixListener::bind(runtime.join("daemon.sock")).unwrap());
    drop(f);
    assert!(
        child.0.try_wait().unwrap().is_none(),
        "uncaptured process group must not be killed"
    );
    assert!(
        root.join("host-runtime/daemon.sock").exists(),
        "unconfirmed cleanup must retain evidence"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn failed_first_connect_is_acked_and_a_different_session_can_claim_control() {
    let mut f = ProcessGuard::new();
    f.init();
    f.start();
    let failed = f.remote(
        "client-a",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "999"],
    );
    assert!(!failed.status.success());
    let failure = json(&failed);
    assert_eq!(
        failure["error"]["code"], "WINDOW_UNAVAILABLE",
        "failed connect must receive a normal acknowledged outcome: {failure}"
    );
    assert!(
        native_action_count(&f, "windows") >= 1,
        "missing window must reach the native window list"
    );
    assert_eq!(
        native_action_count(&f, "window"),
        0,
        "no window lease for a missing window"
    );
    assert_eq!(native_action_count(&f, "transport-pause"), 0);
    let connected = ok(&f.remote(
        "client-b",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    let id = connected["connectionId"]
        .as_str()
        .expect("new owner connectionId");
    assert_eq!(connected["window"]["windowId"], 42);
    ok(&f.remote(
        "client-b",
        "tls/host-ca.pem",
        "token",
        &["disconnect", "--connection", id],
    ));
    f.isolated();
}

#[test]
fn failed_remote_claim_does_not_take_over_an_existing_local_connection() {
    let mut f = ProcessGuard::new();
    f.init();
    let local = ok(&run(f.command(true).args(["connect", "--window", "42"])));
    let id = local["connectionId"].as_str().expect("local connectionId");
    let observed = ok(&run(f.command(true).args(["observe", "--connection", id])));
    let frame = observed["frameId"].as_str().expect("local frameId");
    f.start();
    let before = f.native();
    let failed = f.remote(
        "client-a",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "999"],
    );
    assert!(!failed.status.success());
    let failure = json(&failed);
    assert_eq!(
        failure["error"]["code"], "BUSY",
        "must reject an existing external local connection: {failure}"
    );
    let after = f.native();
    for line in after[before.len()..].lines() {
        let request: Value = serde_json::from_str(line).unwrap();
        assert!(
            !matches!(
                request["action"].as_str(),
                Some("cancel" | "transport-pause" | "transport-disconnect")
            ),
            "remote claim disturbed local connection: {request}"
        );
    }
    let clicked = ok(&run(f.command(true).args([
        "click",
        "--connection",
        id,
        "--frame",
        frame,
        "--x",
        "10",
        "--y",
        "10",
    ])));
    assert_eq!(
        clicked["sent"], true,
        "original local connection and frame remain usable"
    );
    ok(&run(f.command(true).args([
        "disconnect",
        "--connection",
        id,
    ])));
    let remote = ok(&f.remote(
        "client-b",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    assert_eq!(remote["window"]["windowId"], 42);
    let remote_id = remote["connectionId"]
        .as_str()
        .expect("remote connectionId");
    ok(&f.remote(
        "client-b",
        "tls/host-ca.pem",
        "token",
        &["disconnect", "--connection", remote_id],
    ));
    f.isolated();
}

/// Loopback-only fake Decisions server. Never contacts any external service.
struct FakeCloud {
    port: u16,
    request: mpsc::Receiver<Value>,
    closed: mpsc::Receiver<bool>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl FakeCloud {
    fn new(slow: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port();
        let (request_tx, request) = mpsc::channel();
        let (closed_tx, closed) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = Arc::clone(&stop);
        let thread = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(25);
            let (mut socket, _) = loop {
                match listener.accept() {
                    Ok(pair) => break pair,
                    Err(e)
                        if e.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline
                            && !stopped.load(Ordering::Acquire) =>
                    {
                        std::thread::sleep(Duration::from_millis(20))
                    }
                    _ => return,
                }
            };
            socket
                .set_read_timeout(Some(Duration::from_millis(200)))
                .unwrap();
            socket
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut data = Vec::new();
            let mut payload = None;
            while Instant::now() < deadline && !stopped.load(Ordering::Acquire) {
                let mut buf = [0; 4096];
                match socket.read(&mut buf) {
                    Ok(0) => return,
                    Ok(n) => {
                        data.extend_from_slice(&buf[..n]);
                        assert!(data.len() <= 80 * 1024);
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        continue
                    }
                    Err(_) => return,
                }
                if let Some(i) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&data[..i]);
                    let len = headers
                        .lines()
                        .find_map(|line| {
                            line.split_once(':').and_then(|(k, v)| {
                                k.eq_ignore_ascii_case("content-length")
                                    .then(|| v.trim().parse::<usize>().unwrap())
                            })
                        })
                        .expect("bounded Content-Length");
                    if data.len() >= i + 4 + len {
                        payload = Some(serde_json::from_slice(&data[i + 4..i + 4 + len]).unwrap());
                        break;
                    }
                }
            }
            let Some(payload) = payload else {
                return;
            };
            let _ = request_tx.send(payload);
            if slow {
                while Instant::now() < deadline && !stopped.load(Ordering::Acquire) {
                    let mut byte = [0; 1];
                    match socket.read(&mut byte) {
                        Ok(0) => {
                            let _ = closed_tx.send(true);
                            return;
                        }
                        Err(e)
                            if matches!(
                                e.kind(),
                                std::io::ErrorKind::ConnectionReset
                                    | std::io::ErrorKind::BrokenPipe
                            ) =>
                        {
                            let _ = closed_tx.send(true);
                            return;
                        }
                        Err(e)
                            if matches!(
                                e.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                            ) => {}
                        _ => return,
                    }
                }
                let _ = closed_tx.send(false);
            } else {
                let body = br#"{"model":"fixture/model","answers":{"target":{"type":"choice","choice":"t0","confidence":0.98,"probabilities":{"t0":0.99,"none":0.01}}}}"#;
                let headers = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                socket.write_all(headers.as_bytes()).unwrap();
                socket.write_all(body).unwrap();
                // Keep the endpoint listening briefly after the response to
                // catch retries instead of making a second request invisible.
                let end = Instant::now() + Duration::from_millis(300);
                while Instant::now() < end && !stopped.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok(_) => {
                            let _ = closed_tx.send(false);
                            return;
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(10))
                        }
                        Err(_) => {
                            let _ = closed_tx.send(false);
                            return;
                        }
                    }
                }
                let _ = closed_tx.send(true);
            }
        });
        Self {
            port,
            request,
            closed,
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for FakeCloud {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
fn enable_fake_cloud(f: &ProcessGuard, cloud: &FakeCloud) {
    fs::write(f.root.join("fixture-ocr"), b"enable").unwrap();
    let dir = f.root.join("host-config");
    fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    let path = dir.join("models.toml");
    fs::write(&path, format!("default_model = 'jev'\n[models.jev]\nenabled = true\nurl = 'http://127.0.0.1:{}/decisions'\napi_key = 'fixture-only'\nmodel = 'fixture/model'\n", cloud.port)).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn verify_cloud_request(value: &Value) {
    assert_eq!(value["state"], serde_json::json!({"target":"Save"}));
    assert_eq!(
        value["questions"]["target"]["criteria"],
        serde_json::json!({"t0":"Save", "none":"No matching label."})
    );
    let root = value.as_object().unwrap();
    assert_eq!(root.len(), 3);
    assert!(
        root.contains_key("model") && root.contains_key("state") && root.contains_key("questions")
    );
    let question = value["questions"]["target"].as_object().unwrap();
    assert_eq!(question.len(), 3);
    assert!(
        question.contains_key("type")
            && question.contains_key("instructions")
            && question.contains_key("criteria")
    );
    let text = value.to_string();
    for forbidden in [
        "bbox",
        "center",
        "screenPoint",
        "imagePath",
        "width",
        "height",
        "base64",
    ] {
        assert!(
            !text.contains(forbidden),
            "cloud request leaks {forbidden}: {text}"
        );
    }
}

#[test]
fn remote_click_target_uses_host_ocr_and_one_loopback_decision() {
    let mut f = ProcessGuard::new();
    f.init();
    let cloud = FakeCloud::new(false);
    enable_fake_cloud(&f, &cloud);
    f.start();
    let connected = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    let id = connected["connectionId"].as_str().unwrap();
    let result = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["click-target", "--connection", id, "--target", "Save"],
    ));
    verify_cloud_request(
        &cloud
            .request
            .recv_timeout(LIMIT)
            .expect("one fake HTTP request"),
    );
    assert!(cloud.request.try_recv().is_err(), "only one HTTP request");
    assert!(cloud.closed.recv_timeout(LIMIT).unwrap());
    assert!(
        result.get("imagePath").is_none(),
        "click-target must not return or transfer its internal image: {result}"
    );
    assert_eq!(result["selection"]["candidateId"], "t0");
    assert_eq!(result["screenPoint"]["x"], 30.0);
    assert_eq!(result["screenPoint"]["y"], 20.0);
    assert_eq!(native_action_count(&f, "observe"), 1);
    assert_eq!(native_action_count(&f, "click"), 1);
    let frame = result["frameId"].as_str().expect("click-target frameId");
    let press = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &[
            "press",
            "--connection",
            id,
            "--frame",
            frame,
            "--key",
            "Enter",
        ],
    ));
    assert_eq!(press["sent"], true);
    assert_eq!(native_action_count(&f, "press"), 1);
    assert_eq!(
        native_action_count(&f, "observe"),
        1,
        "frame reuse must not trigger an extra observe"
    );
    assert_eq!(native_action_count(&f, "click"), 1);
    ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["disconnect", "--connection", id],
    ));
    f.isolated();
}

#[test]
fn lost_remote_client_cancels_jev_and_pauses_input_but_allows_observation() {
    let mut f = ProcessGuard::new();
    f.init();
    let cloud = FakeCloud::new(true);
    enable_fake_cloud(&f, &cloud);
    f.start();
    let connected = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["connect", "--window", "42"],
    ));
    let id = connected["connectionId"].as_str().unwrap();
    let observation = ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["observe", "--connection", id],
    ));
    let frame = observation["frameId"].as_str().unwrap();
    let mut child = OwnedChild(
        f.remote_command(
            "owner",
            "tls/host-ca.pem",
            "token",
            &["click-target", "--connection", id, "--target", "Save"],
        )
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap(),
    );
    let request = cloud
        .request
        .recv_timeout(LIMIT)
        .expect("slow fake cloud received HTTP request");
    verify_cloud_request(&request);
    child.0.kill().expect("kill only test client");
    child.0.wait().unwrap();
    assert!(
        cloud
            .closed
            .recv_timeout(LIMIT)
            .expect("cloud socket close after lost client"),
        "cloud HTTP connection was not cancelled"
    );
    let until = Instant::now() + LIMIT;
    let receipt = loop {
        let text = fs::read_to_string(f.root.join("host-runtime/native-pause-responses.ndjson"))
            .unwrap_or_default();
        if let Some(v) = text
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .find(|v| {
                v["ok"] == true
                    && v["data"]["transportPauseVersion"] == 1
                    && v["data"]["paused"] == true
            })
        {
            break v;
        }
        assert!(
            Instant::now() < until,
            "missing native transport-pause ACK; requests={}",
            f.native()
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    let ack_id = receipt["id"].as_str().unwrap();
    assert!(
        f.native()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .any(|v| v["action"] == "transport-pause" && v["id"] == ack_id),
        "pause ACK must match native request"
    );
    assert_eq!(native_action_count(&f, "click"), 0);
    let blocked = f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &[
            "click",
            "--connection",
            id,
            "--frame",
            frame,
            "--x",
            "10",
            "--y",
            "10",
        ],
    );
    assert!(
        !blocked.status.success(),
        "paused session must reject input: {}",
        json(&blocked)
    );
    let denied = json(&blocked);
    assert!(
        matches!(
            denied["error"]["code"].as_str(),
            Some("RECOVERY_REQUIRED" | "USER_PAUSED")
        ),
        "paused input must fail for a pause/recovery reason: {denied}"
    );
    assert_eq!(native_action_count(&f, "click"), 0);
    ok(&f.remote(
        "owner",
        "tls/host-ca.pem",
        "token",
        &["observe", "--connection", id],
    ));
    f.isolated();
}

// Wire-level client used only to replay the exact same session/id/sequence.
// All network traffic remains on loopback; Host is the separately compiled CLI.
type ReplaySocket = tungstenite::WebSocket<
    copis_chrome::remote::wire::UpgradeStream<
        rustls::StreamOwned<rustls::ClientConnection, copis_chrome::remote::wire::DeadlineTcp>,
    >,
>;
fn ws_json(ws: &mut ReplaySocket) -> Value {
    loop {
        match ws.read().expect("WSS message from Host") {
            tungstenite::Message::Text(text) => {
                return serde_json::from_str(&text).expect("Host JSON")
            }
            tungstenite::Message::Ping(_) | tungstenite::Message::Pong(_) => {
                ws.flush().unwrap();
            }
            other => panic!("expected WSS JSON, got {other:?}"),
        }
    }
}
fn replay_rpc(
    f: &ProcessGuard,
    session: Option<(&str, &str)>,
    id: &str,
    sequence: u64,
    request: Value,
) -> (String, String, Value, Vec<u8>) {
    use copis_chrome::remote::{credentials, wire};
    use tungstenite::Message;
    let ca = f.root.join("tls/host-ca.pem");
    let config = credentials::client_config(Some(&ca)).unwrap();
    let token = credentials::read_token(&f.root.join("token")).unwrap();
    let mut ws = wire::connect_authenticated(
        &format!("wss://127.0.0.1:{}/mcc/v1", f.port),
        config,
        &token,
    )
    .expect("WSS authenticated");
    ws.get_mut()
        .inner_mut()
        .sock
        .set_deadline(Instant::now() + LIMIT);
    let hello = ws_json(&mut ws);
    assert_eq!(hello["scope"], "desktop");
    assert_eq!(hello["remoteProtocol"], 1);
    let (sid, boot) = session.map_or((Value::Null, Value::Null), |(sid, boot)| {
        (serde_json::json!(sid), serde_json::json!(boot))
    });
    ws.send(Message::Text(serde_json::json!({"type":"session","remoteProtocol":1,"scope":"desktop","session":sid,"bootId":boot}).to_string().into())).unwrap();
    let accepted = ws_json(&mut ws);
    assert_eq!(accepted["type"], "session");
    let sid = accepted["session"].as_str().unwrap().to_owned();
    let boot = accepted["bootId"].as_str().unwrap().to_owned();
    assert_eq!(hello["bootId"], boot);
    ws.send(Message::Text(serde_json::json!({"remoteProtocol":1,"id":id,"session":sid,"sequence":sequence,"scope":"desktop","request":request}).to_string().into())).unwrap();
    let result = ws_json(&mut ws);
    assert_eq!(result["type"], "result");
    assert_eq!(result["id"], id);
    assert_eq!(result["sequence"], sequence);
    let mut image = Vec::new();
    if let Some(count) = result["image"]["bytes"].as_u64() {
        assert!(count < 1024 * 1024);
        while image.len() < count as usize {
            match ws.read().expect("bounded image chunk") {
                Message::Binary(chunk) => image.extend_from_slice(&chunk),
                _ => panic!("expected image chunk"),
            }
            assert!(image.len() <= count as usize);
        }
    }
    ws.send(Message::Text(
        serde_json::json!({"type":"ack","id":id,"sequence":sequence})
            .to_string()
            .into(),
    ))
    .unwrap();
    let ack = ws_json(&mut ws);
    assert_eq!(ack["type"], "acked");
    assert_eq!(ack["id"], id);
    assert_eq!(ack["sequence"], sequence);
    ws.close(None).expect("send normal WSS close");
    match ws.read() {
        Ok(Message::Close(_)) | Err(tungstenite::Error::ConnectionClosed) => {}
        other => panic!("WSS close handshake failed: {other:?}"),
    }
    f.capture_owned();
    (sid, boot, result, image)
}

#[test]
fn replayed_observe_returns_identical_image_without_extra_native_capture() {
    let mut f = ProcessGuard::new();
    f.init();
    f.start();
    let (sid, boot, connected, _) = replay_rpc(
        &f,
        None,
        "connect-1",
        1,
        serde_json::json!({"action":"connect","windowId":42}),
    );
    let id = connected["response"]["connectionId"].as_str().unwrap();
    let request = serde_json::json!({"action":"observe","connectionId":id});
    let (_, _, first, first_image) =
        replay_rpc(&f, Some((&sid, &boot)), "observe-1", 2, request.clone());
    let (_, _, replay, replay_image) = replay_rpc(&f, Some((&sid, &boot)), "observe-1", 2, request);
    assert_eq!(first["response"]["ok"], true);
    assert_eq!(first["response"], replay["response"]);
    assert_eq!(first["image"], replay["image"]);
    assert!(!first_image.is_empty());
    assert_eq!(first_image, replay_image);
    assert_eq!(native_action_count(&f, "observe"), 1);
    assert_eq!(native_action_count(&f, "transport-pause"), 0);
    let (_, _, disconnected, _) = replay_rpc(
        &f,
        Some((&sid, &boot)),
        "disconnect-1",
        3,
        serde_json::json!({"action":"disconnect","connectionId":id}),
    );
    assert_eq!(disconnected["response"]["ok"], true);
}

#[test]
fn replayed_observe_with_deleted_private_frame_returns_acked_error_without_pause() {
    let mut f = ProcessGuard::new();
    f.init();
    f.start();
    let (sid, boot, connected, _) = replay_rpc(
        &f,
        None,
        "connect-1",
        1,
        serde_json::json!({"action":"connect","windowId":42}),
    );
    let id = connected["response"]["connectionId"].as_str().unwrap();
    let request = serde_json::json!({"action":"observe","connectionId":id});
    let (_, _, original, image) =
        replay_rpc(&f, Some((&sid, &boot)), "observe-1", 2, request.clone());
    assert!(!image.is_empty());
    let frame = original["response"]["frameId"].as_str().unwrap();
    assert!(frame
        .bytes()
        .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_'));
    fs::remove_file(
        f.root
            .join("host-runtime/frames")
            .join(format!("{frame}.jpg")),
    )
    .unwrap();
    let (_, _, replay, bytes) = replay_rpc(&f, Some((&sid, &boot)), "observe-1", 2, request);
    assert!(
        matches!(
            replay["response"]["error"]["code"].as_str(),
            Some("FRAME_NOT_FOUND" | "FRAME_UNKNOWN")
        ),
        "stale replay must return an ACK-able frame error: {}",
        replay["response"]
    );
    assert!(bytes.is_empty());
    assert!(replay["image"].is_null());
    assert_eq!(native_action_count(&f, "observe"), 1);
    assert_eq!(native_action_count(&f, "transport-pause"), 0);
    let (_, _, status, _) = replay_rpc(
        &f,
        Some((&sid, &boot)),
        "status-1",
        3,
        serde_json::json!({"action":"status"}),
    );
    assert_eq!(status["response"]["ok"], true);
    let (_, _, disconnected, _) = replay_rpc(
        &f,
        Some((&sid, &boot)),
        "disconnect-1",
        4,
        serde_json::json!({"action":"disconnect","connectionId":id}),
    );
    assert_eq!(disconnected["response"]["ok"], true);
}

#[test]
fn replayed_evicted_click_target_does_not_revive_or_displace_new_frames() {
    let mut f = ProcessGuard::new();
    f.init();
    let cloud = FakeCloud::new(false);
    enable_fake_cloud(&f, &cloud);
    f.start();
    let (sid, boot, connected, _) = replay_rpc(
        &f,
        None,
        "connect-1",
        1,
        serde_json::json!({"action":"connect","windowId":42}),
    );
    let id = connected["response"]["connectionId"].as_str().unwrap();
    let target = serde_json::json!({"action":"click-target","connectionId":id,"target":"Save"});
    let (_, _, first, bytes) = replay_rpc(&f, Some((&sid, &boot)), "target-1", 2, target.clone());
    assert_eq!(first["response"]["ok"], true);
    assert!(bytes.is_empty());
    assert!(first["image"].is_null());
    let old = first["response"]["frameId"].as_str().unwrap().to_owned();
    verify_cloud_request(&cloud.request.recv_timeout(LIMIT).unwrap());
    assert!(cloud.closed.recv_timeout(LIMIT).unwrap());
    let mut newest = String::new();
    let mut first_retained = String::new();
    // The Host allows 10 requests/s per session; pace the 32 captures so this
    // tests frame eviction rather than accidentally tripping the rate limiter.
    let mut next_observe = Instant::now();
    for i in 0..32_u64 {
        let now = Instant::now();
        if now < next_observe {
            std::thread::sleep(next_observe - now);
        }
        next_observe = Instant::now() + Duration::from_millis(110);
        let (_, _, observed, image) = replay_rpc(
            &f,
            Some((&sid, &boot)),
            &format!("observe-{i}"),
            i + 3,
            serde_json::json!({"action":"observe","connectionId":id}),
        );
        assert_eq!(observed["response"]["ok"], true);
        assert!(!image.is_empty());
        newest = observed["response"]["frameId"].as_str().unwrap().to_owned();
        if i == 0 {
            first_retained = newest.clone();
        }
    }
    assert_ne!(old, newest);
    assert!(!f
        .root
        .join("host-runtime/frames")
        .join(format!("{old}.jpg"))
        .exists());
    let (_, _, replay, image) = replay_rpc(&f, Some((&sid, &boot)), "target-1", 2, target);
    assert!(
        matches!(
            replay["response"]["error"]["code"].as_str(),
            Some("FRAME_NOT_FOUND" | "FRAME_UNKNOWN")
        ),
        "evicted semantic frame replay must return an acknowledged frame error: {}",
        replay["response"]
    );
    assert!(image.is_empty());
    assert!(replay["image"].is_null());
    assert_eq!(native_action_count(&f, "observe"), 33);
    assert_eq!(native_action_count(&f, "click"), 1);
    assert_eq!(native_action_count(&f, "transport-pause"), 0);
    let (_, _, oldest_press, _) = replay_rpc(
        &f,
        Some((&sid, &boot)),
        "press-first-retained",
        35,
        serde_json::json!({"action":"press","connectionId":id,"frameId":first_retained,"key":"Enter"}),
    );
    assert_eq!(
        oldest_press["response"]["ok"], true,
        "replay must not displace the oldest retained frame"
    );
    let (_, _, press, _) = replay_rpc(
        &f,
        Some((&sid, &boot)),
        "press-new",
        36,
        serde_json::json!({"action":"press","connectionId":id,"frameId":newest,"key":"Enter"}),
    );
    assert_eq!(
        press["response"]["ok"], true,
        "newest frame must remain usable"
    );
    assert_eq!(native_action_count(&f, "press"), 2);
    assert_eq!(native_action_count(&f, "observe"), 33);
    let (_, _, disconnected, _) = replay_rpc(
        &f,
        Some((&sid, &boot)),
        "disconnect",
        37,
        serde_json::json!({"action":"disconnect","connectionId":id}),
    );
    assert_eq!(disconnected["response"]["ok"], true);
}
