use copis_chrome::remote::wire::{parse_server_control, ServerControl};
use serde_json::json;
#[test]
fn server_messages_are_strict_bound_and_manifest_is_bound_to_request() {
    let valid = json!({"type":"result","id":"request1","sequence":1,"response":{"ok":true,"frameId":"frame1"},"image":{"requestId":"request1","frameId":"frame1","mime":"image/jpeg","bytes":2,"sha256":"a".repeat(64)}});
    assert!(matches!(
        parse_server_control(&serde_json::to_vec(&valid).unwrap()).unwrap(),
        ServerControl::Result { .. }
    ));
    for v in [
        json!({"type":"acked","id":"x","sequence":0}),
        json!({"type":"session","session":"secret","bootId":"boot","state":"ready","token":"bad"}),
        json!({"type":"result","id":"x","sequence":1,"response":null,"image":null}),
        json!({"type":"result","id":"x","sequence":1,"response":{"frameId":"frame"},"image":{"requestId":"wrong","frameId":"frame","mime":"image/jpeg","bytes":2,"sha256":"a".repeat(64)}}),
    ] {
        assert!(parse_server_control(&serde_json::to_vec(&v).unwrap()).is_err());
    }
    assert!(parse_server_control(&vec![b' '; 65537]).is_err());
}
#[test]
fn client_tls_authentication_and_wrong_ca_use_loopback_without_fallback() {
    use copis_chrome::remote::{credentials, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, sync::Arc, time::Duration};
    let parent = std::env::temp_dir().join(format!(
        "mcc-client-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let good = credentials::initialize_tls(&["127.0.0.1".into()], &parent.join("good")).unwrap();
    let wrong = credentials::initialize_tls(&["127.0.0.1".into()], &parent.join("wrong")).unwrap();
    let tokenfile = parent.join("token");
    credentials::initialize_token(&tokenfile).unwrap();
    let token = credentials::read_token(&tokenfile).unwrap();
    let server = credentials::server_config(&good.certificate, &good.private_key).unwrap();
    for correct in [true, false] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = Arc::clone(&server);
        let p = tokenfile.clone();
        let thread = std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            tcp.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
            let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(server).unwrap(), tcp);
            wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).is_ok()
        });
        let config = credentials::client_config(Some(if correct {
            &good.ca_cert
        } else {
            &wrong.ca_cert
        }))
        .unwrap();
        assert_eq!(
            wire::connect_authenticated(&format!("wss://{addr}/mcc/v1"), config, &token).is_ok(),
            correct
        );
        assert_eq!(thread.join().unwrap(), correct);
    }
    for bad in [
        "ws://127.0.0.1:1/mcc/v1",
        "wss://user:pw@127.0.0.1:1/mcc/v1",
        "wss://127.0.0.1:1/other",
        "wss://127.0.0.1:1/mcc/v1?token=x",
    ] {
        assert!(wire::connect_authenticated(
            bad,
            credentials::client_config(Some(&good.ca_cert)).unwrap(),
            &token
        )
        .is_err());
    }
    std::fs::remove_dir_all(parent).unwrap();
}
#[test]
fn hello_must_match_version_scope_and_have_bounded_capabilities() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::wire::parse_hello;
    let good = json!({"remoteProtocol":1,"version":"0.3.3","scope":"desktop","bootId":"boot","capabilities":["pause-v1"]});
    let encoded = serde_json::to_vec(&good).unwrap();
    assert!(parse_hello(&encoded, "0.3.3", Scope::Desktop).is_ok());
    assert!(parse_hello(&encoded, "0.3.4", Scope::Desktop).is_err());
    assert!(parse_hello(&encoded, "0.3.3", Scope::Chrome).is_err());
    let mut bad = good.clone();
    bad["bootId"] = json!("bad boot");
    assert!(parse_hello(&serde_json::to_vec(&bad).unwrap(), "0.3.3", Scope::Desktop).is_err());
    let mut bad = good;
    bad["capabilities"] = json!(vec!["a"; 65]);
    assert!(parse_hello(&serde_json::to_vec(&bad).unwrap(), "0.3.3", Scope::Desktop).is_err());
}
#[test]
fn client_reuses_private_session_and_monotonic_sequence_across_invocations() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, sync::Arc, time::Duration};
    use tungstenite::Message;
    let parent = std::env::temp_dir().join(format!(
        "mcc-client-e2e-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &parent.join("tls")).unwrap();
    let token = parent.join("token");
    credentials::initialize_token(&token).unwrap();
    let server = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let token_file = token.clone();
    let t = std::thread::spawn(move || {
        for expected in 1..=2u64 {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
            tcp.set_write_timeout(Some(Duration::from_secs(4))).unwrap();
            let tls = rustls::StreamOwned::new(
                rustls::ServerConnection::new(Arc::clone(&server)).unwrap(),
                tcp,
            );
            let mut ws =
                wire::accept_authenticated(tls, &credentials::read_token(&token_file).unwrap())
                    .unwrap();
            ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"desktop","bootId":"boot","capabilities":[]}).to_string().into())).unwrap();
            let session: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(
                session["session"],
                if expected == 1 {
                    serde_json::Value::Null
                } else {
                    json!("sid")
                }
            );
            ws.send(Message::Text(
                json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let request: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(request["sequence"], expected);
            let id = request["id"].as_str().unwrap().to_owned();
            ws.send(Message::Text(json!({"type":"result","id":id,"sequence":expected,"response":{"ok":true,"protocolVersion":1,"scope":"desktop","running":true},"image":null}).to_string().into())).unwrap();
            let ack: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(ack["type"], "ack");
            assert_eq!(ack["id"], id);
            ws.send(Message::Text(
                json!({"type":"acked","id":id,"sequence":expected})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let _ = ws.read();
        }
    });
    let opts = ClientOptions {
        url: format!("wss://{addr}/mcc/v1"),
        ca_cert: Some(cert.ca_cert.clone()),
        token_file: token,
        state_dir: Some(parent.join("client")),
    };
    for _ in 0..2 {
        let result = client::run(
            opts.clone(),
            json!({"action":"status"}),
            None,
            Scope::Desktop,
        )
        .unwrap();
        assert_eq!(result["running"], true);
    }
    t.join().unwrap();
    std::fs::remove_dir_all(parent).unwrap();
}
#[test]
fn symlinked_state_root_is_rejected_without_writing_through_it() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions};
    use std::os::unix::fs::{symlink, PermissionsExt};
    let parent = std::env::temp_dir().join(format!(
        "mcc-client-symlink-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &parent.join("tls")).unwrap();
    let token = parent.join("token");
    credentials::initialize_token(&token).unwrap();
    let target = parent.join("victim");
    std::fs::create_dir(&target).unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o700)).unwrap();
    let link = parent.join("state-link");
    symlink(&target, &link).unwrap();
    let options = ClientOptions {
        url: "wss://127.0.0.1:9/mcc/v1".into(),
        ca_cert: Some(cert.ca_cert),
        token_file: token,
        state_dir: Some(link),
    };
    assert!(client::run(options, json!({"action":"status"}), None, Scope::Chrome).is_err());
    assert_eq!(std::fs::read_dir(&target).unwrap().count(), 0);
    std::fs::remove_dir_all(parent).unwrap();
}
#[test]
fn ipv6_wss_uses_ip_san_without_brackets_in_server_name() {
    use copis_chrome::remote::{credentials, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, time::Duration};
    let Ok(listener) = TcpListener::bind("[::1]:0") else {
        eprintln!("SKIP: IPv6 loopback unavailable");
        return;
    };
    let parent = std::env::temp_dir().join(format!(
        "mcc-ipv6-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["::1".into()], &parent.join("tls")).unwrap();
    let token = parent.join("token");
    credentials::initialize_token(&token).unwrap();
    let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let addr = listener.local_addr().unwrap();
    let p = token.clone();
    let t = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
        let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), tcp);
        wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).is_ok()
    });
    let ws = wire::connect_authenticated(
        &format!("wss://{addr}/mcc/v1"),
        credentials::client_config(Some(&cert.ca_cert)).unwrap(),
        &credentials::read_token(&token).unwrap(),
    );
    assert!(ws.is_ok());
    drop(ws);
    assert!(t.join().unwrap());
    std::fs::remove_dir_all(parent).unwrap();
}
#[test]
fn invalid_result_is_not_acked_or_reported_as_success() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, time::Duration};
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-invalid-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let p = token.clone();
    let thread = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), tcp);
        let mut ws =
            wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).unwrap();
        ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":"boot","capabilities":[]}).to_string().into())).unwrap();
        let _ = ws.read().unwrap();
        ws.send(Message::Text(
            json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                .to_string()
                .into(),
        ))
        .unwrap();
        let req: serde_json::Value =
            serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
        ws.send(Message::Text(json!({"type":"result","id":req["id"],"sequence":req["sequence"],"response":{"ok":true,"protocolVersion":999},"image":null}).to_string().into())).unwrap();
        match ws.read() {
            Ok(Message::Text(v)) => v.contains("\"type\":\"ack\""),
            _ => false,
        }
    });
    let options = ClientOptions {
        url: format!("wss://{addr}/mcc/v1"),
        ca_cert: Some(cert.ca_cert),
        token_file: token,
        state_dir: Some(root.join("state")),
    };
    assert!(client::run(options, json!({"action":"status"}), None, Scope::Chrome).is_err());
    assert!(!thread.join().unwrap());
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn host_boot_change_does_not_replace_cached_session() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, sync::Arc, time::Duration};
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-boot-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let cfg = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let p = token.clone();
    let t = std::thread::spawn(move || {
        for boot in ["boot1", "boot2"] {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            let tls = rustls::StreamOwned::new(
                rustls::ServerConnection::new(Arc::clone(&cfg)).unwrap(),
                tcp,
            );
            let mut ws =
                wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).unwrap();
            ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":boot,"capabilities":[]}).to_string().into())).unwrap();
            if boot == "boot2" {
                assert!(!matches!(ws.read(), Ok(Message::Text(_))));
                break;
            }
            let _ = ws.read().unwrap();
            ws.send(Message::Text(
                json!({"type":"session","session":"sid","bootId":boot,"state":"ready"})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let req: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            ws.send(Message::Text(json!({"type":"result","id":req["id"],"sequence":req["sequence"],"response":{"ok":true,"protocolVersion":1,"running":true},"image":null}).to_string().into())).unwrap();
            let _ = ws.read().unwrap();
            ws.send(Message::Text(
                json!({"type":"acked","id":req["id"],"sequence":req["sequence"]})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let _ = ws.read();
        }
    });
    let opts = ClientOptions {
        url: format!("wss://{addr}/mcc/v1"),
        ca_cert: Some(cert.ca_cert),
        token_file: token,
        state_dir: Some(root.join("state")),
    };
    client::run(
        opts.clone(),
        json!({"action":"status"}),
        None,
        Scope::Chrome,
    )
    .unwrap();
    let error = client::run(opts, json!({"action":"status"}), None, Scope::Chrome).unwrap_err();
    assert_eq!(error.code, "RECOVERY_REQUIRED");
    t.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn client_has_one_absolute_tls_http_handshake_deadline() {
    use copis_chrome::remote::{credentials, wire};
    use std::{
        io::{Read, Write},
        net::TcpListener,
        os::unix::fs::PermissionsExt,
        time::{Duration, Instant},
    };
    let root = std::env::temp_dir().join(format!(
        "mcc-client-slow-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let server = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let t = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(6))).unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(1))).unwrap();
        let mut tls = rustls::StreamOwned::new(rustls::ServerConnection::new(server).unwrap(), tcp);
        let mut buf = [0u8; 4096];
        let _ = tls.read(&mut buf);
        for byte in b"HTTP/1.1 101 Switching Protocols\r\n" {
            if tls.write_all(&[*byte]).and_then(|_| tls.flush()).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    });
    let start = Instant::now();
    let result = wire::connect_authenticated(
        &format!("wss://{addr}/mcc/v1"),
        credentials::client_config(Some(&cert.ca_cert)).unwrap(),
        &credentials::read_token(&token).unwrap(),
    );
    assert!(result.is_err());
    assert!(start.elapsed() < Duration::from_millis(6500));
    t.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn public_state_root_is_rejected_before_creating_endpoint_cache() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions};
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!(
        "mcc-root-mode-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let state = root.join("state");
    std::fs::create_dir(&state).unwrap();
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o755)).unwrap();
    let opts = ClientOptions {
        url: "wss://127.0.0.1:9/mcc/v1".into(),
        ca_cert: Some(cert.ca_cert),
        token_file: token,
        state_dir: Some(state.clone()),
    };
    assert!(client::run(opts, json!({"action":"status"}), None, Scope::Chrome).is_err());
    assert_eq!(std::fs::read_dir(state).unwrap().count(), 0);
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn application_deadline_stops_fragment_trickle_inside_read_exact() {
    use copis_chrome::remote::wire::DeadlineTcp;
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        time::{Duration, Instant},
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let writer = std::thread::spawn(move || {
        let (mut tcp, _) = listener.accept().unwrap();
        for _ in 0..12 {
            if tcp.write_all(b"x").is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(180));
        }
    });
    let tcp = TcpStream::connect(addr).unwrap();
    let start = Instant::now();
    let mut io = DeadlineTcp::new(tcp, start + Duration::from_secs(5));
    io.clear_deadline();
    io.set_deadline(start + Duration::from_millis(700));
    let mut payload = [0; 12];
    assert!(io.read_exact(&mut payload).is_err());
    assert!(start.elapsed() < Duration::from_millis(1400));
    drop(io);
    writer.join().unwrap();
}
#[test]
fn hello_and_session_text_drips_cannot_extend_application_deadlines() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{
        io::Write,
        net::TcpListener,
        os::unix::fs::PermissionsExt,
        time::{Duration, Instant},
    };
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-stage-slow-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    for stage in ["hello", "session"] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
        let p = token.clone();
        let t = std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(8))).unwrap();
            tcp.set_write_timeout(Some(Duration::from_secs(1))).unwrap();
            let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), tcp);
            let mut ws =
                wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).unwrap();
            let hello=json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":"boot","capabilities":[]}).to_string();
            let payload = if stage == "session" {
                ws.send(Message::Text(hello.into())).unwrap();
                let _ = ws.read().unwrap();
                json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                    .to_string()
            } else {
                hello
            };
            assert!(payload.len() < 126);
            let tls = ws.get_mut().inner_mut();
            tls.write_all(&[0x81, payload.len() as u8]).unwrap();
            tls.flush().unwrap();
            for b in payload.bytes() {
                if tls.write_all(&[b]).and_then(|_| tls.flush()).is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(220));
            }
        });
        let opts = ClientOptions {
            url: format!("wss://{addr}/mcc/v1"),
            ca_cert: Some(cert.ca_cert.clone()),
            token_file: token.clone(),
            state_dir: Some(root.join(format!("state-{stage}"))),
        };
        let start = Instant::now();
        assert!(client::run(opts, json!({"action":"status"}), None, Scope::Chrome).is_err());
        assert!(start.elapsed() < Duration::from_millis(6500));
        t.join().unwrap();
    }
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn image_transfer_validates_manifest_and_never_returns_partial_file() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, time::Duration};
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-client-image-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let jpeg = vec![
        0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0x04, 0xb0, 0x06, 0x40, 1, 1, 0x11, 0, 0xff, 0xda, 0, 8,
        1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9,
    ];
    for truncated in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
        let p = token.clone();
        let payload = jpeg.clone();
        let server = std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
            let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), tcp);
            let mut ws =
                wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).unwrap();
            ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":"boot","capabilities":[]}).to_string().into())).unwrap();
            let _ = ws.read().unwrap();
            ws.send(Message::Text(
                json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let request: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            let hash: String = ring::digest::digest(&ring::digest::SHA256, &payload)
                .as_ref()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            ws.send(Message::Text(json!({"type":"result","id":request["id"],"sequence":request["sequence"],"response":{"ok":true,"protocolVersion":1,"connectionId":"conn","frameId":"frame","width":1600,"height":1200},"image":{"requestId":request["id"],"frameId":"frame","mime":"image/jpeg","bytes":payload.len(),"sha256":hash}}).to_string().into())).unwrap();
            let n = payload.len() / 2;
            ws.send(Message::Binary(payload[..n].to_vec().into()))
                .unwrap();
            if truncated {
                return;
            }
            ws.send(Message::Binary(payload[n..].to_vec().into()))
                .unwrap();
            let ack: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            ws.send(Message::Text(
                json!({"type":"acked","id":ack["id"],"sequence":ack["sequence"]})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let _ = ws.read();
        });
        let output = root.join(if truncated {
            "partial.jpg"
        } else {
            "image.jpg"
        });
        let opts = ClientOptions {
            url: format!("wss://{addr}/mcc/v1"),
            ca_cert: Some(cert.ca_cert.clone()),
            token_file: token.clone(),
            state_dir: Some(root.join(format!("state-{truncated}"))),
        };
        let result = client::run(
            opts,
            json!({"action":"observe","connectionId":"conn"}),
            Some(output.clone()),
            Scope::Chrome,
        );
        if truncated {
            assert_eq!(result.unwrap_err().code, "REMOTE_OUTCOME_UNKNOWN");
            assert!(!output.exists());
        } else {
            assert_eq!(result.unwrap()["imagePath"], output.to_str().unwrap());
            assert_eq!(std::fs::read(&output).unwrap(), jpeg);
        }
        server.join().unwrap();
    }
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn automatic_images_are_bounded_and_never_delete_unregistered_or_replaced_files() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{
        net::TcpListener,
        os::unix::fs::{symlink, PermissionsExt},
        sync::Arc,
        time::Duration,
    };
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-image-cache-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let p = token.clone();
    let jpeg = vec![
        0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0x04, 0xb0, 0x06, 0x40, 1, 1, 0x11, 0, 0xff, 0xda, 0, 8,
        1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9,
    ];
    let payload = jpeg.clone();
    let server = std::thread::spawn(move || {
        for n in 0..36 {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
            let tls = rustls::StreamOwned::new(
                rustls::ServerConnection::new(Arc::clone(&config)).unwrap(),
                tcp,
            );
            let mut ws =
                wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).unwrap();
            ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":"boot","capabilities":[]}).to_string().into())).unwrap();
            let _ = ws.read().unwrap();
            ws.send(Message::Text(
                json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let request: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            let frame = format!("frame-{n}");
            let hash: String = ring::digest::digest(&ring::digest::SHA256, &payload)
                .as_ref()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            ws.send(Message::Text(json!({"type":"result","id":request["id"],"sequence":request["sequence"],"response":{"ok":true,"protocolVersion":1,"connectionId":"conn","frameId":frame,"width":1600,"height":1200},"image":{"requestId":request["id"],"frameId":frame,"mime":"image/jpeg","bytes":payload.len(),"sha256":hash}}).to_string().into())).unwrap();
            ws.send(Message::Binary(payload.clone().into())).unwrap();
            let ack: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            ws.send(Message::Text(
                json!({"type":"acked","id":ack["id"],"sequence":ack["sequence"]})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let _ = ws.read();
        }
    });
    let opts = ClientOptions {
        url: format!("wss://{addr}/mcc/v1"),
        ca_cert: Some(cert.ca_cert),
        token_file: token,
        state_dir: Some(root.join("state")),
    };
    let request = json!({"action":"observe","connectionId":"conn"});
    let first = client::run(opts.clone(), request.clone(), None, Scope::Chrome).unwrap();
    let first_path = std::path::PathBuf::from(first["imagePath"].as_str().unwrap());
    let cache = first_path.parent().unwrap().to_path_buf();
    let unrelated = cache.join("user.jpg");
    std::fs::write(&unrelated, b"unrelated").unwrap();
    let victim = root.join("victim");
    std::fs::write(&victim, b"victim").unwrap();
    std::fs::remove_file(&first_path).unwrap();
    symlink(&victim, &first_path).unwrap();
    let explicit = cache.join("explicit.jpg");
    client::run(
        opts.clone(),
        request.clone(),
        Some(explicit.clone()),
        Scope::Chrome,
    )
    .unwrap();
    let mut latest = None;
    let mut edited = None;
    let mut linked = None;
    for n in 0..34 {
        let value = client::run(opts.clone(), request.clone(), None, Scope::Chrome).unwrap();
        let path = std::path::PathBuf::from(value["imagePath"].as_str().unwrap());
        if n == 0 {
            std::fs::write(&path, b"edited-by-user").unwrap();
            edited = Some(path.clone());
        } else if n == 1 {
            std::fs::remove_file(&path).unwrap();
            std::fs::hard_link(&victim, &path).unwrap();
            linked = Some(path.clone());
        }
        latest = Some(path);
    }
    assert!(latest.unwrap().exists());
    let edited = edited.unwrap();
    assert_eq!(std::fs::read(&edited).unwrap(), b"edited-by-user");
    assert_eq!(std::fs::read(&victim).unwrap(), b"victim");
    let linked = linked.unwrap();
    assert_eq!(std::fs::read(&linked).unwrap(), b"victim");
    assert!(std::fs::symlink_metadata(&first_path)
        .unwrap()
        .file_type()
        .is_symlink());
    assert_eq!(std::fs::read(&unrelated).unwrap(), b"unrelated");
    assert_eq!(std::fs::read(&explicit).unwrap(), jpeg);
    let state: serde_json::Value =
        serde_json::from_slice(&std::fs::read(cache.join("session.json")).unwrap()).unwrap();
    assert_eq!(state["autoImages"].as_array().unwrap().len(), 32);
    assert_eq!(
        std::fs::read_dir(&cache)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.path().extension().is_some_and(|s| s == "jpg")
                && e.file_type().unwrap().is_file()
                && e.file_name() != "user.jpg"
                && e.file_name() != "explicit.jpg"
                && e.path() != edited
                && e.path() != linked)
            .count(),
        32
    );
    server.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn ack_failure_never_deletes_a_replaced_explicit_output() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, time::Duration};
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-ack-replace-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let output = root.join("output.jpg");
    let target = output.clone();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let p = token.clone();
    let server = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
        let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), tcp);
        let mut ws =
            wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).unwrap();
        ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":"boot","capabilities":[]}).to_string().into())).unwrap();
        let _ = ws.read().unwrap();
        ws.send(Message::Text(
            json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                .to_string()
                .into(),
        ))
        .unwrap();
        let request: serde_json::Value =
            serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
        let bytes = vec![
            0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0x04, 0xb0, 0x06, 0x40, 1, 1, 0x11, 0, 0xff, 0xda, 0,
            8, 1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9,
        ];
        let hash: String = ring::digest::digest(&ring::digest::SHA256, &bytes)
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        ws.send(Message::Text(json!({"type":"result","id":request["id"],"sequence":request["sequence"],"response":{"ok":true,"protocolVersion":1,"connectionId":"conn","frameId":"frame","width":1600,"height":1200},"image":{"requestId":request["id"],"frameId":"frame","mime":"image/jpeg","bytes":bytes.len(),"sha256":hash}}).to_string().into())).unwrap();
        ws.send(Message::Binary(bytes.into())).unwrap();
        let _ack = ws.read().unwrap();
        std::fs::remove_file(&target).unwrap();
        std::fs::write(&target, b"user-replacement").unwrap();
    });
    let opts = ClientOptions {
        url: format!("wss://{addr}/mcc/v1"),
        ca_cert: Some(cert.ca_cert),
        token_file: token,
        state_dir: Some(root.join("state")),
    };
    let result = client::run(
        opts,
        json!({"action":"observe","connectionId":"conn"}),
        Some(output.clone()),
        Scope::Chrome,
    );
    assert_eq!(result.unwrap_err().code, "REMOTE_OUTCOME_UNKNOWN");
    server.join().unwrap();
    assert_eq!(std::fs::read(output).unwrap(), b"user-replacement");
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn lost_acked_auto_image_is_removed_and_not_registered() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, time::Duration};
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-ack-auto-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let p = token.clone();
    let server = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
        let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), tcp);
        let mut ws =
            wire::accept_authenticated(tls, &credentials::read_token(&p).unwrap()).unwrap();
        ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":"boot","capabilities":[]}).to_string().into())).unwrap();
        let _ = ws.read().unwrap();
        ws.send(Message::Text(
            json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                .to_string()
                .into(),
        ))
        .unwrap();
        let req: serde_json::Value =
            serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
        let bytes = vec![
            0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0x04, 0xb0, 0x06, 0x40, 1, 1, 0x11, 0, 0xff, 0xda, 0,
            8, 1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9,
        ];
        let hash: String = ring::digest::digest(&ring::digest::SHA256, &bytes)
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        ws.send(Message::Text(json!({"type":"result","id":req["id"],"sequence":req["sequence"],"response":{"ok":true,"protocolVersion":1,"connectionId":"conn","frameId":"frame","width":1600,"height":1200},"image":{"requestId":req["id"],"frameId":"frame","mime":"image/jpeg","bytes":bytes.len(),"sha256":hash}}).to_string().into())).unwrap();
        ws.send(Message::Binary(bytes.into())).unwrap();
        let _ = ws.read().unwrap();
    });
    let state_root = root.join("state");
    let opts = ClientOptions {
        url: format!("wss://{addr}/mcc/v1"),
        ca_cert: Some(cert.ca_cert),
        token_file: token,
        state_dir: Some(state_root.clone()),
    };
    assert_eq!(
        client::run(
            opts,
            json!({"action":"observe","connectionId":"conn"}),
            None,
            Scope::Chrome
        )
        .unwrap_err()
        .code,
        "REMOTE_OUTCOME_UNKNOWN"
    );
    server.join().unwrap();
    let endpoint = std::fs::read_dir(state_root)
        .unwrap()
        .filter_map(Result::ok)
        .find(|e| e.file_type().unwrap().is_dir())
        .unwrap()
        .path();
    assert_eq!(
        std::fs::read_dir(&endpoint)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.path().extension().is_some_and(|x| x == "jpg"))
            .count(),
        0
    );
    let state: serde_json::Value =
        serde_json::from_slice(&std::fs::read(endpoint.join("session.json")).unwrap()).unwrap();
    assert_eq!(state["autoImages"].as_array().unwrap().len(), 0);
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn existing_output_and_symlink_fail_before_network_or_credentials() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, options::ClientOptions};
    use std::os::unix::fs::{symlink, PermissionsExt};
    let root = std::env::temp_dir().join(format!(
        "mcc-output-preflight-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let file = root.join("existing.jpg");
    std::fs::write(&file, b"unchanged").unwrap();
    let link = root.join("link.jpg");
    symlink(root.join("missing-target"), &link).unwrap();
    let options = ClientOptions {
        url: "wss://127.0.0.1:9/mcc/v1".into(),
        ca_cert: None,
        token_file: root.join("missing-token"),
        state_dir: Some(root.join("state")),
    };
    for output in [&file, &link] {
        let err = client::run(
            options.clone(),
            json!({"action":"observe","connectionId":"conn"}),
            Some(output.clone()),
            Scope::Chrome,
        )
        .unwrap_err();
        assert_eq!(err.code, "OUTPUT_EXISTS");
    }
    assert_eq!(std::fs::read(file).unwrap(), b"unchanged");
    assert!(std::fs::symlink_metadata(link)
        .unwrap()
        .file_type()
        .is_symlink());
    assert!(!root.join("state").exists());
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn output_race_is_acked_but_corrupt_image_is_not() {
    use copis_chrome::protocol::Scope;
    use copis_chrome::remote::{client, credentials, options::ClientOptions, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, time::Duration};
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-output-race-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token = root.join("token");
    credentials::initialize_token(&token).unwrap();
    let image = vec![
        0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0x04, 0xb0, 0x06, 0x40, 1, 1, 0x11, 0, 0xff, 0xda, 0, 8,
        1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9,
    ];
    for corrupt in [false, true] {
        let out = root.join(format!("out-{corrupt}.jpg"));
        let target = out.clone();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let tls = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
        let p = token.clone();
        let original = image.clone();
        let server = std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
            let stream = rustls::StreamOwned::new(rustls::ServerConnection::new(tls).unwrap(), tcp);
            let mut ws =
                wire::accept_authenticated(stream, &credentials::read_token(&p).unwrap()).unwrap();
            ws.send(Message::Text(json!({"remoteProtocol":1,"version":env!("CARGO_PKG_VERSION"),"scope":"chrome","bootId":"boot","capabilities":[]}).to_string().into())).unwrap();
            let _ = ws.read().unwrap();
            ws.send(Message::Text(
                json!({"type":"session","session":"sid","bootId":"boot","state":"ready"})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let req: serde_json::Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            std::fs::write(&target, b"existing-race").unwrap();
            let hash: String = ring::digest::digest(&ring::digest::SHA256, &original)
                .as_ref()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            ws.send(Message::Text(json!({"type":"result","id":req["id"],"sequence":req["sequence"],"response":{"ok":true,"protocolVersion":1,"connectionId":"conn","frameId":"f","width":1600,"height":1200},"image":{"requestId":req["id"],"frameId":"f","mime":"image/jpeg","bytes":original.len(),"sha256":hash}}).to_string().into())).unwrap();
            let mut sent = original;
            if corrupt {
                sent[10] ^= 1;
            }
            ws.send(Message::Binary(sent.into())).unwrap();
            match ws.read() {
                Ok(Message::Text(text)) => {
                    let ack: serde_json::Value = serde_json::from_str(&text).unwrap();
                    assert_eq!(ack["type"], "ack");
                    ws.send(Message::Text(
                        json!({"type":"acked","id":ack["id"],"sequence":ack["sequence"]})
                            .to_string()
                            .into(),
                    ))
                    .unwrap();
                    assert!(
                        matches!(ws.read(), Ok(Message::Close(_))),
                        "ACKed collision must close normally without another action"
                    );
                    true
                }
                _ => false,
            }
        });
        let opts = ClientOptions {
            url: format!("wss://{addr}/mcc/v1"),
            ca_cert: Some(cert.ca_cert.clone()),
            token_file: token.clone(),
            state_dir: Some(root.join(format!("state-{corrupt}"))),
        };
        let err = client::run(
            opts,
            json!({"action":"observe","connectionId":"conn"}),
            Some(out.clone()),
            Scope::Chrome,
        )
        .unwrap_err();
        assert_eq!(
            err.code,
            if corrupt {
                "REMOTE_OUTCOME_UNKNOWN"
            } else {
                "OUTPUT_EXISTS"
            }
        );
        assert_eq!(server.join().unwrap(), !corrupt);
        assert_eq!(std::fs::read(out).unwrap(), b"existing-race");
    }
    std::fs::remove_dir_all(root).unwrap();
}
