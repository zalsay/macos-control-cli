use copis_chrome::{
    args::{parse_for_scope, Command},
    protocol::Scope,
    remote::protocol::validate_action_with_files,
};
use serde_json::json;

#[test]
fn client_accepts_the_opt_in_file_capability_without_allowing_arbitrary_hello_fields() {
    use copis_chrome::remote::wire::parse_hello;
    let mut hello = json!({"remoteProtocol":1,"version":"0.3.6","scope":"desktop",
        "bootId":"boot","capabilities":["remote-v1","firefox.x11.v1","remote.files.v1"]});
    assert!(parse_hello(
        &serde_json::to_vec(&hello).unwrap(),
        "0.3.6",
        Scope::Desktop
    )
    .is_ok());
    hello["capabilities"] = json!(["unknown.capability"]);
    assert!(parse_hello(
        &serde_json::to_vec(&hello).unwrap(),
        "0.3.6",
        Scope::Desktop
    )
    .is_err());
}

#[test]
fn received_bytes_are_verified_scoped_and_removed_on_disconnect() {
    use copis_chrome::remote::files::{sha256, FileStore, Manifest};
    let root = std::env::temp_dir().join(format!(
        "mcc-files-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    let mut store = FileStore::open(&root).unwrap();
    let bytes = b"multipart bytes \0\xff with Unicode filename";
    let manifest = Manifest {
        name: "报告 with spaces.bin".into(),
        bytes: bytes.len() as u64,
        sha256: sha256(bytes),
    };
    let mut pending = store.begin("session", "conn", manifest.clone()).unwrap();
    pending.push(&bytes[..3]).unwrap();
    pending.push(&bytes[3..]).unwrap();
    let receipt = store.commit(pending).unwrap();
    let id = receipt["fileId"].as_str().unwrap();
    let path = store.resolve("session", "conn", id).unwrap();
    assert_eq!(path.file_name().unwrap(), "报告 with spaces.bin");
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    assert!(store.resolve("other", "conn", id).is_err());
    assert!(store.resolve("session", "other", id).is_err());
    std::fs::write(&path, b"tampered").unwrap();
    assert!(store.resolve("session", "conn", id).is_err());
    store.release("session", "conn");
    assert!(!path.exists());
    drop(store);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn incomplete_corrupted_and_symlink_replaced_uploads_are_never_selected() {
    use copis_chrome::remote::files::{sha256, FileStore, Manifest};
    let root = std::env::temp_dir().join(format!(
        "mcc-files-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    let mut store = FileStore::open(&root).unwrap();
    let manifest = Manifest {
        name: "safe.txt".into(),
        bytes: 3,
        sha256: sha256(b"abc"),
    };
    {
        let mut partial = store.begin("s", "c", manifest.clone()).unwrap();
        partial.push(b"a").unwrap();
    }
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1); // only the store lock
    let mut wrong = store.begin("s", "c", manifest.clone()).unwrap();
    wrong.push(b"bad").unwrap();
    assert!(store.commit(wrong).is_err());
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
    let mut too_long = store.begin("s", "c", manifest.clone()).unwrap();
    assert!(too_long.push(b"abcd").is_err());
    drop(too_long);
    let mut valid = store.begin("s", "c", manifest).unwrap();
    valid.push(b"abc").unwrap();
    let result = store.commit(valid).unwrap();
    let id = result["fileId"].as_str().unwrap();
    let path = store.resolve("s", "c", id).unwrap();
    std::fs::remove_file(&path).unwrap();
    std::os::unix::fs::symlink("/etc/hosts", &path).unwrap();
    assert!(store.resolve("s", "c", id).is_err());
    store.release("s", "c");
    assert!(std::fs::symlink_metadata(&path)
        .unwrap()
        .file_type()
        .is_symlink());
    drop(store);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn remote_cli_accepts_client_file_and_file_id_without_confusing_host_paths() {
    let command = parse_for_scope(
        [
            "--remote",
            "wss://127.0.0.1:8765",
            "--token-file",
            "/private/token",
            "file",
            "put",
            "--connection",
            "conn",
            "--local",
            "/private/report.pdf",
        ]
        .map(String::from),
        Scope::Desktop,
    );
    assert!(
        matches!(command, Ok(Command::Remote { .. })),
        "file put must be a remote command"
    );
    let selected = parse_for_scope(
        [
            "select-file",
            "--connection",
            "conn",
            "--file-id",
            "file-123",
        ]
        .map(String::from),
        Scope::Desktop,
    );
    assert!(
        selected.is_ok(),
        "select-file must accept an opaque uploaded file ID"
    );
    assert!(parse_for_scope(
        [
            "select-file",
            "--connection",
            "conn",
            "--file-id",
            "file-123",
            "--path",
            "/private/a",
        ]
        .map(String::from),
        Scope::Desktop
    )
    .is_err());
}

#[test]
fn upload_manifest_is_bounded_and_cannot_set_destination_paths() {
    let request = json!({"action":"file-put","connectionId":"conn","name":"报告 with space.pdf","bytes":3,"sha256":"a".repeat(64)});
    assert!(validate_action_with_files(Scope::Desktop, &request, true).is_ok());
    assert!(validate_action_with_files(Scope::Desktop, &request, false).is_err());
    for (key, value) in [
        ("name", json!("../escape")),
        ("name", json!("/absolute")),
        ("name", json!("bad\nname")),
        ("name", json!("..")),
        ("name", json!(".part")),
        ("name", json!("nested\\file.txt")),
        ("bytes", json!(67_108_865u64)),
        ("sha256", json!("not-a-hash")),
        ("path", json!("/arbitrary/server/path")),
    ] {
        let mut bad = request.clone();
        bad[key] = value;
        assert!(
            validate_action_with_files(Scope::Desktop, &bad, true).is_err(),
            "accepted {key}"
        );
    }
    assert!(validate_action_with_files(
        Scope::Desktop,
        &json!({"action":"select-file","connectionId":"conn","fileId":"file-123"}),
        true
    )
    .is_ok());
}

#[test]
fn empty_files_publish_and_crash_leftovers_still_count_toward_quota() {
    use copis_chrome::remote::files::{sha256, FileStore, Manifest};
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!(
        "mcc-files-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    let mut store = FileStore::open(&root).unwrap();
    let empty = Manifest {
        name: "empty.txt".into(),
        bytes: 0,
        sha256: sha256(b""),
    };
    let pending = store.begin("s", "c", empty.clone()).unwrap();
    let receipt = store.commit(pending).unwrap();
    let id = receipt["fileId"].as_str().unwrap();
    assert!(std::fs::read(store.resolve("s", "c", id).unwrap())
        .unwrap()
        .is_empty());
    store.release("s", "c");
    for index in 0..4 {
        let directory = root.join(format!("crash-{index}"));
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let file = std::fs::File::create(directory.join("leftover.bin")).unwrap();
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .unwrap();
        file.set_len(64 * 1024 * 1024).unwrap();
    }
    drop(store);
    let store = FileStore::open(&root).unwrap();
    assert_eq!(
        store
            .begin(
                "s",
                "c",
                Manifest {
                    name: "one-byte".into(),
                    bytes: 1,
                    sha256: sha256(b"a")
                }
            )
            .err()
            .unwrap()
            .code,
        "FILE_QUOTA_EXCEEDED"
    );
    drop(store);
    std::fs::remove_dir_all(root).unwrap();
}
