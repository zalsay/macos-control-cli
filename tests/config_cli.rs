use std::io::Write;
use std::process::{Command, Stdio};
#[test]
fn config_stdin_show_default_and_window_are_local_only_and_mask_secrets() {
    let root = std::env::temp_dir().join(format!(
        "mcc-config-cli-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    let cli = env!("CARGO_BIN_EXE_mcc");
    let run = |args: &[&str], input: &str| {
        let mut child = Command::new(cli)
            .args(args)
            .env("MCC_CONFIG_DIR", root.join("config"))
            .env("COPIS_DESKTOP_RUNTIME_DIR", root.join("runtime"))
            .env("COPIS_DESKTOP_HELPER", "/no-helper-must-start")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stdout)
        );
        assert!(!String::from_utf8_lossy(&out.stdout).contains("stdin-private-secret"));
        assert!(!String::from_utf8_lossy(&out.stderr).contains("stdin-private-secret"));
        serde_json::from_slice::<serde_json::Value>(&out.stdout).unwrap()
    };
    assert_eq!(run(&["--config"], "")["configured"], false);
    run(
        &[
            "--config",
            "set",
            "fast",
            "--url",
            "http://127.0.0.1:8080/decisions",
            "--model",
            "custom/decision",
            "--api-key-stdin",
        ],
        "stdin-private-secret\n",
    );
    assert_eq!(
        run(&["--config", "show", "fast"], "")["profile"]["api_key"],
        "[REDACTED]"
    );
    run(&["--config", "default", "fast"], "");
    run(&["--config", "window", "--max-width", "1500"], "");
    assert!(!root.join("runtime").exists());
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn parses_start_without_exposing_config_key_in_debug() {
    use copis_chrome::args::{parse, Command};
    let parsed = parse(
        ["chrome", "start", "--url", "https://example.com/"]
            .into_iter()
            .map(str::to_owned),
    )
    .unwrap();
    let Command::Request { request, .. } = parsed else {
        panic!("request expected")
    };
    assert_eq!(request["action"], "chrome-start");
    assert!(parse(["chrome", "stop"].into_iter().map(str::to_owned)).is_err());
    let config = parse(
        ["--config", "set", "fast", "--api-key", "secret"]
            .into_iter()
            .map(str::to_owned),
    )
    .unwrap();
    assert!(!format!("{config:?}").contains("secret"));
}

#[test]
fn chrome_profile_config_commands_are_local_private_and_visible_without_secrets() {
    use std::os::unix::fs::PermissionsExt;

    let root = std::env::temp_dir().join(format!(
        "mcc-chrome-profile-cli-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    let config_dir = root.join("config");
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_mcc"))
            .args(args)
            .env("MCC_CONFIG_DIR", &config_dir)
            .env("COPIS_DESKTOP_RUNTIME_DIR", root.join("runtime"))
            .env("COPIS_DESKTOP_HELPER", "/no-helper-must-start")
            .output()
            .unwrap()
    };

    let set = run(&["--config", "chrome", "--profile", "mcc"]);
    assert!(
        set.status.success(),
        "{}",
        String::from_utf8_lossy(&set.stdout)
    );
    let summary = run(&["--config"]);
    assert!(summary.status.success());
    let summary: serde_json::Value = serde_json::from_slice(&summary.stdout).unwrap();
    assert_eq!(summary["chrome"]["profile"], "mcc");

    let window = run(&["--config", "window", "--max-width", "1300"]);
    assert!(window.status.success());
    let summary = run(&["--config"]);
    let summary: serde_json::Value = serde_json::from_slice(&summary.stdout).unwrap();
    assert_eq!(summary["chrome"]["profile"], "mcc");
    assert_eq!(summary["chrome"]["window"]["max_width_px"], 1300);

    let clear = run(&["--config", "chrome", "--clear-profile"]);
    assert!(clear.status.success());
    let summary = run(&["--config"]);
    let summary: serde_json::Value = serde_json::from_slice(&summary.stdout).unwrap();
    assert!(summary["chrome"].get("profile").is_none());
    assert!(!root.join("runtime").exists());
    assert_eq!(
        std::fs::metadata(&config_dir).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(config_dir.join("config.toml"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn all_cli_entries_toggle_models_locally_and_mask_saved_secrets() {
    let root = std::env::temp_dir().join(format!(
        "mcc-toggle-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    let store = copis_chrome::config::Store::new(root.join("config"));
    store
        .execute(
            &[
                "set",
                "jev",
                "--url",
                "https://router.example/api",
                "--model",
                "vendor/model",
                "--api-key-stdin",
            ]
            .map(str::to_owned),
            "toggle-cli-secret".as_bytes(),
        )
        .unwrap();
    for cli in [
        env!("CARGO_BIN_EXE_mcc"),
        env!("CARGO_BIN_EXE_desktop-control"),
        env!("CARGO_BIN_EXE_copis-chrome"),
    ] {
        for (command, enabled) in [("disable", false), ("enable", true)] {
            let out = Command::new(cli)
                .args(["--config", command, "jev", "--json"])
                .env("MCC_CONFIG_DIR", root.join("config"))
                .env("COPIS_DESKTOP_RUNTIME_DIR", root.join("desktop"))
                .env("COPIS_CHROME_RUNTIME_DIR", root.join("chrome"))
                .env("COPIS_DESKTOP_HELPER", "/must-not-start")
                .env("COPIS_CHROME_HELPER", "/must-not-start")
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stdout)
            );
            assert!(!String::from_utf8_lossy(&out.stdout).contains("toggle-cli-secret"));
            assert!(!String::from_utf8_lossy(&out.stderr).contains("toggle-cli-secret"));
            let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(reply["profile"]["enabled"], enabled);
            assert_eq!(reply["profile"]["api_key"], "[REDACTED]");
            assert!(!root.join("desktop").exists());
            assert!(!root.join("chrome").exists());
        }
    }
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
#[cfg(target_os = "macos")]
fn disabled_model_blocks_all_cli_entries_before_daemon_helper_or_network_even_with_key_override() {
    use std::net::TcpListener;
    // Keep the Unix socket path within the existing macOS runtime limit.
    let root = std::path::PathBuf::from("/tmp").join(format!(
        "mcc-disabled-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}/decisions", listener.local_addr().unwrap());
    let store = copis_chrome::config::Store::new(root.join("config"));
    store
        .execute(
            &[
                "set",
                "jev",
                "--url",
                &endpoint,
                "--model",
                "vendor/model",
                "--api-key-stdin",
            ]
            .map(str::to_owned),
            "disabled-cli-secret".as_bytes(),
        )
        .unwrap();
    let path = root.join("config/models.toml");
    let mut config: toml::Value = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    config["models"]["jev"]
        .as_table_mut()
        .unwrap()
        .insert("enabled".into(), toml::Value::Boolean(false));
    std::fs::write(&path, toml::to_string(&config).unwrap()).unwrap();
    let before = std::fs::read(&path).unwrap();
    for cli in [
        env!("CARGO_BIN_EXE_mcc"),
        env!("CARGO_BIN_EXE_desktop-control"),
        env!("CARGO_BIN_EXE_copis-chrome"),
    ] {
        for override_key in [false, true] {
            let mut args = vec![
                "click-target",
                "--connection",
                "fixture",
                "--target",
                "保存",
            ];
            if override_key {
                args.extend(["--jev-key", "override-cli-secret"]);
            }
            let out = Command::new(cli)
                .args(args)
                .env("MCC_CONFIG_DIR", root.join("config"))
                .env("COPIS_DESKTOP_RUNTIME_DIR", root.join("desktop"))
                .env("COPIS_CHROME_RUNTIME_DIR", root.join("chrome"))
                .env("COPIS_DESKTOP_HELPER", "/must-not-start")
                .env("COPIS_CHROME_HELPER", "/must-not-start")
                .output()
                .unwrap();
            assert!(!out.status.success());
            let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(reply["error"]["code"], "MODEL_DISABLED");
            for secret in ["disabled-cli-secret", "override-cli-secret"] {
                assert!(!String::from_utf8_lossy(&out.stdout).contains(secret));
                assert!(!String::from_utf8_lossy(&out.stderr).contains(secret));
            }
            assert!(!root.join("desktop").exists());
            assert!(!root.join("chrome").exists());
        }
    }
    assert!(matches!(listener.accept(), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock));
    assert_eq!(std::fs::read(&path).unwrap(), before);
    std::fs::remove_dir_all(root).unwrap();
}
