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
