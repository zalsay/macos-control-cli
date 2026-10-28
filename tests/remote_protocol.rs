use copis_chrome::remote::protocol as remote_protocol;
use remote_protocol::{parse_envelope, validate_handshake};
use serde_json::json;

#[test]
fn rejects_untrusted_input_before_dispatch() {
    let good = json!({"remoteProtocol":1,"id":"req-1","session":"secret","sequence":1,"scope":"desktop","request":{"action":"windows"}});
    assert!(parse_envelope(&serde_json::to_vec(&good).unwrap()).is_ok());
    for request in [
        json!({"action":"daemon_stop"}),
        json!({"action":"permissions","request":true}),
        json!({"action":"select-file","connectionId":"c","path":"/tmp/a"}),
        json!({"action":"click-target","connectionId":"c","target":"a","jevKey":"secret"}),
        json!({"action":"windows","profileMarkerPath":"x"}),
    ] {
        let mut v = good.clone();
        v["request"] = request;
        assert!(parse_envelope(&serde_json::to_vec(&v).unwrap()).is_err());
    }
    for (field, value) in [
        ("remoteProtocol", json!(2)),
        ("scope", json!("other")),
        ("extra", json!(true)),
        ("sequence", json!(0)),
    ] {
        let mut v = good.clone();
        v[field] = value;
        assert!(parse_envelope(&serde_json::to_vec(&v).unwrap()).is_err());
    }
    assert!(parse_envelope(&vec![b' '; 65537]).is_err());
    assert!(validate_handshake("/mcc/v1", "mcc.remote.v1", Some("https://example.org")).is_err());
    assert!(validate_handshake("/mcc/v1", "mcc.remote.v1", None).is_ok());
    let parsed = parse_envelope(&serde_json::to_vec(&good).unwrap()).unwrap();
    assert!(!format!("{parsed:?}").contains("secret"));
}
#[test]
fn schema_manifest_is_bounded_and_strict() {
    use remote_protocol::ImageManifest;
    let m: ImageManifest = serde_json::from_value(json!({"requestId":"r","frameId":"f","mime":"image/jpeg","bytes":100,"sha256":"a".repeat(64)})).unwrap();
    assert!(m.validate().is_ok());
    let mut invalid = m.clone();
    invalid.bytes = 1_048_576;
    assert!(invalid.validate().is_err());
    assert!(serde_json::from_value::<ImageManifest>(json!({"requestId":"r","frameId":"f","mime":"image/jpeg","bytes":1,"sha256":"a".repeat(64),"path":"/etc/passwd"})).is_err());
}
#[test]
fn select_file_requires_host_policy_and_absolute_remote_path() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::protocol::{
        parse_envelope, parse_envelope_with_files, validate_action_with_files,
    };
    let v = json!({"remoteProtocol":1,"id":"r","session":"s","sequence":1,"scope":"desktop","request":{"action":"select-file","connectionId":"c","path":"/approved/file.pdf"}});
    let bytes = serde_json::to_vec(&v).unwrap();
    assert!(parse_envelope(&bytes).is_err());
    assert!(parse_envelope_with_files(&bytes, false).is_err());
    assert!(parse_envelope_with_files(&bytes, true).is_ok());
    for request in [
        json!({"action":"select-file","connectionId":"c","path":"relative"}),
        json!({"action":"select-file","connectionId":"c","path":"/approved/a","jevKey":"secret"}),
        json!({"action":"select-file","connectionId":"c","path":"/tmp/a\n"}),
    ] {
        assert!(validate_action_with_files(Scope::Desktop, &request, true).is_err());
    }
}
#[test]
fn select_file_query_syntax_does_not_enable_dispatch_policy() {
    let query = json!({"type":"query","session":"s","id":"r","sequence":1,"request":{"action":"select-file","connectionId":"c","path":"/host/allowed/file"}});
    let encoded = serde_json::to_vec(&query).unwrap();
    assert!(copis_chrome::remote::wire::parse_client_control(&encoded).is_ok());
    assert!(copis_chrome::remote::protocol::validate_action(
        copis_chrome::protocol::Scope::Desktop,
        &query["request"]
    )
    .is_err());
}
