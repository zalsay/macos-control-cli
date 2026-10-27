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
