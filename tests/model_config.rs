use copis_chrome::config::Store;
use serde_json::json;
use std::os::unix::fs::{symlink, PermissionsExt};

struct Fixture(std::path::PathBuf);
impl Fixture {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!(
            "mcc-models-{}",
            copis_chrome::protocol::random_id().unwrap()
        ));
        Self(dir)
    }
    fn store(&self) -> Store {
        Store::new(self.0.clone())
    }
    fn run(&self, args: &[&str], input: &str) -> copis_chrome::protocol::Result<serde_json::Value> {
        self.store().execute(
            &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            input.as_bytes(),
        )
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn set(f: &Fixture, url: &str, model: &str, key: &str) {
    f.run(
        &[
            "set",
            "jev",
            "--url",
            url,
            "--model",
            model,
            "--api-key-stdin",
        ],
        key,
    )
    .unwrap();
}
#[test]
fn stores_real_toml_privately_and_masks_every_read_receipt() {
    let f = Fixture::new();
    let initial = f.run(&[], "").unwrap();
    assert_eq!(initial["configured"], false);
    set(
        &f,
        "https://router.example/decisions",
        "vendor/jev-new",
        "private-key\n",
    );
    let view = f.run(&["show", "jev"], "").unwrap();
    assert!(!view.to_string().contains("private-key"));
    assert_eq!(view["profile"]["api_key"], "[REDACTED]");
    let contents = std::fs::read_to_string(f.0.join("models.toml")).unwrap();
    assert_eq!(
        toml::from_str::<toml::Value>(&contents).unwrap()["models"]["jev"]["api_key"].as_str(),
        Some("private-key")
    );
    for (path, mode) in [(&f.0, 0o700), (&f.0.join("models.toml"), 0o600)] {
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            mode
        );
    }
    let resolved = f.store().resolve_model(None).unwrap();
    assert_eq!(resolved.model, "vendor/jev-new");
    assert_eq!(resolved.url, "https://router.example/decisions");
    assert_eq!(resolved.api_key, "private-key");
    assert!(!format!("{resolved:?}").contains("private-key"));
    assert_eq!(
        f.store()
            .resolve_model(Some("override-key"))
            .unwrap()
            .api_key,
        "override-key"
    );
}
#[test]
fn no_dotenv_fallback_and_config_changes_are_read_per_invocation() {
    let f = Fixture::new();
    assert!(f.store().resolve_model(Some("override")).is_err());
    set(&f, "https://one.example/api", "vendor/first", "first");
    set(&f, "https://two.example/api", "vendor/next", "second");
    assert_eq!(f.store().resolve_model(None).unwrap().model, "vendor/next");
    let before = std::fs::read(f.0.join("models.toml")).unwrap();
    assert!(f
        .run(&["set", "jev", "--url", "https://else.example/api"], "")
        .is_err());
    assert_eq!(std::fs::read(f.0.join("models.toml")).unwrap(), before);
    f.run(&["set", "jev", "--model", "vendor/third"], "")
        .unwrap();
    assert_eq!(f.store().resolve_model(None).unwrap().api_key, "second");
}
#[test]
fn strict_parser_atomic_failure_and_window_config_separation() {
    let f = Fixture::new();
    set(&f, "https://router.example/api", "vendor/model", "secret");
    for args in [
        vec![
            "set",
            "other",
            "--url",
            "http://remote.example/api",
            "--model",
            "v/m",
            "--api-key",
            "secret",
        ],
        vec![
            "set",
            "other",
            "--url",
            "https://secret@host/api",
            "--model",
            "v/m",
            "--api-key",
            "secret",
        ],
        vec![
            "set",
            "other",
            "--url",
            "https://host/api#fragment",
            "--model",
            "v/m",
            "--api-key",
            "secret",
        ],
        vec!["set", "../bad", "--api-key", "secret"],
        vec!["set", "jev", "--api-key", "secret", "--api-key-stdin"],
        vec!["set", "jev", "--model", "one", "--model", "two"],
        vec!["default", "missing"],
    ] {
        assert!(f.run(&args, "secret").is_err(), "{args:?}");
    }
    f.run(&["window", "--max-width", "1400"], "").unwrap();
    assert_eq!(f.store().window_max_width().unwrap(), 1400);
    assert!(f.run(&["window", "--max-width", "1601"], "").is_err());
    let window = std::fs::read_to_string(f.0.join("config.toml")).unwrap();
    assert_eq!(
        toml::from_str::<toml::Value>(&window).unwrap()["chrome"]["window"]["position"].as_str(),
        Some("left")
    );
    assert!(!window.contains("secret"));
    std::fs::write(f.0.join("models.toml"), "default_model = 'secret\n").unwrap();
    let error = f.store().resolve_model(None).unwrap_err();
    assert!(!error.to_string().contains("secret"));
}
#[test]
fn rejects_symlinks_insecure_modes_and_concurrent_writes() {
    let f = Fixture::new();
    set(&f, "https://router.example/api", "v/m", "secret");
    std::fs::write(f.0.join("config.lock"), "locked").unwrap();
    assert!(f.run(&["default", "jev"], "").is_err());
    std::fs::remove_file(f.0.join("config.lock")).unwrap();
    std::fs::set_permissions(
        f.0.join("models.toml"),
        std::fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    assert!(f.store().resolve_model(None).is_err());
    std::fs::remove_file(f.0.join("models.toml")).unwrap();
    symlink("/dev/null", f.0.join("models.toml")).unwrap();
    assert!(f.store().resolve_model(None).is_err());
    assert_eq!(f.store().window_max_width().unwrap(), 1600);
    assert_eq!(json!({"safe":true})["safe"], true);
}

#[test]
fn switching_named_default_selects_entire_profile_not_only_key() {
    let f = Fixture::new();
    set(
        &f,
        "https://first.example/alpha/decisions",
        "first/model",
        "first-secret",
    );
    f.run(
        &[
            "set",
            "second",
            "--url",
            "http://[::1]:8080/custom",
            "--model",
            "second/model",
            "--api-key-stdin",
        ],
        "second-secret",
    )
    .unwrap();
    assert_eq!(f.store().resolve_model(None).unwrap().model, "first/model");
    f.run(&["default", "second"], "").unwrap();
    let resolved = f.store().resolve_model(None).unwrap();
    assert_eq!(resolved.model, "second/model");
    assert_eq!(resolved.url, "http://[::1]:8080/custom");
    assert_eq!(resolved.api_key, "second-secret");
    assert_eq!(
        std::fs::read_dir(&f.0).unwrap().count(),
        1,
        "no lingering locks or temp files"
    );
}

#[test]
fn malformed_default_and_unknown_fields_fail_without_echoing_toml_source() {
    let f = Fixture::new();
    set(
        &f,
        "https://first.example/api",
        "v/model",
        "never-echo-secret",
    );
    let path = f.0.join("models.toml");
    let original = std::fs::read_to_string(&path).unwrap();
    for bad in [
        original.replace("default_model = \"jev\"", "default_model = \"missing\""),
        original.replace("api_key =", "unexpected_secret ="),
    ] {
        std::fs::write(&path, bad).unwrap();
        let error = f.run(&[], "").unwrap_err();
        assert!(!error.to_string().contains("never-echo-secret"));
        assert!(f.store().resolve_model(None).is_err());
    }
}

#[test]
fn chrome_profile_config_preserves_window_settings_and_can_be_cleared() {
    let f = Fixture::new();
    set(
        &f,
        "https://router.example/api",
        "vendor/model",
        "profile-test-key",
    );
    let models_before = std::fs::read(f.0.join("models.toml")).unwrap();
    assert_eq!(f.store().window_max_width().unwrap(), 1600);
    assert_eq!(f.store().chrome_start_settings().unwrap(), (1600, None));

    f.run(&["chrome", "--profile", "mcc"], "").unwrap();
    assert_eq!(
        f.store().chrome_start_settings().unwrap(),
        (1600, Some("mcc".to_owned()))
    );
    let initial = std::fs::read_to_string(f.0.join("config.toml")).unwrap();
    let parsed: toml::Value = toml::from_str(&initial).unwrap();
    assert_eq!(parsed["chrome"]["profile"].as_str(), Some("mcc"));
    assert_eq!(
        parsed["chrome"]["window"]["max_width_px"].as_integer(),
        Some(1600)
    );

    f.run(&["window", "--max-width", "1400"], "").unwrap();
    let settings: toml::Value =
        toml::from_str(&std::fs::read_to_string(f.0.join("config.toml")).unwrap()).unwrap();
    assert_eq!(settings["chrome"]["profile"].as_str(), Some("mcc"));
    assert_eq!(f.store().window_max_width().unwrap(), 1400);
    assert_eq!(
        f.store().chrome_start_settings().unwrap(),
        (1400, Some("mcc".to_owned()))
    );

    f.run(&["chrome", "--clear-profile"], "").unwrap();
    let cleared = std::fs::read_to_string(f.0.join("config.toml")).unwrap();
    let parsed: toml::Value = toml::from_str(&cleared).unwrap();
    assert!(parsed["chrome"].get("profile").is_none());
    assert_eq!(f.store().window_max_width().unwrap(), 1400);
    assert_eq!(f.store().chrome_start_settings().unwrap(), (1400, None));
    assert_eq!(
        std::fs::read(f.0.join("models.toml")).unwrap(),
        models_before
    );
}

#[test]
fn invalid_chrome_profiles_do_not_modify_existing_config() {
    let f = Fixture::new();
    f.run(&["chrome", "--profile", "mcc"], "").unwrap();
    let before = std::fs::read(f.0.join("config.toml")).unwrap();

    for invalid in ["", &"x".repeat(129), " mcc", "mcc ", "mcc\n"] {
        assert!(f.run(&["chrome", "--profile", invalid], "").is_err());
        assert_eq!(std::fs::read(f.0.join("config.toml")).unwrap(), before);
    }
}

#[test]
fn legacy_and_new_model_configs_are_enabled_by_default() {
    let f = Fixture::new();
    set(
        &f,
        "https://router.example/api",
        "vendor/model",
        "legacy-secret",
    );
    assert_eq!(
        f.run(&["show", "jev"], "").unwrap()["profile"]["enabled"],
        true
    );
    let path = f.0.join("models.toml");
    let mut legacy: toml::Value = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    legacy["models"]["jev"]
        .as_table_mut()
        .unwrap()
        .remove("enabled");
    std::fs::write(&path, toml::to_string(&legacy).unwrap()).unwrap();
    assert_eq!(f.run(&[], "").unwrap()["models"]["jev"]["enabled"], true);
    assert_eq!(f.store().resolve_model(None).unwrap().model, "vendor/model");
}

#[test]
fn disable_and_enable_preserve_credentials_default_and_chrome_settings() {
    let f = Fixture::new();
    set(
        &f,
        "https://router.example/api",
        "vendor/model",
        "toggle-secret",
    );
    f.run(&["chrome", "--profile", "mcc"], "").unwrap();
    f.run(&["window", "--max-width", "1400"], "").unwrap();
    let chrome_before = std::fs::read(f.0.join("config.toml")).unwrap();
    for _ in 0..2 {
        let disabled = f.run(&["disable", "jev"], "").unwrap();
        assert_eq!(disabled["saved"], true);
        assert_eq!(disabled["profile"]["enabled"], false);
        assert!(!disabled.to_string().contains("toggle-secret"));
        assert_eq!(f.run(&[], "").unwrap()["default_model"], "jev");
        assert_eq!(f.run(&[], "").unwrap()["configured"], true);
        assert_eq!(
            f.run(&["show", "jev"], "").unwrap()["profile"]["enabled"],
            false
        );
        for key in [None, Some("override-secret")] {
            assert_eq!(
                f.store().resolve_model(key).unwrap_err().code,
                "MODEL_DISABLED"
            );
        }
    }
    let persisted: toml::Value =
        toml::from_str(&std::fs::read_to_string(f.0.join("models.toml")).unwrap()).unwrap();
    assert_eq!(persisted["models"]["jev"]["enabled"].as_bool(), Some(false));
    assert_eq!(
        persisted["models"]["jev"]["api_key"].as_str(),
        Some("toggle-secret")
    );
    for _ in 0..2 {
        let enabled = f.run(&["enable", "jev"], "").unwrap();
        assert_eq!(enabled["profile"]["enabled"], true);
        assert_eq!(enabled["profile"]["api_key"], "[REDACTED]");
        let resolved = f.store().resolve_model(None).unwrap();
        assert_eq!(resolved.url, "https://router.example/api");
        assert_eq!(resolved.model, "vendor/model");
        assert_eq!(resolved.api_key, "toggle-secret");
    }
    assert_eq!(
        std::fs::read(f.0.join("config.toml")).unwrap(),
        chrome_before
    );
    assert_eq!(
        f.store().chrome_start_settings().unwrap(),
        (1400, Some("mcc".into()))
    );
    assert!(!f.0.join("config.lock").exists());
}

#[test]
fn updating_a_disabled_model_does_not_reenable_it_or_reuse_cross_endpoint_keys() {
    let f = Fixture::new();
    set(&f, "https://one.example/api", "vendor/old", "old-key");
    f.run(&["disable", "jev"], "").unwrap();
    f.run(&["set", "jev", "--model", "vendor/new"], "").unwrap();
    assert_eq!(
        f.run(&["show", "jev"], "").unwrap()["profile"]["enabled"],
        false
    );
    assert_eq!(
        f.store().resolve_model(None).unwrap_err().code,
        "MODEL_DISABLED"
    );
    let before = std::fs::read(f.0.join("models.toml")).unwrap();
    assert_eq!(
        f.run(&["set", "jev", "--url", "https://two.example/api"], "")
            .unwrap_err()
            .code,
        "MODEL_KEY_REQUIRED"
    );
    assert_eq!(std::fs::read(f.0.join("models.toml")).unwrap(), before);
    set(&f, "https://two.example/api", "vendor/updated", "new-key");
    assert_eq!(
        f.run(&["show", "jev"], "").unwrap()["profile"]["enabled"],
        false
    );
    f.run(&["enable", "jev"], "").unwrap();
    let resolved = f.store().resolve_model(None).unwrap();
    assert_eq!(resolved.model, "vendor/updated");
    assert_eq!(resolved.url, "https://two.example/api");
    assert_eq!(resolved.api_key, "new-key");
}

#[test]
fn toggling_one_profile_neither_selects_nor_falls_back_to_another_model() {
    let f = Fixture::new();
    set(&f, "https://one.example/api", "vendor/first", "first-key");
    f.run(
        &[
            "set",
            "second",
            "--url",
            "https://two.example/api",
            "--model",
            "vendor/second",
            "--api-key-stdin",
        ],
        "second-key",
    )
    .unwrap();
    f.run(&["disable", "second"], "").unwrap();
    assert_eq!(f.store().resolve_model(None).unwrap().model, "vendor/first");
    f.run(&["enable", "second"], "").unwrap();
    f.run(&["disable", "jev"], "").unwrap();
    assert_eq!(
        f.store().resolve_model(None).unwrap_err().code,
        "MODEL_DISABLED"
    );
    assert_eq!(f.run(&[], "").unwrap()["default_model"], "jev");
    f.run(&["default", "second"], "").unwrap();
    assert_eq!(
        f.store().resolve_model(None).unwrap().model,
        "vendor/second"
    );
    // Selecting a profile does not implicitly enable it.
    f.run(&["default", "jev"], "").unwrap();
    assert_eq!(
        f.store().resolve_model(None).unwrap_err().code,
        "MODEL_DISABLED"
    );
}

#[test]
fn toggle_rejects_unknown_names_bad_arguments_and_busy_config_without_mutating_files() {
    let f = Fixture::new();
    set(
        &f,
        "https://router.example/api",
        "vendor/model",
        "private-test-key",
    );
    let path = f.0.join("models.toml");
    let before = std::fs::read(&path).unwrap();
    for args in [
        vec!["enable"],
        vec!["disable"],
        vec!["enable", "missing"],
        vec!["disable", "missing"],
        vec!["enable", "../jev"],
        vec!["disable", "jev", "extra"],
    ] {
        assert!(f.run(&args, "").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert!(!f.0.join("config.lock").exists());
    }
    std::fs::write(f.0.join("config.lock"), "busy").unwrap();
    for command in ["enable", "disable"] {
        assert_eq!(
            f.run(&[command, "jev"], "").unwrap_err().code,
            "CONFIG_BUSY"
        );
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }
}

#[test]
fn enabled_is_a_strict_boolean_and_errors_never_echo_config_credentials() {
    let f = Fixture::new();
    set(
        &f,
        "https://router.example/api",
        "vendor/model",
        "never-echo-toggle-secret",
    );
    let path = f.0.join("models.toml");
    let mut value: toml::Value = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    value["models"]["jev"]
        .as_table_mut()
        .unwrap()
        .insert("enabled".into(), toml::Value::Boolean(false));
    std::fs::write(&path, toml::to_string(&value).unwrap()).unwrap();
    assert_eq!(
        f.store().resolve_model(None).unwrap_err().code,
        "MODEL_DISABLED"
    );
    for invalid in [
        toml::Value::String("false".into()),
        toml::Value::Integer(0),
        toml::Value::Array(vec![]),
    ] {
        value["models"]["jev"]["enabled"] = invalid;
        std::fs::write(&path, toml::to_string(&value).unwrap()).unwrap();
        let before = std::fs::read(&path).unwrap();
        for args in [vec![], vec!["enable", "jev"], vec!["disable", "jev"]] {
            let error = f.run(&args, "").unwrap_err();
            assert_eq!(error.code, "CONFIG_INVALID");
            assert!(!error.to_string().contains("never-echo-toggle-secret"));
            assert_eq!(std::fs::read(&path).unwrap(), before);
        }
    }
}
