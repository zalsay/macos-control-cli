#![cfg(target_os = "macos")]
use copis_chrome::{
    args::{self, Command},
    config::Store,
    execution::{execute_local, execute_request},
    protocol::{Scope, PROTOCOL_VERSION},
};
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixListener},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

struct Fixture {
    root: PathBuf,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
    requests: Arc<Mutex<Vec<Value>>>,
    version: Arc<Mutex<String>>,
    dynamic: Arc<AtomicBool>,
    env: Vec<(&'static str, Option<std::ffi::OsString>)>,
}
impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/tmp/mcc-exec-{}",
            &copis_chrome::protocol::random_id().unwrap()[..12]
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let runtime = root.join("runtime");
        std::fs::create_dir(&runtime).unwrap();
        std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = runtime.join("daemon.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
        listener.set_nonblocking(true).unwrap();
        let image = root.join("frame.jpg");
        std::fs::write(&image, b"temporary fake frame").unwrap();
        let env: Vec<_> = [
            "MCC_CONFIG_DIR",
            "COPIS_DESKTOP_RUNTIME_DIR",
            "COPIS_CHROME_RUNTIME_DIR",
            "COPIS_DESKTOP_HELPER",
            "COPIS_CHROME_HELPER",
        ]
        .into_iter()
        .map(|key| (key, std::env::var_os(key)))
        .collect();
        std::env::set_var("MCC_CONFIG_DIR", root.join("config"));
        std::env::set_var("COPIS_DESKTOP_RUNTIME_DIR", &runtime);
        std::env::set_var("COPIS_CHROME_RUNTIME_DIR", &runtime);
        std::env::set_var("COPIS_DESKTOP_HELPER", "/no-real-helper");
        std::env::set_var("COPIS_CHROME_HELPER", "/no-real-helper");
        let requests = Arc::new(Mutex::new(Vec::new()));
        let requests_server = Arc::clone(&requests);
        let version = Arc::new(Mutex::new(env!("CARGO_PKG_VERSION").to_owned()));
        let version_server = Arc::clone(&version);
        let dynamic = Arc::new(AtomicBool::new(true));
        let dynamic_server = Arc::clone(&dynamic);
        let stop = Arc::new(AtomicBool::new(false));
        let stop_server = Arc::clone(&stop);
        let worker = std::thread::spawn(move || {
            while !stop_server.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        if stream
                            .set_nonblocking(false)
                            .and_then(|_| stream.set_read_timeout(Some(Duration::from_millis(200))))
                            .is_err()
                        {
                            continue;
                        }
                        let mut line = String::new();
                        if BufReader::new(&stream).read_line(&mut line).is_err() || line.is_empty()
                        {
                            continue;
                        }
                        let envelope: Value = serde_json::from_str(&line).unwrap();
                        requests_server.lock().unwrap().push(envelope.clone());
                        let action = envelope["request"]["action"].as_str().unwrap();
                        let mut response = if action == "status" {
                            json!({"running":true,"connected":true,"version":*version_server.lock().unwrap(),"jev":{"protocol":copis_chrome::jev::DECISION_PROTOCOL,"dynamicEndpoint":dynamic_server.load(Ordering::Acquire)}})
                        } else if action == "observe" {
                            json!({"imagePath":image})
                        } else {
                            json!({"action":action})
                        };
                        response["ok"] = json!(true);
                        response["protocolVersion"] = json!(PROTOCOL_VERSION);
                        if envelope["scope"] == "desktop" {
                            response["scope"] = json!("desktop");
                        }
                        writeln!(stream, "{response}").unwrap();
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(2))
                    }
                    Err(e) => panic!("fake daemon accept: {e}"),
                }
            }
        });
        Self {
            root,
            stop,
            worker: Some(worker),
            requests,
            version,
            dynamic,
            env,
        }
    }
    fn store(&self) -> Store {
        Store::new(self.root.join("config"))
    }
    fn actions(&self) -> Vec<Value> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|v| v["request"]["action"] != "status")
            .cloned()
            .collect()
    }
    fn clear(&self) {
        self.requests.lock().unwrap().clear();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        for (key, value) in self.env.drain(..) {
            match value {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
#[test]
fn shared_entry_matches_cli_preprocessing_gates_scope_and_export() {
    let f = Fixture::new();
    let store = f.store();
    store
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
            b"fake-secret".as_slice(),
        )
        .unwrap();
    store
        .execute(
            &["chrome", "--profile", "Saved"].map(str::to_owned),
            std::io::empty(),
        )
        .unwrap();
    store
        .execute(
            &["window", "--max-width", "1400"].map(str::to_owned),
            std::io::empty(),
        )
        .unwrap();
    let config = execute_local(Command::Config(vec![]), Scope::Desktop).unwrap();
    assert_eq!(config["chrome"]["profile"], "Saved");
    assert!(f.requests.lock().unwrap().is_empty());

    let daemon_status = execute_local(Command::Daemon("status".into()), Scope::Desktop).unwrap();
    let request_status = execute_request(json!({"action":"status"}), None, Scope::Desktop).unwrap();
    assert_eq!(daemon_status, request_status);
    f.clear();
    let words = [
        "click-target",
        "--connection",
        "fixture",
        "--target",
        "Save",
    ];
    let command =
        || args::parse_for_scope(words.into_iter().map(str::to_owned), Scope::Desktop).unwrap();
    let Command::Request { request, output } = command() else {
        panic!("request expected")
    };
    let direct = execute_request(request, output, Scope::Desktop).unwrap();
    let local = execute_local(command(), Scope::Desktop).unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_mcc"))
        .args(words)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    let cli: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(direct, local);
    assert_eq!(direct["action"], cli["action"]);
    let actions = f.actions();
    assert_eq!(actions.len(), 3);
    assert!(actions.windows(2).all(|w| w[0] == w[1]));
    assert_eq!(actions[0]["scope"], "desktop");
    assert_eq!(actions[0]["request"]["jevKey"], "fake-secret");
    assert_eq!(
        actions[0]["request"]["jevProtocol"],
        copis_chrome::jev::DECISION_PROTOCOL
    );

    f.clear();
    execute_request(json!({"action":"chrome-start"}), None, Scope::Chrome).unwrap();
    let actions = f.actions();
    assert_eq!(actions.len(), 1);
    assert!(actions[0].get("scope").is_none());
    assert_eq!(actions[0]["request"]["profile"], "Saved");
    assert_eq!(actions[0]["request"]["maxWidthPx"], 1400);
    let image = f.root.join("export.jpg");
    let observed = execute_request(
        json!({"action":"observe"}),
        Some(image.clone()),
        Scope::Desktop,
    )
    .unwrap();
    assert_eq!(observed["imagePath"], image.to_str().unwrap());
    assert_eq!(std::fs::read(&image).unwrap(), b"temporary fake frame");
    assert_eq!(
        execute_request(json!({"action":"observe"}), Some(image), Scope::Desktop)
            .unwrap_err()
            .code,
        "OUTPUT_EXISTS"
    );

    f.clear();
    *f.version.lock().unwrap() = "old-version".into();
    assert_eq!(
        execute_request(
            json!({"action":"click-target","connectionId":"fixture","target":"Save"}),
            None,
            Scope::Desktop
        )
        .unwrap_err()
        .code,
        "DAEMON_UPGRADE_REQUIRED"
    );
    assert!(f.actions().is_empty());
    *f.version.lock().unwrap() = env!("CARGO_PKG_VERSION").into();
    f.clear();
    f.dynamic.store(false, Ordering::Release);
    assert_eq!(
        execute_request(
            json!({"action":"click-target","connectionId":"fixture","target":"Save"}),
            None,
            Scope::Desktop
        )
        .unwrap_err()
        .code,
        "DAEMON_UPGRADE_REQUIRED"
    );
    assert!(f.actions().is_empty());
    assert!(f
        .requests
        .lock()
        .unwrap()
        .iter()
        .all(|envelope| envelope["request"].get("jevKey").is_none()));
    f.dynamic.store(true, Ordering::Release);
    store
        .execute(&["disable", "jev"].map(str::to_owned), std::io::empty())
        .unwrap();
    f.clear();
    assert_eq!(
        execute_request(
            json!({"action":"click-target","connectionId":"fixture","target":"Save"}),
            None,
            Scope::Desktop
        )
        .unwrap_err()
        .code,
        "MODEL_DISABLED"
    );
    assert!(f.requests.lock().unwrap().is_empty());
}
