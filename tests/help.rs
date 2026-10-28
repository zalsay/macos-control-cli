#![cfg(target_os = "macos")]
use copis_chrome::{args, protocol::Scope};
use std::process::Command;

const ENTRIES: [(&str, &str, Scope); 3] = [
    ("mcc", env!("CARGO_BIN_EXE_mcc"), Scope::Desktop),
    (
        "desktop-control",
        env!("CARGO_BIN_EXE_desktop-control"),
        Scope::Desktop,
    ),
    (
        "copis-chrome",
        env!("CARGO_BIN_EXE_copis-chrome"),
        Scope::Chrome,
    ),
];

#[test]
fn help_documents_current_install_model_and_local_workflow() {
    let help = args::help_text(Scope::Desktop, "mcc");
    assert!(help.contains(&format!("当前版本：{}", env!("CARGO_PKG_VERSION"))));
    for required in [
        "本机快速开始",
        "mcc chrome start --url https://example.com/",
        "mcc --config show jev",
        "mcc --config disable jev",
        "~/Applications/MCC/mcc",
        "~/Applications/MCC/macos-chrome-helper",
        "docs/STABLE-INSTALL.md",
        "docs/MODEL-CONFIG.md",
        "Decisions",
        "仅需结束本任务自建 daemon",
        "mcc daemon stop",
    ] {
        assert!(help.contains(required), "missing current help: {required}");
    }
    assert!(!help.contains("任务结束必须 disconnect 并 daemon stop"));
}

#[test]
fn all_entrypoints_document_remote_security_lifecycle_and_correct_command_names() {
    for (program, _, scope) in ENTRIES {
        let help = args::help_text(scope, program);
        for required in [
            "远端 Host",
            "本地 client",
            "--remote 必须紧跟命令名",
            "仅支持 wss://",
            "host-ca.pem",
            "host-cert.pem",
            "host-key.pem",
            "--files-root",
            "--remote-state-dir",
            "不在客户端启动 helper",
            "远端不支持 --config、--jev-key、daemon、host、permissions --request",
            "SSH",
            "300 秒",
            "USER_PAUSED",
            "RECOVERY_REQUIRED",
            "docs/REMOTE-HOST.md",
        ] {
            assert!(help.contains(required), "{program}: missing {required}");
        }
        for line in help.lines().filter(|line| line.starts_with("  ")) {
            for other in ["mcc", "desktop-control", "copis-chrome"] {
                if other != program {
                    assert!(
                        !line.starts_with(&format!("  {other} ")),
                        "{program}: wrong entrypoint in {line}"
                    );
                }
            }
        }
    }
}

#[test]
fn documented_local_host_and_remote_examples_parse_in_every_scope() {
    let examples: &[&[&str]] = &[
        &["chrome", "start", "--url", "https://example.com/"],
        &["--config", "show", "jev"],
        &["--config", "disable", "jev"],
        &[
            "host",
            "tls",
            "init",
            "--dns",
            "host.example",
            "--output-dir",
            "/absolute/host-tls",
        ],
        &[
            "host",
            "token",
            "init",
            "--output",
            "/absolute/access.token",
        ],
        &[
            "host",
            "start",
            "--listen",
            "0.0.0.0:8765",
            "--tls-cert",
            "/absolute/host-tls/host-cert.pem",
            "--tls-key",
            "/absolute/host-tls/host-key.pem",
            "--token-file",
            "/absolute/access.token",
            "--state-dir",
            "/absolute/host-state",
        ],
        &[
            "--remote",
            "wss://host.example:8765/mcc/v1",
            "--ca-cert",
            "/absolute/host-ca.pem",
            "--token-file",
            "/absolute/access.token",
            "--remote-state-dir",
            "/absolute/client-state",
            "status",
        ],
        &["host", "recover", "--state-dir", "/absolute/host-state"],
    ];
    for (program, _, scope) in ENTRIES {
        let help = args::help_text(scope, program);
        for example in examples {
            let line = format!("  {program} {}", example.join(" "));
            assert!(help.lines().any(|s| s == line), "missing example: {line}");
            args::parse_for_scope(example.iter().map(|s| (*s).to_owned()), scope)
                .unwrap_or_else(|_| panic!("documented example does not parse: {line}"));
        }
    }
}

#[test]
fn help_aliases_and_remote_host_help_never_create_runtime_config_or_credentials() {
    let root = std::env::temp_dir().join(format!(
        "mcc-help-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    assert!(!root.exists());
    let variants: &[&[&str]] = &[
        &["--help"],
        &["-h"],
        &["help"],
        &["host", "start", "--help"],
        &["--remote", "wss://host.example:8765/mcc/v1", "--help"],
    ];
    for (program, executable, scope) in ENTRIES {
        let expected = args::help_text(scope, program);
        for variant in variants {
            let output = Command::new(executable)
                .args(*variant)
                .env("HOME", root.join("home"))
                .env("MCC_CONFIG_DIR", root.join("config"))
                .env("COPIS_DESKTOP_RUNTIME_DIR", root.join("desktop"))
                .env("COPIS_CHROME_RUNTIME_DIR", root.join("chrome"))
                .env("COPIS_DESKTOP_HELPER", root.join("missing-helper"))
                .env("COPIS_CHROME_HELPER", root.join("missing-helper"))
                .output()
                .unwrap();
            assert!(output.status.success(), "{program}: {variant:?}");
            assert!(output.stderr.is_empty());
            assert_eq!(String::from_utf8(output.stdout).unwrap(), expected);
            assert!(!root.exists(), "help created data under {}", root.display());
        }
    }
}
