use copis_chrome::{config::Store, protocol::Error};
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Default,
    Enable,
    Disable,
}

fn public_error(error: Error) -> String {
    format!("{}：{}", error.code, error.message)
}

pub fn summary(store: &Store) -> crate::store::Result<Value> {
    store.model_summary_for_panel().map_err(public_error)
}

pub fn save(
    store: &Store,
    name: &str,
    url: &str,
    model: &str,
    key: Option<&str>,
) -> crate::store::Result<Value> {
    let mut args = ["set", name, "--url", url, "--model", model]
        .map(str::to_owned)
        .to_vec();
    if key.is_some() {
        args.push("--api-key-stdin".into());
    }
    store
        .execute(&args, key.unwrap_or_default().as_bytes())
        .map_err(public_error)?;
    summary(store)
}

pub fn change(store: &Store, name: &str, operation: Operation) -> crate::store::Result<Value> {
    let command = match operation {
        Operation::Default => "default",
        Operation::Enable => "enable",
        Operation::Disable => "disable",
    };
    store
        .execute(&[command.into(), name.into()], std::io::empty())
        .map_err(public_error)?;
    summary(store)
}

#[cfg(test)]
mod tests {
    use super::*;
    const TEST_KEY: &str = "sk-fixture-key-that-must-not-reach-the-webview";

    #[test]
    fn jev_editor_shares_mcc_storage_and_never_returns_key() {
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(copis_chrome::protocol::random_id().unwrap());
        struct Scratch(std::path::PathBuf);
        impl Drop for Scratch {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let scratch = Scratch(directory);
        let store = Store::new(scratch.0.clone());
        let summary = save(
            &store,
            "jev",
            "https://example.test/decisions",
            "jev-v1",
            Some(TEST_KEY),
        )
        .unwrap();
        assert_eq!(summary["default_model"], "jev");
        assert_eq!(summary["models"]["jev"]["enabled"], true);
        assert!(summary["models"]["jev"].get("api_key").is_none());
        assert_eq!(summary["models"]["jev"]["key_preview"], "sk-********");
        assert!(!summary.to_string().contains(TEST_KEY));
        let short = save(
            &store,
            "short",
            "https://example.test/decisions",
            "jev-v1",
            Some("abc"),
        )
        .unwrap();
        assert_eq!(short["models"]["short"]["key_preview"], "********");
        let cli = store.execute(&[], std::io::empty()).unwrap();
        assert_eq!(cli["models"]["jev"]["api_key"], "[REDACTED]");
        assert!(cli["models"]["jev"].get("key_preview").is_none());
        assert_eq!(
            std::fs::metadata(scratch.0.join("models.toml"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        save(
            &store,
            "jev",
            "https://example.test/decisions",
            "jev-v2",
            None,
        )
        .unwrap();
        assert_eq!(store.resolve_model(None).unwrap().api_key, TEST_KEY);
        assert!(save(
            &store,
            "jev",
            "https://other.test/decisions",
            "jev-v2",
            None
        )
        .unwrap_err()
        .contains("MODEL_KEY_REQUIRED"));
        assert_eq!(
            store.resolve_model(None).unwrap().url,
            "https://example.test/decisions"
        );
        assert!(save(
            &store,
            "missing",
            "https://example.test/decisions",
            "jev-v2",
            None
        )
        .is_err());
        save(
            &store,
            "second",
            "https://example.test/decisions",
            "jev-v3",
            Some("second-test-key"),
        )
        .unwrap();
        assert_eq!(
            change(&store, "second", Operation::Default).unwrap()["default_model"],
            "second"
        );
        assert_eq!(
            change(&store, "second", Operation::Disable).unwrap()["models"]["second"]["enabled"],
            false
        );
        assert_eq!(
            store.resolve_model(None).unwrap_err().code,
            "MODEL_DISABLED"
        );
        change(&store, "second", Operation::Enable).unwrap();
        assert_eq!(store.resolve_model(None).unwrap().model, "jev-v3");
    }
}
