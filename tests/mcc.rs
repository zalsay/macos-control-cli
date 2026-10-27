#![cfg(target_os = "macos")]
use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Output};

struct Environment(PathBuf);
impl Environment {
    fn new() -> Self {
        let value = Self(PathBuf::from(format!(
            "/tmp/mcc-test-{}",
            copis_chrome::protocol::random_id().unwrap()
        )));
        std::fs::create_dir(value.cwd()).unwrap();
        value
    }
    fn cwd(&self) -> PathBuf {
        self.0.with_extension("cwd")
    }
    fn configure(&self) {
        copis_chrome::config::Store::new(self.cwd().join("config"))
            .execute(
                &[
                    "set",
                    "jev",
                    "--url",
                    "https://router.example/decisions",
                    "--model",
                    "typesafe/jev-1.13",
                    "--api-key-stdin",
                ]
                .map(str::to_owned),
                "private-config-key".as_bytes(),
            )
            .unwrap();
    }
    fn raw(&self, executable: &str, args: &[&str]) -> Output {
        Command::new(executable)
            .current_dir(self.cwd())
            .env_remove("JEV_API_KEY")
            .env_remove("OPENROUTER_API_KEY")
            .env_remove("TYPESAFE_API_KEY")
            .args(args)
            .env("MCC_CONFIG_DIR", self.cwd().join("config"))
            .env("COPIS_DESKTOP_RUNTIME_DIR", &self.0)
            .env(
                "COPIS_DESKTOP_HELPER",
                format!(
                    "{}/tests/fixtures/fake-helper.sh",
                    env!("CARGO_MANIFEST_DIR")
                ),
            )
            .output()
            .unwrap()
    }
    fn call(&self, executable: &str, args: &[&str]) -> Value {
        let output = self.raw(executable, args);
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert!(output.status.success(), "{value}");
        assert_eq!(value["scope"], "desktop");
        value
    }
}
impl Drop for Environment {
    fn drop(&mut self) {
        if self.0.exists() {
            let _ = self.raw(env!("CARGO_BIN_EXE_desktop-control"), &["daemon", "stop"]);
            for _ in 0..60 {
                if !self.0.join("daemon.sock").exists() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            if !self.0.join("daemon.sock").exists() {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _ = std::fs::remove_dir_all(self.cwd());
    }
}
fn mcc() -> &'static str {
    env!("CARGO_BIN_EXE_mcc")
}
#[test]
fn given_mcc_when_help_or_version_requested_then_no_runtime_or_desktop_side_effects() {
    let env = Environment::new();
    let output = env.raw(mcc(), &["--help"]);
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.starts_with("mcc —"));
    for command in [
        "mcc permissions",
        "mcc apps",
        "mcc windows",
        "mcc observe",
        "mcc click",
        "mcc daemon stop",
    ] {
        assert!(help.contains(command), "帮助缺少 {command}");
    }
    assert!(help.contains("frameId") && help.contains("原像素"));
    assert!(help.contains("~/.copis/desktop-control-cli"));
    assert!(!help.contains("~/.copis/mcc-cli"));
    assert!(!env.0.exists());
    let version = env.call(mcc(), &["--version"]);
    assert_eq!(version["version"], env!("CARGO_PKG_VERSION"));
    assert!(!env.0.exists());
}
#[test]
fn given_mcc_and_legacy_desktop_entry_when_sharing_runtime_then_mode_and_connection_are_compatible()
{
    let env = Environment::new();
    let connection = env.call(mcc(), &["connect", "--window", "42"]);
    let id = connection["connectionId"].as_str().unwrap();
    assert_eq!(
        env.call(env!("CARGO_BIN_EXE_desktop-control"), &["status"])["connected"],
        true
    );
    env.call(
        env!("CARGO_BIN_EXE_desktop-control"),
        &["disconnect", "--connection", id],
    );
    assert_eq!(env.call(mcc(), &["status"])["connected"], false);
    env.call(mcc(), &["daemon", "stop"]);
}

#[test]
fn given_click_target_without_key_when_invoked_then_reject_before_starting_daemon() {
    let env = Environment::new();
    let output = Command::new(mcc())
        .args([
            "click-target",
            "--connection",
            "fixture",
            "--target",
            "保存",
        ])
        .env_remove("JEV_API_KEY")
        .env_remove("TYPESAFE_API_KEY")
        .env_remove("OPENROUTER_API_KEY")
        .current_dir(env.cwd())
        .env("MCC_CONFIG_DIR", env.cwd().join("config"))
        .env("COPIS_DESKTOP_RUNTIME_DIR", &env.0)
        .output()
        .unwrap();
    assert!(!output.status.success());
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["error"]["code"], "MODEL_NOT_CONFIGURED");
    assert!(!env.0.exists());
}

