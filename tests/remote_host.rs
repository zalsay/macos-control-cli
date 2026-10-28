use copis_chrome::protocol::Scope;
use copis_chrome::remote::wire::{parse_client_control, ClientControl};
use serde_json::json;

#[test]
fn control_messages_are_bounded_strict_and_secrets_redacted() {
    let session = json!({"type":"session","remoteProtocol":1,"scope":"desktop","session":"private-secret","bootId":"boot"});
    let parsed = parse_client_control(&serde_json::to_vec(&session).unwrap()).unwrap();
    assert!(matches!(
        parsed,
        ClientControl::Session {
            scope: Scope::Desktop,
            ..
        }
    ));
    assert!(!format!("{parsed:?}").contains("private-secret"));
    for value in [
        json!({"type":"session","remoteProtocol":2,"scope":"desktop","session":null,"bootId":null}),
        json!({"type":"session","remoteProtocol":1,"scope":"desktop","session":"private","bootId":null}),
        json!({"type":"ack","id":"x","sequence":0}),
        json!({"type":"ack","id":"x","sequence":1,"ticket":9}),
        json!({"type":"query","session":"secret","id":"x","sequence":1,"request":{"action":"permissions","request":true}}),
    ] {
        assert!(
            parse_client_control(&serde_json::to_vec(&value).unwrap()).is_err(),
            "{value}"
        );
    }
    assert!(parse_client_control(&vec![b' '; 65537]).is_err());
}

