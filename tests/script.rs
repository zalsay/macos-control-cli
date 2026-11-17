use copis_chrome::{
    args::{self, Command},
    protocol::Scope,
    remote::protocol,
};
use serde_json::json;
use std::path::PathBuf;

struct File(PathBuf);
impl File {
    fn new(contents: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "mcc-script-{}.json",
            copis_chrome::protocol::random_id().unwrap()
        ));
        std::fs::write(&path, contents).unwrap();
        Self(path)
    }
}
impl Drop for File {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
fn parse(words: &[&str]) -> copis_chrome::protocol::Result<Command> {
    args::parse_for_scope(words.iter().map(|s| s.to_string()), Scope::Desktop)
}
#[test]
fn script_cli_inlines_json_and_preserves_per_step_eb() {
    let file = File::new(
        r#"{"version":1,"steps":[{"action":"observe"},{"action":"click","x":12,"y":34,"eb":true},{"action":"type","text":"literal --eb"}]}"#,
    );
    for remote in [false, true] {
        let mut words = vec![];
        if remote {
            words.extend([
                "--remote",
                "wss://example.test",
                "--token-file",
                "/tmp/token",
            ]);
        }
        words.extend([
            "script",
            "--connection",
            "c",
            "--file",
            file.0.to_str().unwrap(),
        ]);
        let command = parse(&words).unwrap();
        let command = match command {
            Command::Remote { command, .. } => *command,
            other => other,
        };
        let Command::Request { request, output } = command else {
            panic!("request expected")
        };
        assert!(output.is_none());
        assert_eq!(request["action"], "script");
        assert_eq!(request["connectionId"], "c");
        assert_eq!(request["script"]["steps"][1]["eb"], true);
        assert!(request["script"]["steps"][2].get("eb").is_none());
        assert!(request.get("file").is_none());
    }
}
#[test]
fn script_direct_schema_accepts_only_bounded_existing_operations() {
    let good = json!({"action":"script","connectionId":"c","script":{"version":1,"steps":[{"action":"observe"},{"action":"click","x":1,"y":2,"eb":true},{"action":"wait","ms":1}]}});
    assert!(protocol::validate_action(Scope::Desktop, &good).is_ok());
    for step in [
        json!({"action":"script"}),
        json!({"action":"daemon"}),
        json!({"action":"click","x":1,"y":2,"connectionId":"other"}),
        json!({"action":"type","text":"hello","eb":"true"}),
        json!({"action":"wait","ms":10001}),
        json!({"action":"type","text":"hello","frameId":"other"}),
        json!({"action":"press","key":"bogus"}),
        json!({"action":"type","text":"中文","eb":true}),
    ] {
        let mut invalid = good.clone();
        invalid["script"]["steps"] = json!([{"action":"observe"},step]);
        assert!(
            protocol::validate_action(Scope::Desktop, &invalid).is_err(),
            "{invalid}"
        );
    }
    for script in [
        json!({"version":2,"steps":[{"action":"observe"}]}),
        json!({"version":1,"steps":[]}),
        json!({"version":1,"steps":vec![json!({"action":"observe"});65]}),
        json!({"version":1,"timeoutMs":40001,"steps":[{"action":"observe"}]}),
        json!({"version":1,"steps":[{"action":"click","x":1,"y":2}]}),
        json!({"version":1,"steps":[{"action":"wait","ms":6000},{"action":"wait","ms":6000}]}),
    ] {
        let mut invalid = good.clone();
        invalid["script"] = script;
        assert!(
            protocol::validate_action(Scope::Desktop, &invalid).is_err(),
            "{invalid}"
        );
    }
    let mut initial = good;
    initial["frameId"] = json!("f");
    initial["script"]["steps"] = json!([{"action":"click","x":1,"y":2}]);
    assert!(protocol::validate_action(Scope::Desktop, &initial).is_ok());
}
#[test]
fn script_help_never_reads_file_and_late_invalid_steps_fail_before_execution() {
    assert!(matches!(
        parse(&["script", "--help"]).unwrap(),
        Command::Help
    ));
    for contents in [
        "[]",
        "bad json",
        r#"{"version":1,"steps":[{"action":"observe"},{"action":"click","x":1}]}"#,
    ] {
        let file = File::new(contents);
        assert!(parse(&[
            "script",
            "--connection",
            "c",
            "--file",
            file.0.to_str().unwrap()
        ])
        .is_err());
    }
    let file = File::new(&" ".repeat(32769));
    assert!(parse(&[
        "script",
        "--connection",
        "c",
        "--file",
        file.0.to_str().unwrap()
    ])
    .is_err());
}

#[test]
fn script_progress_preserves_preflight_failure_index_and_rejects_inconsistent_execution() {
    let preflight = json!({"totalSteps":3,"completedSteps":0,"failedStep":3});
    assert_eq!(
        copis_chrome::script::project_progress(&preflight).unwrap()["failedStep"],
        3
    );
    for invalid in [
        json!({"totalSteps":3,"completedSteps":1,"failedStep":3,"steps":[{"index":1,"action":"observe"}]}),
        json!({"totalSteps":3,"completedSteps":0,"failedStep":0}),
        json!({"totalSteps":3,"completedSteps":0,"failedStep":4}),
        json!({"totalSteps":1,"completedSteps":1,"steps":[{"index":1,"action":"type","sent":"true"}]}),
    ] {
        assert!(copis_chrome::script::project_progress(&invalid).is_err());
    }
}

#[test]
fn script_requires_host_capability_and_help_documents_json_for_each_entry() {
    let request = json!({"action":"script","connectionId":"c","script":{"version":1,"steps":[{"action":"observe"}]}});
    assert!(protocol::require_capability(&request, &["remote-v1".into()]).is_err());
    assert!(
        protocol::require_capability(&request, &protocol::host_capabilities(Scope::Desktop))
            .is_ok()
    );
    for (scope, program) in [
        (Scope::Desktop, "mcc"),
        (Scope::Desktop, "desktop-control"),
        (Scope::Chrome, "copis-chrome"),
    ] {
        let help = args::help_text(scope, program);
        assert!(help.contains(&format!(
            "{program} script --connection <connectionId> --file /absolute/flow.json"
        )));
        assert!(help.contains("docs/SCRIPT.md"));
    }
}