#[test]
fn given_invalid_explicit_key_when_invoked_then_no_runtime_or_secret_in_error() {
    let env = Environment::new();
    let secret = "private-key\ninvalid";
    let output = env.raw(
        mcc(),
        &[
            "click-target",
            "--connection",
            "fixture",
            "--target",
            "保存",
            "--jev-key",
            secret,
        ],
    );
    assert!(!output.status.success());
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["error"]["code"], "INVALID_ARGUMENT");
    assert!(!String::from_utf8_lossy(&output.stdout).contains("private-key"));
    assert!(!env.0.exists());
}

#[test]
fn given_per_call_or_config_key_when_using_old_helper_then_key_is_not_logged_or_inherited() {
    for source in ["explicit", "configured"] {
        let env = Environment::new();
        env.configure();
        let mut connect = Command::new(mcc());
        let output = connect
            .current_dir(env.cwd())
            .args(["connect", "--window", "42"])
            .env("MCC_CONFIG_DIR", env.cwd().join("config"))
            .env("COPIS_DESKTOP_RUNTIME_DIR", &env.0)
            .env(
                "COPIS_DESKTOP_HELPER",
                format!(
                    "{}/tests/fixtures/fake-helper.sh",
                    env!("CARGO_MANIFEST_DIR")
                ),
            )
            .env("JEV_API_KEY", "private-env-key")
            .env("TYPESAFE_API_KEY", "private-typesafe-key")
            .env("OPENROUTER_API_KEY", "private-openrouter-key")
            .output()
            .unwrap();
        assert!(output.status.success());
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        let id = value["connectionId"].as_str().unwrap();
        let mut command = Command::new(mcc());
        command
            .current_dir(env.cwd())
            .env_remove("OPENROUTER_API_KEY")
            .args(["click-target", "--connection", id, "--target", "保存"])
            .env("MCC_CONFIG_DIR", env.cwd().join("config"))
            .env("COPIS_DESKTOP_RUNTIME_DIR", &env.0)
            .env(
                "JEV_API_KEY",
                if source == "explicit" {
                    "invalid env key"
                } else {
                    "private-env-key"
                },
            );
        if source == "explicit" {
            command.args(["--jev-key", "private-flag-key"]);
        }
        if source == "openrouter-env" {
            command
                .env_remove("JEV_API_KEY")
                .env("OPENROUTER_API_KEY", "private-openrouter-key");
        }
        let output = command.output().unwrap();
        let result: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert!(!output.status.success());
        assert_eq!(result["error"]["code"], "HELPER_UPGRADE_REQUIRED");
        assert!(!env.0.join("key-inherited").exists());
        let log = std::fs::read_to_string(env.0.join("daemon.log")).unwrap();
        for secret in [
            "private-env-key",
            "private-typesafe-key",
            "private-flag-key",
            "private-openrouter-key",
        ] {
            assert!(!log.contains(secret));
            assert!(!String::from_utf8_lossy(&output.stdout).contains(secret));
            assert!(!String::from_utf8_lossy(&output.stderr).contains(secret));
        }
    }
}

