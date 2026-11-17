#![cfg(target_os = "macos")]
use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "mcc-eb-{}",
            copis_chrome::protocol::random_id().unwrap()
        ));
        std::fs::create_dir_all(root.join("bin")).unwrap();
        Self(root)
    }

    fn backend(&self) {
        let file = self.0.join("bin/macos-ble-control");
        // Only the external BLE process is substituted. MCC's parsing, dispatch,
        // argv transport, stdio and exit status all execute as shipped.
        std::fs::write(
            &file,
            "#!/bin/sh\nprintf '<%s>\\n' \"$@\"\nif [ -n \"${EB_TEST_ERROR-}\" ]; then printf '%s\\n' \"$EB_TEST_ERROR\" >&2; fi\nexit \"${EB_TEST_EXIT-0}\"\n",
        )
        .unwrap();
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_mcc"));
        command
            .current_dir(&self.0)
            .env("PATH", self.0.join("bin"))
            .env("COPIS_DESKTOP_RUNTIME_DIR", self.0.join("runtime"))
            .env("MCC_CONFIG_DIR", self.0.join("config"))
            .env("COPIS_DESKTOP_HELPER", self.0.join("missing-helper"));
        command
    }

    fn call(&self, args: &[&str]) -> Output {
        self.command().args(args).output().unwrap()
    }

    fn bundled_command(&self) -> (Command, PathBuf) {
        let bundle = self.0.join("bundle with spaces");
        std::fs::create_dir(&bundle).unwrap();
        std::fs::copy(env!("CARGO_BIN_EXE_mcc"), bundle.join("mcc")).unwrap();
        let mut command = Command::new(bundle.join("mcc"));
        command
            .current_dir(&self.0)
            .env("PATH", self.0.join("bin"))
            .env("COPIS_DESKTOP_RUNTIME_DIR", self.0.join("runtime"))
            .env("MCC_CONFIG_DIR", self.0.join("config"));
        (command, bundle)
    }

    fn assert_no_desktop_state(&self) {
        assert!(!self.0.join("runtime").exists());
        assert!(!self.0.join("config").exists());
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn eb_status_routes_to_ble_without_desktop_runtime_or_json_wrapper() {
    let fixture = Fixture::new();
    fixture.backend();
    let output = fixture.call(&["--eb", "status"]);
    assert!(output.status.success(), "{:?}", output);
    assert_eq!(output.stdout, b"<--status>\n");
    assert!(output.stderr.is_empty());
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_subcommands_preserve_values_and_flag_sequences() {
    let fixture = Fixture::new();
    fixture.backend();
    let cases: &[(&[&str], &str)] = &[
        (&["--eb", "move", "52,54"], "<--move>\n<52,54>\n"),
        (&["--eb", "click", "52,54"], "<--click>\n<52,54>\n"),
        (&["--eb", "click"], "<--click>\n"),
        (&["--eb", "key", "cmd+a"], "<--key>\n<cmd+a>\n"),
        (&["--eb", "scroll", "-3,0"], "<--scroll>\n<-3,0>\n"),
        (
            &["--eb", "--move", "52,54", "--click"],
            "<--move>\n<52,54>\n<--click>\n",
        ),
        (
            &["--eb", "move", "52,54", "--click", "--dry-run"],
            "<--move>\n<52,54>\n<--click>\n<--dry-run>\n",
        ),
        (&["--eb", "type", "--help"], "<--type>\n<--help>\n"),
        (
            &["--eb", "type", "a b\n'$()`touch injected`"],
            "<--type>\n<a b\n'$()`touch injected`>\n",
        ),
    ];
    for (args, expected) in cases {
        let output = fixture.call(args);
        assert!(output.status.success(), "{args:?}: {output:?}");
        assert_eq!(String::from_utf8(output.stdout).unwrap(), *expected);
    }
    assert!(!fixture.0.join("injected").exists());
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_help_does_not_require_backend_or_create_state() {
    let fixture = Fixture::new();
    for args in [
        vec!["--eb"],
        vec!["--eb", "help"],
        vec!["--eb", "--help"],
        vec!["--eb", "-h"],
    ] {
        let output = fixture.call(&args);
        assert!(output.status.success(), "{args:?}: {output:?}");
        let help = String::from_utf8(output.stdout).unwrap();
        assert!(help.contains("mcc --eb status"));
        assert!(help.contains("mcc --eb move 52,54"));
        assert!(help.contains("macos-ble-control"));
        assert!(output.stderr.is_empty());
    }
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_propagates_backend_failure_without_retry_or_fallback() {
    let fixture = Fixture::new();
    fixture.backend();
    let output = fixture
        .command()
        .args(["--eb", "status"])
        .env("EB_TEST_EXIT", "17")
        .env("EB_TEST_ERROR", "BLE failure")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(17));
    assert_eq!(output.stdout, b"<--status>\n");
    assert_eq!(output.stderr, b"BLE failure\n");
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_missing_backend_returns_actionable_error_without_starting_daemon() {
    let fixture = Fixture::new();
    let output = fixture.call(&["--eb", "status"]);
    assert!(!output.status.success());
    let result: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(result["error"]["code"], "BLE_CLIENT_NOT_FOUND");
    assert!(result["error"]["message"]
        .as_str()
        .unwrap()
        .contains("macos-ble-control"));
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_rejects_unknown_commands_and_remote_use_before_backend_dispatch() {
    let fixture = Fixture::new();
    fixture.backend();
    for args in [
        vec!["--eb", "unknown"],
        vec!["--eb", "--unknown"],
        vec![
            "--remote",
            "wss://example.test",
            "--token-file",
            "/tmp/token",
            "--eb",
            "status",
        ],
    ] {
        let output = fixture.call(&args);
        assert!(!output.status.success());
        let result: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(result["error"]["code"], "INVALID_ARGUMENT");
    }
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_does_not_change_chrome_only_entry_or_expose_type_text_in_debug() {
    use copis_chrome::{args, protocol::Scope};
    assert!(args::parse_for_scope(["--eb", "status"].map(str::to_owned), Scope::Chrome).is_err());
    let command = args::parse_for_scope(
        ["--eb", "type", "private-text"].map(str::to_owned),
        Scope::Desktop,
    )
    .unwrap();
    assert!(!format!("{command:?}").contains("private-text"));
}

#[test]
fn eb_prefers_bundled_client_over_path_client() {
    let fixture = Fixture::new();
    fixture.backend();
    let (mut command, bundle) = fixture.bundled_command();
    let client = bundle.join("macos-ble-control");
    std::fs::write(&client, "#!/bin/sh\nprintf 'bundled\\n<%s>\\n' \"$1\"\n").unwrap();
    std::fs::set_permissions(client, std::fs::Permissions::from_mode(0o755)).unwrap();
    let output = command.args(["--eb", "status"]).output().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, b"bundled\n<--status>\n");
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_does_not_fallback_to_path_after_bundled_failure() {
    let fixture = Fixture::new();
    fixture.backend();
    let (mut command, bundle) = fixture.bundled_command();
    let client = bundle.join("macos-ble-control");
    std::fs::write(
        &client,
        "#!/bin/sh\nprintf 'bundled failure\\n' >&2\nexit 19\n",
    )
    .unwrap();
    std::fs::set_permissions(client, std::fs::Permissions::from_mode(0o755)).unwrap();
    let output = command.args(["--eb", "status"]).output().unwrap();
    assert_eq!(output.status.code(), Some(19));
    assert!(output.stdout.is_empty());
    assert_eq!(output.stderr, b"bundled failure\n");
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_nonexecutable_bundled_client_is_error_without_path_fallback() {
    let fixture = Fixture::new();
    fixture.backend();
    let (mut command, bundle) = fixture.bundled_command();
    let client = bundle.join("macos-ble-control");
    std::fs::write(&client, "not executable").unwrap();
    std::fs::set_permissions(client, std::fs::Permissions::from_mode(0o644)).unwrap();
    let output = command.args(["--eb", "status"]).output().unwrap();
    assert!(!output.status.success());
    let result: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(result["error"]["code"], "IO_ERROR");
    fixture.assert_no_desktop_state();
}

#[test]
fn eb_entry_symlink_resolves_client_next_to_actual_executable() {
    let fixture = Fixture::new();
    fixture.backend();
    let (_, bundle) = fixture.bundled_command();
    let client = bundle.join("macos-ble-control");
    std::fs::write(&client, "#!/bin/sh\nprintf 'bundled\\n<%s>\\n' \"$1\"\n").unwrap();
    std::fs::set_permissions(client, std::fs::Permissions::from_mode(0o755)).unwrap();
    let entry = fixture.0.join("bin/mcc");
    std::os::unix::fs::symlink(bundle.join("mcc"), &entry).unwrap();
    let output = Command::new(entry)
        .args(["--eb", "status"])
        .env("PATH", fixture.0.join("bin"))
        .env("COPIS_DESKTOP_RUNTIME_DIR", fixture.0.join("runtime"))
        .env("MCC_CONFIG_DIR", fixture.0.join("config"))
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, b"bundled\n<--status>\n");
    fixture.assert_no_desktop_state();
}
