use copis_chrome::args::{parse, Command};
use serde_json::json;

fn parse_args(args: &[&str]) -> copis_chrome::protocol::Result<Command> {
    parse(args.iter().map(|arg| (*arg).to_owned()))
}

#[test]
fn chrome_start_passes_only_an_explicit_display_profile() {
    let Command::Request { request, .. } = parse_args(&[
        "chrome",
        "start",
        "--profile",
        "Work profile",
        "--url",
        "https://example.com/",
    ])
    .unwrap() else {
        panic!("chrome start should create a request");
    };
    assert_eq!(
        request,
        json!({
            "action":"chrome-start",
            "profile":"Work profile",
            "url":"https://example.com/"
        })
    );

    let Command::Request { request, .. } = parse_args(&["chrome", "start"]).unwrap() else {
        panic!("chrome start should create a request");
    };
    assert_eq!(request, json!({"action":"chrome-start"}));
    assert!(parse_args(&["chrome", "start", "--profile-directory", "Default"]).is_err());
}

#[test]
fn chrome_display_profile_validation_counts_unicode_scalars_and_rejects_unsafe_edges() {
    let max_profile = "界".repeat(128);
    assert!(parse_args(&["chrome", "start", "--profile", &max_profile]).is_ok());

    for invalid in [
        "",
        &"界".repeat(129),
        " mcc",
        "mcc ",
        "\tmcc",
        "\u{00a0}mcc",
        "mcc\n",
        "m\u{0000}cc",
    ] {
        assert!(
            parse_args(&["chrome", "start", "--profile", invalid]).is_err(),
            "profile should be rejected: {invalid:?}"
        );
    }
}

#[test]
fn config_parser_preserves_chrome_profile_set_and_clear_forms() {
    let Command::Config(args) = parse_args(&["--config", "chrome", "--profile", "mcc"]).unwrap()
    else {
        panic!("config command expected");
    };
    assert_eq!(args, ["chrome", "--profile", "mcc"]);

    let Command::Config(args) = parse_args(&["--config", "chrome", "--clear-profile"]).unwrap()
    else {
        panic!("config command expected");
    };
    assert_eq!(args, ["chrome", "--clear-profile"]);
}

#[test]
fn mcc_help_distinguishes_chrome_display_names_from_model_profiles() {
    use copis_chrome::args::{help_text, DESKTOP_HELP};
    use copis_chrome::protocol::Scope;

    let help = help_text(Scope::Desktop, "mcc");
    assert!(help.contains("Chrome 的显示名称"));
    assert!(help.contains("models.toml"));
    assert!(help.contains("模型 profile"));
    assert!(!help.contains("--profile-directory"));
    assert!(!DESKTOP_HELP.contains("profile create"));
}