#[test]
fn given_only_env_and_cwd_dotenv_then_require_models_configuration_without_starting_daemon() {
    let env = Environment::new();
    let secret = "private-env-not-an-implicit-source";
    let dotenv = format!("JEV_API_KEY='{secret}'\nUNRELATED=$(touch shell-executed)\n");
    std::fs::write(env.cwd().join(".env"), &dotenv).unwrap();
    let output = Command::new(mcc())
        .args([
            "click-target",
            "--connection",
            "missing",
            "--target",
            "保存",
        ])
        .current_dir(env.cwd())
        .env("MCC_CONFIG_DIR", env.cwd().join("config"))
        .env("JEV_API_KEY", secret)
        .env("COPIS_DESKTOP_RUNTIME_DIR", &env.0)
        .output()
        .unwrap();
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["error"]["code"], "MODEL_NOT_CONFIGURED");
    assert!(!env.0.exists());
    assert!(!env.cwd().join("shell-executed").exists());
    assert_eq!(
        std::fs::read_to_string(env.cwd().join(".env")).unwrap(),
        dotenv
    );
    assert!(!String::from_utf8_lossy(&output.stdout).contains(secret));
}

#[test]
fn given_old_or_wrong_provider_daemon_then_reject_before_sending_openrouter_key() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    };
    use std::time::{Duration, Instant};
    struct MockDaemon {
        stop: Arc<AtomicBool>,
        worker: Option<std::thread::JoinHandle<()>>,
        path: PathBuf,
    }
    impl Drop for MockDaemon {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Release);
            if let Some(worker) = self.worker.take() {
                let _ = worker.join();
            }
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
    for metadata in [
        serde_json::json!({}),
        serde_json::json!({"provider":"typesafe","model":"jev-1.14.0"}),
        serde_json::json!({"provider":"openrouter","model":"typesafe/jev-1.14"}),
        serde_json::json!({"protocol":"decisions-v1","dynamicEndpoint":true,"daemonVersion":"0.2.9"}),
    ] {
        let env = Environment::new();
        std::fs::create_dir(&env.0).unwrap();
        std::fs::set_permissions(&env.0, std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = env.0.join("daemon.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
        listener.set_nonblocking(true).unwrap();
        let seen = Arc::new(Mutex::new(Vec::<String>::new()));
        let seen_server = seen.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_server = stop.clone();
        let is_old_version = metadata.get("daemonVersion").is_some();
        let worker = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !stop_server.load(Ordering::Acquire) && Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        if stream
                            .set_nonblocking(false)
                            .and_then(|_| stream.set_read_timeout(Some(Duration::from_millis(100))))
                            .is_err()
                        {
                            continue;
                        }
                        let mut line = String::new();
                        if BufReader::new(&stream).read_line(&mut line).is_ok() && !line.is_empty()
                        {
                            seen_server.lock().unwrap().push(line);
                            let reply = serde_json::json!({"ok":true,"protocolVersion":1,"scope":"desktop","running":true,"connected":true,
                                "version":metadata.get("daemonVersion").cloned().unwrap_or_else(||serde_json::json!(env!("CARGO_PKG_VERSION"))),"jev":metadata});
                            writeln!(stream, "{reply}").unwrap();
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5))
                    }
                    Err(error) => panic!("mock socket: {error}"),
                }
            }
        });
        let _server = MockDaemon {
            stop,
            worker: Some(worker),
            path: env.0.clone(),
        };
        env.configure();
        let secret = "private-openrouter-key-no-old-daemon";
        let output = env.raw(
            mcc(),
            &[
                "click-target",
                "--connection",
                "fixture",
                "--target",
                "保存",
                "--jev-key",
                secret,
            ],
        );
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value["error"]["code"], "DAEMON_UPGRADE_REQUIRED");
        assert!(!output.status.success());
        if is_old_version {
            let output = env.raw(mcc(), &["chrome", "start"]);
            let value: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(value["error"]["code"], "DAEMON_UPGRADE_REQUIRED");
        }
        let requests = seen.lock().unwrap();
        assert!(requests
            .iter()
            .all(|request| !request.contains(secret) && !request.contains("click-target")));
    }
}