use copis_chrome::remote::session::{Effect, SessionManager};
fn ack(
    m: &mut SessionManager,
    s: &str,
    seq: u64,
    id: &str,
    now: u64,
) -> copis_chrome::protocol::Result<u64> {
    m.ack_rpc(s, seq, id, seq, now)
}
#[test]
fn abandoned_acked_sockets_are_reclaimed_without_canceling_newer_flight() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    m.claim_control("s", "conn", 0).unwrap();
    let req = br#"{"action":"status"}"#;
    for seq in 1..=70 {
        let id = format!("r{seq}");
        m.begin_rpc("s", seq, &id, req, seq * 3).unwrap();
        m.complete("s", seq, &id, br#"{"ok":true}"#, seq * 3 + 1)
            .unwrap();
        let permit = ack(&mut m, "s", seq, &id, seq * 3 + 2).unwrap();
        // Once the next invocation begins, the old socket cannot cancel it.
        if seq == 1 {
            m.begin_rpc("s", 2, "r2", req, seq * 3 + 2).unwrap();
            assert_eq!(
                m.abandon_acked_transport("s", seq, &id, permit, seq * 3 + 2)
                    .unwrap(),
                Effect::None
            );
            m.complete("s", 2, "r2", br#"{"ok":true}"#, seq * 3 + 2)
                .unwrap();
            let p = ack(&mut m, "s", 2, "r2", seq * 3 + 2).unwrap();
            m.normal_close("s", 2, "r2", p).unwrap();
        } else if seq > 2 {
            m.normal_close("s", seq, &id, permit).unwrap();
        }
        if seq == 1 {
            break;
        }
    }
    for seq in 3..=72 {
        let id = format!("r{seq}");
        m.begin_rpc("s", seq, &id, req, seq * 3).unwrap();
        m.complete("s", seq, &id, br#"{"ok":true}"#, seq * 3 + 1)
            .unwrap();
        let p = ack(&mut m, "s", seq, &id, seq * 3 + 2).unwrap();
        m.normal_close("s", seq, &id, p).unwrap();
    }
    m.begin_rpc("s", 73, "r73", req, 220).unwrap();
    m.complete("s", 73, "r73", br#"{"ok":true}"#, 221).unwrap();
    let p = ack(&mut m, "s", 73, "r73", 222).unwrap();
    assert_eq!(
        m.abandon_acked_transport("s", 73, "r73", p, 223).unwrap(),
        Effect::PauseOwnedOperation
    );
    assert!(m.normal_close("s", 73, "r73", p).is_err());
}
#[test]
fn handshake_rejects_origin_and_bad_bearer_before_upgrade() {
    use copis_chrome::remote::{credentials, wire};
    use std::{
        net::{TcpListener, TcpStream},
        os::unix::fs::PermissionsExt,
        sync::Arc,
        time::Duration,
    };
    use tungstenite::{
        client::IntoClientRequest,
        http::{header, HeaderValue},
    };
    let parent = std::env::temp_dir().join(format!(
        "mcc-wire-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &parent.join("tls")).unwrap();
    let token_file = parent.join("token");
    credentials::initialize_token(&token_file).unwrap();
    let server = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let client = credentials::client_config(Some(&cert.ca_cert)).unwrap();
    let token = credentials::read_token(&token_file).unwrap();
    for (bad_token, origin) in [(false, false), (true, false), (false, true)] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let config = Arc::clone(&server);
        let p = token_file.clone();
        let thread = std::thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            socket
                .set_write_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let tls =
                rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), socket);
            let token = credentials::read_token(&p).unwrap();
            wire::accept_authenticated(tls, &token).is_ok()
        });
        let tcp = TcpStream::connect(addr).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
        let conn = rustls::ClientConnection::new(
            Arc::clone(&client),
            rustls::pki_types::ServerName::try_from("127.0.0.1")
                .unwrap()
                .to_owned(),
        )
        .unwrap();
        let tls = rustls::StreamOwned::new(conn, tcp);
        let mut request = format!("wss://{addr}/mcc/v1")
            .into_client_request()
            .unwrap();
        request.headers_mut().insert(
            header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static("mcc.remote.v1"),
        );
        let mut auth = HeaderValue::from_str(&format!(
            "Bearer {}",
            if bad_token {
                "0".repeat(64)
            } else {
                token.header_value()
            }
        ))
        .unwrap();
        auth.set_sensitive(true);
        request.headers_mut().insert(header::AUTHORIZATION, auth);
        if origin {
            request.headers_mut().insert(
                header::ORIGIN,
                HeaderValue::from_static("https://example.test"),
            );
        }
        let result = tungstenite::client(request, tls);
        assert_eq!(result.is_ok(), !bad_token && !origin);
        assert_eq!(thread.join().unwrap(), !bad_token && !origin);
    }
    std::fs::remove_dir_all(parent).unwrap();
}
#[test]
fn session_control_requires_explicit_session_and_boot_fields() {
    for value in [
        json!({"type":"session","remoteProtocol":1,"scope":"desktop","session":null}),
        json!({"type":"session","remoteProtocol":1,"scope":"desktop","bootId":null}),
    ] {
        assert!(parse_client_control(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}
#[test]
fn abandoned_readonly_close_permits_do_not_exhaust_after_64() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Chrome, 0).unwrap();
    for seq in 1..=70 {
        let id = format!("id{seq}");
        let (_, ticket) = m
            .begin_rpc("s", seq, &id, br#"{"action":"status"}"#, seq * 3)
            .unwrap();
        m.complete("s", seq, &id, br#"{"ok":true}"#, seq * 3 + 1)
            .unwrap();
        let permit = m.ack_rpc("s", seq, &id, ticket, seq * 3 + 2).unwrap();
        assert_eq!(
            m.abandon_acked_transport("s", seq, &id, permit, seq * 3 + 2)
                .unwrap(),
            Effect::None
        );
    }
}
#[test]
fn tls_upgrade_rejects_oversized_http_headers_before_websocket() {
    use copis_chrome::remote::{credentials, wire};
    use std::{
        io::Write,
        net::{TcpListener, TcpStream},
        os::unix::fs::PermissionsExt,
        time::Duration,
    };
    let parent = std::env::temp_dir().join(format!(
        "mcc-header-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &parent.join("tls")).unwrap();
    let token_path = parent.join("token");
    credentials::initialize_token(&token_path).unwrap();
    let token = credentials::read_token(&token_path).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let token_file = token_path.clone();
    let thread = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
        let tls = rustls::StreamOwned::new(rustls::ServerConnection::new(server).unwrap(), tcp);
        wire::accept_authenticated(tls, &credentials::read_token(&token_file).unwrap()).is_err()
    });
    let tcp = TcpStream::connect(addr).unwrap();
    tcp.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
    let conn = rustls::ClientConnection::new(
        credentials::client_config(Some(&cert.ca_cert)).unwrap(),
        rustls::pki_types::ServerName::try_from("127.0.0.1")
            .unwrap()
            .to_owned(),
    )
    .unwrap();
    let mut tls = rustls::StreamOwned::new(conn, tcp);
    let request=format!("GET /mcc/v1 HTTP/1.1\r\nHost: {addr}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: mcc.remote.v1\r\nAuthorization: Bearer {}\r\nX-Filler: {}\r\n\r\n",token.header_value(),"a".repeat(9000));
    let _ = tls.write_all(request.as_bytes());
    let _ = tls.flush();
    assert!(thread.join().unwrap());
    std::fs::remove_dir_all(parent).unwrap();
}
#[test]
fn admission_limits_pending_authenticated_and_failure_budgets() {
    use copis_chrome::remote::wire::Admission;
    use std::net::IpAddr;
    let gate = Admission::new();
    let ip: IpAddr = "127.0.0.1".parse().unwrap();
    let mut pending: Vec<_> = (0..8).map(|_| gate.enter(ip, 0).unwrap()).collect();
    assert!(gate.enter(ip, 0).is_err());
    for lease in pending.iter_mut().take(4) {
        lease.authenticate().unwrap();
    }
    assert!(pending[4].authenticate().is_err());
    pending.clear();
    for _ in 0..10 {
        let mut lease = gate.enter(ip, 1).unwrap();
        lease.reject(1).unwrap();
    }
    assert!(gate.enter(ip, 2).is_err());
    assert!(gate.enter(ip, 60_002).is_ok());
    assert!(gate.enter(ip, 60_001).is_err());
}
#[test]
fn request_budget_is_burst_limited_and_table_bounded() {
    use copis_chrome::remote::wire::RequestBudget;
    let mut budget = RequestBudget::new();
    for _ in 0..20 {
        budget.consume("session", 0).unwrap();
    }
    assert!(budget.consume("session", 0).is_err());
    budget.consume("session", 100).unwrap();
    assert!(budget.consume("session", 100).is_err());
    for n in 0..63 {
        budget.consume(&format!("session-{n}"), 100).unwrap();
    }
    assert!(budget.consume("overflow", 100).is_err());
    budget.consume("overflow", 300_101).unwrap();
    assert!(budget.consume("other", 300_100).is_err());
    assert!(!format!("{budget:?}").contains("session-0"));
}
#[test]
fn lost_paused_owner_can_only_read_without_resuming_lease() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("owner", Scope::Desktop, 0).unwrap();
    m.issue("other", Scope::Desktop, 0).unwrap();
    m.claim_control("owner", "conn", 0).unwrap();
    m.register_frame("owner", "conn", "frame").unwrap();
    m.lost("owner", 1).unwrap();
    m.acknowledge_pause().unwrap();
    let status = br#"{"action":"status"}"#;
    assert!(m.begin_rpc("other", 1, "stolen", status, 2).is_err());
    let (_, ticket) = m.begin_rpc("owner", 1, "status", status, 2).unwrap();
    m.complete("owner", 1, "status", br#"{"ok":true,"running":true}"#, 3)
        .unwrap();
    let p = m.ack_rpc("owner", 1, "status", ticket, 4).unwrap();
    m.normal_close("owner", 1, "status", p).unwrap();
    assert_eq!(m.state(), copis_chrome::remote::session::State::LostPaused);
    let observe = br#"{"action":"observe","connectionId":"conn"}"#;
    let (_, ticket) = m.begin_rpc("owner", 2, "observe", observe, 5).unwrap();
    m.complete(
        "owner",
        2,
        "observe",
        br#"{"ok":true,"connectionId":"conn","frameId":"frame","width":100,"height":100}"#,
        6,
    )
    .unwrap();
    let p = m.ack_rpc("owner", 2, "observe", ticket, 7).unwrap();
    m.normal_close("owner", 2, "observe", p).unwrap();
    assert!(m
        .begin_rpc(
            "owner",
            3,
            "input",
            br#"{"action":"type","connectionId":"conn","frameId":"frame","text":"x"}"#,
            8
        )
        .is_err());
    assert_eq!(m.state(), copis_chrome::remote::session::State::LostPaused);
    m.require_recovery();
    assert!(m.begin_rpc("owner", 3, "status2", status, 9).is_err());
}
#[test]
fn paused_readonly_disconnect_does_not_unlock_or_escalate_pause() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("owner", Scope::Desktop, 0).unwrap();
    m.claim_control("owner", "conn", 0).unwrap();
    m.lost("owner", 1).unwrap();
    m.acknowledge_pause().unwrap();
    let (_, ticket) = m
        .begin_rpc("owner", 1, "status", br#"{"action":"status"}"#, 2)
        .unwrap();
    assert_eq!(
        m.lost_rpc("owner", 1, "status", ticket, 3).unwrap(),
        Effect::None
    );
    assert_eq!(m.state(), copis_chrome::remote::session::State::LostPaused);
    assert!(m
        .begin_rpc("owner", 1, "status", br#"{"action":"status"}"#, 4)
        .is_err());
}
#[test]
fn slow_tls_trickle_cannot_extend_absolute_handshake_deadline() {
    use copis_chrome::remote::{credentials, wire};
    use std::{
        io::Write,
        net::{TcpListener, TcpStream},
        os::unix::fs::PermissionsExt,
        time::{Duration, Instant},
    };
    let root = std::env::temp_dir().join(format!(
        "mcc-slow-{}",
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
    let started = Instant::now();
    let t = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        wire::accept_tls_authenticated(
            tcp,
            config,
            &credentials::read_token(&p).unwrap(),
            Duration::from_secs(1),
        )
        .is_err()
    });
    let mut tcp = TcpStream::connect(addr).unwrap();
    for b in [0x16u8, 0x03, 0x03, 0x00, 0xff, 0x01, 0x02, 0x03] {
        if tcp.write_all(&[b]).is_err() {
            break;
        }
        std::thread::sleep(Duration::from_millis(240));
    }
    assert!(t.join().unwrap());
    assert!(started.elapsed() < Duration::from_millis(2200));
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn wss_partial_text_can_yield_for_heartbeat_and_continue() {
    use copis_chrome::remote::{credentials, wire};
    use std::{
        io::Write,
        net::TcpListener,
        os::unix::fs::PermissionsExt,
        sync::mpsc,
        time::{Duration, Instant},
    };
    use tungstenite::Message;
    let root = std::env::temp_dir().join(format!(
        "mcc-partial-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cert = credentials::initialize_tls(&["127.0.0.1".into()], &root.join("tls")).unwrap();
    let token_path = root.join("token");
    credentials::initialize_token(&token_path).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel();
    let config = credentials::server_config(&cert.certificate, &cert.private_key).unwrap();
    let p = token_path.clone();
    let server = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        let mut ws = wire::accept_tls_authenticated(
            tcp,
            config,
            &credentials::read_token(&p).unwrap(),
            Duration::from_secs(2),
        )
        .unwrap();
        let stream = ws.get_mut().inner_mut();
        stream.write_all(&[0x81, 0x04, b't']).unwrap();
        stream.flush().unwrap();
        rx.recv().unwrap();
        stream.write_all(b"est").unwrap();
        stream.flush().unwrap();
    });
    let mut ws = wire::connect_authenticated(
        &format!("wss://{addr}/mcc/v1"),
        credentials::client_config(Some(&cert.ca_cert)).unwrap(),
        &credentials::read_token(&token_path).unwrap(),
    )
    .unwrap();
    ws.get_mut()
        .inner_mut()
        .sock
        .set_deadline(Instant::now() + Duration::from_millis(250));
    assert!(matches!(ws.read(), Err(tungstenite::Error::Io(_))));
    ws.get_mut()
        .inner_mut()
        .sock
        .set_deadline(Instant::now() + Duration::from_secs(2));
    ws.send(Message::Ping(Vec::new().into())).unwrap();
    tx.send(()).unwrap();
    assert_eq!(ws.read().unwrap().to_text().unwrap(), "test");
    server.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn accepted_nonblocking_socket_is_normalized_before_tls_handshake() {
    use copis_chrome::remote::{credentials, wire};
    use std::{net::TcpListener, os::unix::fs::PermissionsExt, time::Duration};
    let root = std::env::temp_dir().join(format!(
        "mcc-nonblock-{}",
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
    let t = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_nonblocking(true).unwrap();
        wire::accept_tls_authenticated(
            tcp,
            config,
            &credentials::read_token(&p).unwrap(),
            Duration::from_secs(3),
        )
        .is_ok()
    });
    let result = wire::connect_authenticated(
        &format!("wss://{addr}/mcc/v1"),
        credentials::client_config(Some(&cert.ca_cert)).unwrap(),
        &credentials::read_token(&token).unwrap(),
    );
    assert!(result.is_ok());
    assert!(t.join().unwrap());
    std::fs::remove_dir_all(root).unwrap();
}
