use copis_chrome::{
    args::{self, Command},
    protocol::Scope,
    remote::options::HostCommand,
};

fn parse(words: &[&str]) -> copis_chrome::protocol::Result<Command> {
    args::parse_for_scope(words.iter().map(|s| s.to_string()), Scope::Chrome)
}

#[test]
fn remote_eb_is_a_per_input_flag_without_changing_coordinates() {
    for tail in [
        vec![
            "click",
            "--connection",
            "c",
            "--frame",
            "f",
            "--x",
            "123",
            "--y",
            "456",
            "--eb",
        ],
        vec![
            "type",
            "--eb",
            "--connection",
            "c",
            "--frame",
            "f",
            "--text",
            "literal --eb",
        ],
        vec![
            "press",
            "--connection",
            "c",
            "--frame",
            "f",
            "--key",
            "Enter",
            "--eb",
        ],
        vec![
            "scroll",
            "--connection",
            "c",
            "--frame",
            "f",
            "--x",
            "1",
            "--y",
            "2",
            "--delta-y",
            "-3",
            "--eb",
        ],
        vec![
            "click-target",
            "--connection",
            "c",
            "--target",
            "Save",
            "--eb",
        ],
    ] {
        let mut words = vec![
            "--remote",
            "wss://example.test",
            "--token-file",
            "/tmp/token",
        ];
        words.extend(tail);
        let Command::Remote { command, .. } = parse(&words).unwrap() else {
            panic!()
        };
        let Command::Request { request, .. } = *command else {
            panic!()
        };
        assert_eq!(request["eb"], true);
        if request["action"] == "click" {
            assert_eq!(request["x"], 123);
            assert_eq!(request["y"], 456);
        }
    }
    assert!(parse(&["status", "--eb"]).is_err());
    assert!(parse(&["host", "start", "--eb"]).is_err());
    assert!(parse(&[
        "type",
        "--connection",
        "c",
        "--frame",
        "f",
        "--text",
        "hi",
        "--eb",
        "--eb"
    ])
    .is_err());
    let Command::Request { request, .. } = parse(&[
        "type",
        "--connection",
        "c",
        "--frame",
        "f",
        "--text",
        "--eb",
    ])
    .unwrap() else {
        panic!()
    };
    assert_eq!(request["text"], "--eb");
    assert!(request.get("eb").is_none());
}
#[test]
fn remote_prefix_validates_and_preserves_request() {
    let Command::Remote { options, command } = parse(&[
        "--remote",
        "wss://example.test",
        "--token-file",
        "/tmp/token",
        "status",
    ])
    .unwrap() else {
        panic!()
    };
    assert_eq!(options.url, "wss://example.test/mcc/v1");
    assert!(matches!(*command, Command::Request { .. }));
    for url in [
        "ws://example.test",
        "wss://x/other",
        "wss://x/a/../mcc/v1",
        "wss://u:p@x",
        "wss://x/?q=1",
        "wss://x/#x",
    ] {
        assert!(
            parse(&["--remote", url, "--token-file", "/tmp/token", "status"]).is_err(),
            "{url}"
        );
    }
    for tail in [
        vec!["daemon", "status"],
        vec!["--config"],
        vec!["host", "recover"],
        vec!["host", "disconnect-all"],
        vec!["--remote", "wss://x"],
        vec![
            "click-target",
            "--connection",
            "c",
            "--target",
            "t",
            "--jev-key",
            "secret",
        ],
    ] {
        let mut words = vec!["--remote", "wss://x", "--token-file", "/tmp/token"];
        words.extend(tail);
        assert!(parse(&words).is_err());
    }
    assert!(parse(&[
        "--remote",
        "wss://x",
        "--token-file",
        "/tmp/a",
        "--token-file",
        "/tmp/b",
        "status"
    ])
    .is_err());
    assert!(parse(&["--remote", "wss://x", "--token-file", "relative", "status"]).is_err());
}
#[test]
fn host_commands_validate_options() {
    assert!(matches!(
        parse(&["host", "recover"]).unwrap(),
        Command::Host(_)
    ));
    assert!(matches!(
        parse(&["host", "disconnect-all"]).unwrap(),
        Command::Host(HostCommand::DisconnectAll { state_dir: None })
    ));
    assert!(matches!(
        parse(&["host", "disconnect-all", "--state-dir", "/tmp/host-state"]).unwrap(),
        Command::Host(HostCommand::DisconnectAll { state_dir: Some(path) })
            if path == std::path::Path::new("/tmp/host-state")
    ));
    assert!(parse(&["host", "disconnect-all", "--state-dir", "relative"]).is_err());
    assert!(parse(&["host", "disconnect-all", "--listen", "127.0.0.1:8765"]).is_err());
    assert!(parse(&[
        "host",
        "tls",
        "init",
        "--ip",
        "127.0.0.1",
        "--output-dir",
        "/tmp/certs"
    ])
    .is_ok());
    assert!(parse(&[
        "host",
        "tls",
        "init",
        "--ip",
        "bad",
        "--output-dir",
        "/tmp/certs"
    ])
    .is_err());
    assert!(parse(&["host", "token", "init", "--output", "relative"]).is_err());
    assert!(parse(&[
        "host",
        "start",
        "--tls-cert",
        "/tmp/c",
        "--tls-key",
        "/tmp/k",
        "--token-file",
        "/tmp/t"
    ])
    .is_ok());
    assert!(parse(&["host", "start", "--tls-cert", "/tmp/c"]).is_err());
}
#[test]
fn host_san_limit_duplicates_and_remote_help() {
    let mut args = vec!["host", "tls", "init"];
    for _ in 0..9 {
        args.extend(["--dns", "localhost"]);
    }
    args.extend(["--output-dir", "/tmp/tls"]);
    assert!(parse(&args).is_err());
    assert!(parse(&[
        "host",
        "recover",
        "--state-dir",
        "/tmp/a",
        "--state-dir",
        "/tmp/b"
    ])
    .is_err());
    assert!(matches!(
        parse(&["--remote", "wss://x", "--help"]).unwrap(),
        Command::Help
    ));
    assert!(matches!(
        parse(&["--remote", "wss://x", "--version"]).unwrap(),
        Command::Version
    ));
    assert!(parse(&[
        "--remote",
        "wss://@example.test",
        "--token-file",
        "/tmp/t",
        "status"
    ])
    .is_err());
}
#[test]
fn all_scopes_preserve_legacy_requests_and_redact_debug() {
    for scope in [Scope::Chrome, Scope::Desktop] {
        let command = args::parse_for_scope(
            [
                "--remote",
                "wss://example.test/mcc/v1",
                "--token-file",
                "/tmp/token",
                "type",
                "--connection",
                "c",
                "--frame",
                "f",
                "--text",
                "private-text",
            ]
            .into_iter()
            .map(str::to_owned),
            scope,
        )
        .unwrap();
        assert!(!format!("{command:?}").contains("private-text"));
        let Command::Remote { command, .. } = command else {
            panic!()
        };
        let Command::Request { request, .. } = *command else {
            panic!()
        };
        assert_eq!(request["text"], "private-text");
    }
    assert!(parse(&[
        "click-target",
        "--connection",
        "c",
        "--target",
        "button",
        "--jev-key",
        "secret"
    ])
    .is_ok());
}
#[test]
fn remote_failure_never_creates_local_runtime() {
    let root = std::env::temp_dir().join(format!(
        "mcc-remote-cli-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    for binary in [
        env!("CARGO_BIN_EXE_copis-chrome"),
        env!("CARGO_BIN_EXE_mcc"),
        env!("CARGO_BIN_EXE_desktop-control"),
    ] {
        let runtime = root.join("runtime");
        let out = std::process::Command::new(binary)
            .env("HOME", &root)
            .env("COPIS_CHROME_RUNTIME_DIR", &runtime)
            .env("COPIS_DESKTOP_RUNTIME_DIR", &runtime)
            .args([
                "--remote",
                "wss://127.0.0.1:1",
                "--token-file",
                root.join("missing-token").to_str().unwrap(),
                "status",
            ])
            .output()
            .unwrap();
        assert!(!out.status.success());
        assert!(!runtime.exists());
        assert!(!root.join(".copis").exists());
    }
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn remote_preserves_flag_like_request_values_but_rejects_real_overrides() {
    for (tail, field, expected) in [
        (
            vec![
                "type",
                "--connection",
                "c",
                "--frame",
                "f",
                "--text",
                "--jev-key",
            ],
            "text",
            "--jev-key",
        ),
        (
            vec![
                "type",
                "--connection",
                "c",
                "--frame",
                "f",
                "--text",
                "--remote",
            ],
            "text",
            "--remote",
        ),
        (
            vec!["click-target", "--connection", "c", "--target", "--remote"],
            "target",
            "--remote",
        ),
        (
            vec!["chrome", "start", "--profile", "--token-file"],
            "profile",
            "--token-file",
        ),
    ] {
        let mut words = vec!["--remote", "wss://x", "--token-file", "/tmp/token"];
        words.extend(tail);
        let Command::Remote { command, .. } = parse(&words).unwrap() else {
            panic!()
        };
        let Command::Request { request, .. } = *command else {
            panic!()
        };
        assert_eq!(request[field], expected);
    }
    for tail in [
        vec![
            "click-target",
            "--connection",
            "c",
            "--target",
            "button",
            "--jev-key",
            "secret",
        ],
        vec!["status", "--remote", "wss://x"],
        vec!["--remote", "wss://x", "--token-file", "/tmp/t", "status"],
    ] {
        let mut words = vec!["--remote", "wss://x", "--token-file", "/tmp/token"];
        words.extend(tail);
        assert!(parse(&words).is_err());
    }
}

#[test]
fn host_json_is_a_valueless_option_without_consuming_paths() {
    let commands: &[&[&str]] = &[
        &[
            "host",
            "tls",
            "init",
            "--json",
            "--ip",
            "127.0.0.1",
            "--output-dir",
            "/tmp/certs",
            "--json",
        ],
        &[
            "host",
            "token",
            "init",
            "--json",
            "--output",
            "/tmp/token",
            "--json",
        ],
        &[
            "host",
            "start",
            "--json",
            "--tls-cert",
            "/tmp/cert",
            "--tls-key",
            "/tmp/key",
            "--token-file",
            "/tmp/token",
            "--json",
        ],
        &[
            "host",
            "recover",
            "--json",
            "--state-dir",
            "/tmp/state",
            "--json",
        ],
    ];
    for command in commands {
        for scope in [Scope::Chrome, Scope::Desktop] {
            assert!(
                matches!(
                    args::parse_for_scope(command.iter().map(|s| s.to_string()), scope).unwrap(),
                    Command::Host(_)
                ),
                "{command:?}"
            );
        }
    }
    // A value-taking option consumes the literal --json; it is not a JSON flag
    // and is rejected as a relative path, even if followed by another output.
    assert!(parse(&[
        "host",
        "token",
        "init",
        "--output",
        "--json",
        "--output",
        "/tmp/token"
    ])
    .is_err());
    assert!(parse(&["host", "recover", "--state-dir", "--json"]).is_err());
    assert!(matches!(
        parse(&[
            "--remote",
            "wss://x",
            "--token-file",
            "/tmp/token",
            "status",
            "--json"
        ])
        .unwrap(),
        Command::Remote { .. }
    ));
}
