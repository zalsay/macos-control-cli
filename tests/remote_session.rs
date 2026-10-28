use copis_chrome::protocol;
use copis_chrome::protocol::Scope;
use copis_chrome::remote::session::{Begin, Effect, SessionManager as ProductionSession, State};
use std::ops::{Deref, DerefMut};

// The test adapter keeps the per-socket ticket returned by the production API.
struct SessionManager {
    inner: ProductionSession,
    ticket: Option<u64>,
}
impl SessionManager {
    fn new(boot: &str, recovery: bool) -> protocol::Result<Self> {
        Ok(Self {
            inner: ProductionSession::new(boot, recovery)?,
            ticket: None,
        })
    }
    fn begin(
        &mut self,
        session: &str,
        seq: u64,
        id: &str,
        request: &[u8],
        now: u64,
    ) -> protocol::Result<Begin> {
        let (result, ticket) = self.inner.begin_rpc(session, seq, id, request, now)?;
        self.ticket = Some(ticket);
        Ok(result)
    }
    fn ack(&mut self, session: &str, seq: u64, id: &str, now: u64) -> protocol::Result<u64> {
        self.inner
            .ack_rpc(session, seq, id, self.ticket.unwrap_or(0), now)
    }
}
impl Deref for SessionManager {
    type Target = ProductionSession;
    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}
impl DerefMut for SessionManager {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.inner
    }
}
impl std::fmt::Debug for SessionManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.inner.fmt(f)
    }
}
#[test]
fn ownership_replay_and_loss_are_fail_closed() {
    let mut m = SessionManager::new("boot-a", false).unwrap();
    m.issue("secret-a", Scope::Desktop, 0).unwrap();
    m.issue("secret-b", Scope::Desktop, 0).unwrap();
    assert!(m.claim_control("secret-a", "conn-a", 0).is_ok());
    assert!(m.claim_control("secret-b", "conn-a", 0).is_err());
    m.register_frame("secret-a", "conn-a", "frame-a").unwrap();
    assert!(m.authorize_frame("secret-b", "conn-a", "frame-a").is_err());
    assert_eq!(
        m.begin("secret-a", 1, "id-1", br#"{"action":"status"}"#, 0)
            .unwrap(),
        Begin::Execute
    );
    assert!(m
        .begin("secret-a", 2, "id-2", br#"{"action":"status"}"#, 0)
        .is_err());
    m.complete("secret-a", 1, "id-1", br#"{"ok":true}"#, 1)
        .unwrap();
    let _ = m.ack("secret-a", 1, "id-1", 2).unwrap();
    assert_eq!(
        m.begin("secret-a", 1, "id-1", br#"{"action":"status"}"#, 3)
            .unwrap(),
        Begin::Cached(br#"{"ok":true}"#.to_vec())
    );
    let _ = m.ack("secret-a", 1, "id-1", 3).unwrap();
    assert!(m
        .begin("secret-a", 1, "id-1", br#"{"action":"windows"}"#, 3)
        .is_err());
    assert_eq!(m.lost("secret-a", 4).unwrap(), Effect::PauseOwnedOperation);
    assert_eq!(m.state(), State::CancellationUnconfirmed);
    m.acknowledge_pause().unwrap();
    assert_eq!(m.state(), State::LostPaused);
    assert!(m
        .begin(
            "secret-a",
            2,
            "id-2",
            br#"{"action":"type","connectionId":"conn-a","frameId":"frame-a","text":"x"}"#,
            5
        )
        .is_err());
    assert!(!format!("{m:?}").contains("secret-a"));
}
#[test]
fn readonly_loss_does_not_lock_and_idle_does() {
    let mut m = SessionManager::new("boot-a", false).unwrap();
    m.issue("read", Scope::Chrome, 0).unwrap();
    assert_eq!(m.lost("read", 1).unwrap(), Effect::None);
    assert_eq!(m.state(), State::Ready);
    m.issue("owner", Scope::Chrome, 1).unwrap();
    m.claim_control("owner", "conn", 1).unwrap();
    assert_eq!(m.expire(300_001).unwrap(), Effect::PauseOwnedOperation);
}
#[test]
fn evicted_replays_timeout_and_boot_checks() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Chrome, 0).unwrap();
    assert!(m.authorize("s", "other-boot", Scope::Chrome).is_err());
    assert!(m.authorize("s", "boot", Scope::Desktop).is_err());
    for seq in 1..=65 {
        let id = format!("id-{seq}");
        m.begin("s", seq, &id, br#"{"action":"status"}"#, seq)
            .unwrap();
        m.complete("s", seq, &id, br#"{"ok":true}"#, seq).unwrap();
        let p = m.ack("s", seq, &id, seq).unwrap();
        m.normal_close("s", seq, &id, p).unwrap();
    }
    assert!(m
        .begin("s", 1, "id-1", br#"{"action":"status"}"#, 70)
        .is_err());
    m.begin("s", 66, "id-66", br#"{"action":"status"}"#, 80)
        .unwrap();
    assert_eq!(m.expire(15080).unwrap(), Effect::None);
    assert_eq!(m.state(), State::Ready);
}
#[test]
fn owner_unacked_loss_rejects_late_completion_and_foreign_input() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("owner", Scope::Desktop, 0).unwrap();
    m.issue("other", Scope::Desktop, 0).unwrap();
    m.reserve_control("owner", 0).unwrap();
    m.claim_control("owner", "conn", 0).unwrap();
    let req = br#"{"action":"disconnect","connectionId":"conn"}"#;
    assert!(m.begin("other", 1, "stolen", req, 1).is_err());
    m.begin("owner", 1, "id", req, 1).unwrap();
    assert!(m.normal_close("owner", 1, "id", 1).is_err());
    assert_eq!(m.lost("owner", 2).unwrap(), Effect::PauseOwnedOperation);
    assert!(m.complete("owner", 1, "id", br#"{"ok":true}"#, 3).is_err());
    assert!(m.acknowledge_local_resume("owner", 4).is_err());
}

#[test]
fn close_is_one_time_and_bound_to_the_acknowledged_rpc() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Chrome, 0).unwrap();
    assert!(m.normal_close("s", 1, "id", 1).is_err());
    m.begin("s", 1, "id", br#"{"action":"status"}"#, 1).unwrap();
    m.complete("s", 1, "id", br#"{"ok":true}"#, 2).unwrap();
    assert!(m.normal_close("s", 1, "id", 1).is_err());
    let permit = m.ack("s", 1, "id", 3).unwrap();
    assert!(m.normal_close("s", 2, "id", permit).is_err());
    assert!(m.normal_close("s", 1, "wrong", permit).is_err());
    m.begin("s", 2, "new", br#"{"action":"status"}"#, 4)
        .unwrap();
    m.normal_close("s", 1, "id", permit).unwrap();
    assert!(m.normal_close("s", 1, "id", permit).is_err());
    assert!(m
        .begin("s", 3, "third", br#"{"action":"status"}"#, 4)
        .is_err());
    m.complete("s", 2, "new", br#"{"ok":true}"#, 5).unwrap();
}
#[test]
fn local_resume_keeps_lease_frames_and_old_sequence_invalid() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    m.claim_control("s", "conn", 0).unwrap();
    m.register_frame("s", "conn", "frame").unwrap();
    let input = br#"{"action":"type","connectionId":"conn","frameId":"frame","text":"secret"}"#;
    m.begin("s", 1, "old", input, 1).unwrap();
    m.lost("s", 2).unwrap();
    m.acknowledge_pause().unwrap();
    m.acknowledge_local_resume("s", 300_001).unwrap();
    m.authorize_frame("s", "conn", "frame").unwrap();
    assert_eq!(m.expire(300_002).unwrap(), Effect::None);
    assert!(m.begin("s", 1, "old", input, 300_002).is_err());
    assert_eq!(
        m.begin("s", 2, "new", input, 300_002).unwrap(),
        Begin::Execute
    );
}
#[test]
fn receipt_projection_excludes_arbitrary_payload_and_preserves_selection() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    m.claim_control("s", "conn", 0).unwrap();
    let req = br#"{"action":"click-target","connectionId":"conn","target":"password-value"}"#;
    m.begin("s", 1, "id", req, 1).unwrap();
    let response = br#"{"ok":true,"status":"click_sent","sent":true,"imagePath":"/private/frame","secret":"secret","selection":{"text":"Save","candidateId":"c1","privateKey":"bad","center":{"x":1,"y":2,"blob":"bad"}},"blob":"bad"}"#;
    m.complete("s", 1, "id", response, 2).unwrap();
    let permit = m.ack("s", 1, "id", 3).unwrap();
    m.normal_close("s", 1, "id", permit).unwrap();
    let Begin::Cached(bytes) = m.begin("s", 1, "id", req, 4).unwrap() else {
        panic!()
    };
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["selection"]["text"], "Save");
    assert!(value.get("imagePath").is_none() && value.get("blob").is_none());
    assert!(value["selection"].get("privateKey").is_none());
    assert!(value["selection"]["center"].get("blob").is_none());
    assert!(!format!("{m:?}").contains("password-value"));
}
#[test]
fn reservation_rollback_and_confirmed_disconnect_release_are_guarded() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("a", Scope::Desktop, 0).unwrap();
    m.issue("b", Scope::Desktop, 0).unwrap();
    m.reserve_control("a", 1).unwrap();
    m.rollback_reservation("a", None).unwrap();
    m.reserve_control("b", 2).unwrap();
    let connect = br#"{"action":"connect","windowId":1}"#;
    m.begin("b", 1, "failed", connect, 3).unwrap();
    m.complete(
        "b",
        1,
        "failed",
        br#"{"ok":false,"error":{"code":"NO_WINDOW","message":"window missing"}}"#,
        4,
    )
    .unwrap();
    let p = m.ack("b", 1, "failed", 5).unwrap();
    m.normal_close("b", 1, "failed", p).unwrap();
    m.rollback_reservation("b", Some((1, "failed"))).unwrap();
    m.reserve_control("a", 6).unwrap();
    m.claim_control("a", "conn", 6).unwrap();
    let disc = br#"{"action":"disconnect","connectionId":"conn"}"#;
    m.begin("a", 1, "disc", disc, 7).unwrap();
    m.complete("a", 1, "disc", br#"{"ok":true,"connected":false}"#, 8)
        .unwrap();
    let p = m.ack("a", 1, "disc", 9).unwrap();
    m.release_disconnected("a", 1, "disc").unwrap();
    m.normal_close("a", 1, "disc", p).unwrap();
    m.reserve_control("b", 10).unwrap();
    m.claim_control("b", "conn2", 10).unwrap();
    m.lost("b", 11).unwrap();
    m.acknowledge_pause().unwrap();
    assert!(m.rollback_reservation("b", None).is_err());
    assert!(m.release_disconnected("b", 1, "failed").is_err());
}
#[test]
fn paused_query_cached_is_readonly_and_checks_exact_identity() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("a", Scope::Desktop, 0).unwrap();
    m.issue("b", Scope::Desktop, 0).unwrap();
    m.claim_control("a", "conn", 0).unwrap();
    let req = br#"{"action":"status"}"#;
    m.begin("a", 1, "id", req, 1).unwrap();
    m.complete("a", 1, "id", br#"{"ok":true,"running":true}"#, 2)
        .unwrap();
    m.lost("a", 3).unwrap();
    m.acknowledge_pause().unwrap();
    let data = m.query_cached("a", 1, "id", req).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&data).unwrap()["running"],
        true
    );
    assert!(m.query_cached("b", 1, "id", req).is_err());
    assert!(m.query_cached("a", 1, "bad", req).is_err());
    assert!(m
        .query_cached("a", 1, "id", br#"{"action":"windows"}"#)
        .is_err());
    m.acknowledge_local_resume("a", 4).unwrap();
    assert_eq!(m.begin("a", 2, "next", req, 5).unwrap(), Begin::Execute);
}
#[test]
fn idle_readonly_sessions_expire_and_clock_never_moves_backwards() {
    let mut m = SessionManager::new("boot", false).unwrap();
    for n in 0..64 {
        m.issue(&format!("s{n}"), Scope::Chrome, 100).unwrap();
    }
    assert!(m.issue("overflow", Scope::Chrome, 100).is_err());
    assert!(m.expire(99).is_err());
    assert_eq!(m.expire(300_100).unwrap(), Effect::None);
    assert!(m.authorize("s0", "boot", Scope::Chrome).is_err());
    m.issue("new", Scope::Chrome, 300_100).unwrap();
    assert!(m.claim_control("new", "c", 300_099).is_err());
    m.claim_control("new", "c", 300_101).unwrap();
    assert!(m
        .begin("new", 1, "i", br#"{"action":"status"}"#, 300_100)
        .is_err());
    m.lost("new", 300_102).unwrap();
    assert!(m.expire(300_101).is_err());
}

#[test]
fn lost_rpc_cannot_ack_and_old_disconnect_cannot_release_new_lease() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    m.reserve_control("s", 1).unwrap();
    m.claim_control("s", "c1", 1).unwrap();
    let d = br#"{"action":"disconnect","connectionId":"c1"}"#;
    m.begin("s", 1, "d", d, 2).unwrap();
    m.complete("s", 1, "d", br#"{"ok":true,"connected":false}"#, 3)
        .unwrap();
    let p = m.ack("s", 1, "d", 4).unwrap();
    m.release_disconnected("s", 1, "d").unwrap();
    m.normal_close("s", 1, "d", p).unwrap();
    m.reserve_control("s", 5).unwrap();
    m.claim_control("s", "c2", 5).unwrap();
    assert!(m.release_disconnected("s", 1, "d").is_err());
    m.begin("s", 2, "x", br#"{"action":"status"}"#, 6).unwrap();
    m.complete("s", 2, "x", br#"{"ok":true}"#, 7).unwrap();
    m.lost("s", 8).unwrap();
    assert!(m.ack("s", 2, "x", 9).is_err());
}
#[test]
fn receipt_projection_rejects_payload_disguised_as_scalar_fields() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    m.begin("s", 1, "id", br#"{"action":"status"}"#, 1).unwrap();
    assert!(m
        .complete(
            "s",
            1,
            "id",
            br#"{"ok":"private key material","running":"image bytes","version":{"blob":"secret"}}"#,
            2
        )
        .is_err());
    assert!(m
        .query_cached("s", 1, "id", br#"{"action":"status"}"#)
        .is_err());
}
#[test]
fn repeated_rpc_old_ack_cannot_ack_new_transport() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Chrome, 0).unwrap();
    let r = br#"{"action":"status"}"#;
    let (_, first) = m.begin_rpc("s", 1, "id", r, 1).unwrap();
    m.complete("s", 1, "id", br#"{"ok":true}"#, 2).unwrap();
    let p = m.ack_rpc("s", 1, "id", first, 3).unwrap();
    m.normal_close("s", 1, "id", p).unwrap();
    let (cached, second) = m.begin_rpc("s", 1, "id", r, 4).unwrap();
    assert!(matches!(cached, Begin::Cached(_)));
    assert_ne!(first, second);
    assert!(m.ack_rpc("s", 1, "id", first, 5).is_err());
    m.ack_rpc("s", 1, "id", second, 5).unwrap();
}
#[test]
fn large_legal_ocr_and_window_metadata_are_cached_without_images() {
    use serde_json::json;
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    m.claim_control("s", "conn", 0).unwrap();
    let request = br#"{"action":"observe","connectionId":"conn"}"#;
    m.begin("s", 1, "observe", request, 1).unwrap();
    let item = json!({"text":"字".repeat(60),"bbox":{"x":0,"y":0,"width":20,"height":20},"center":{"x":10,"y":10},"confidence":0.9});
    let result = serde_json::to_vec(&json!({"ok":true,"connectionId":"conn","frameId":"f","imagePath":"/host/private.jpg","width":100,"height":100,"bounds":{"x":0,"y":0,"width":100,"height":100},"coordinateSpace":"frame-pixels","imageTransform":"crop-only","captureBackend":"screencapture","ocr":{"status":"ok","items":vec![item;128],"truncated":false}})).unwrap();
    assert!(result.len() > 16384 && result.len() < 65536);
    m.complete("s", 1, "observe", &result, 2).unwrap();
    let projected: serde_json::Value =
        serde_json::from_slice(&m.query_cached("s", 1, "observe", request).unwrap()).unwrap();
    assert_eq!(projected["ocr"]["items"].as_array().unwrap().len(), 128);
    assert_eq!(projected["coordinateSpace"], "frame-pixels");
    assert!(projected.get("imagePath").is_none());
    let p = m.ack("s", 1, "observe", 3).unwrap();
    m.normal_close("s", 1, "observe", p).unwrap();
    let windows = br#"{"action":"windows"}"#;
    m.begin("s", 2, "windows", windows, 4).unwrap();
    let entry = json!({"windowId":3,"pid":5,"title":"window".repeat(30),"bundleId":"com.example.app","appName":"App","bounds":{"x":0,"y":0,"width":800,"height":600}});
    let raw = serde_json::to_vec(&json!({"ok":true,"windows":vec![entry;100]})).unwrap();
    assert!(raw.len() > 16384 && raw.len() < 65536);
    m.complete("s", 2, "windows", &raw, 5).unwrap();
    let value: serde_json::Value =
        serde_json::from_slice(&m.query_cached("s", 2, "windows", windows).unwrap()).unwrap();
    assert_eq!(value["windows"].as_array().unwrap().len(), 100);
}
#[test]
fn oversized_completion_is_rejected_without_ack_or_cached_success() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Chrome, 0).unwrap();
    let req = br#"{"action":"status"}"#;
    m.begin("s", 1, "id", req, 1).unwrap();
    assert!(m.complete("s", 1, "id", &vec![b' '; 65536], 2).is_err());
    assert!(m.query_cached("s", 1, "id", req).is_err());
    assert!(m.ack("s", 1, "id", 2).is_err());
    assert!(m.begin("s", 2, "next", req, 2).is_err());
}

#[test]
fn original_user_paused_error_survives_cached_roundtrip() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    let req = br#"{"action":"status"}"#;
    m.begin("s", 1, "id", req, 1).unwrap();
    let original = protocol::response_for(
        Err(protocol::Error::new("USER_PAUSED", "raw secret")),
        Scope::Desktop,
    );
    m.complete("s", 1, "id", &serde_json::to_vec(&original).unwrap(), 2)
        .unwrap();
    let cached: serde_json::Value =
        serde_json::from_slice(&m.query_cached("s", 1, "id", req).unwrap()).unwrap();
    assert_eq!(cached, original);
    let error: protocol::Error = serde_json::from_value(cached["error"].clone()).unwrap();
    assert_eq!(error.code, "FOCUS_LOST");
    assert!(error.message.contains("已暂停"));
    assert_eq!(cached["error"]["reason"], "USER_PAUSED");
}

struct RealChromeStartFixture;
impl copis_chrome::service::Native for RealChromeStartFixture {
    fn request(&mut self, request: serde_json::Value) -> protocol::Result<serde_json::Value> {
        use serde_json::json;
        let window = json!({"windowId":42,"pid":123,"bundleId":"com.google.Chrome","title":"test","bounds":{"x":0.0,"y":25.0,"width":800.0,"height":1000.0}});
        Ok(match request["action"].as_str().unwrap() {
            "permissions" => json!({"screenRecording":true,"accessibility":true}),
            "chrome-start" => {
                std::fs::write(
                    request["profileMarkerPath"].as_str().unwrap(),
                    "synthetic marker",
                )
                .unwrap();
                json!({"window":window,"layout":{"maxWidthPx":1600,"scale":2},"profile":{"name":"mcc","directory":"Profile 2","path":"/profiles/Profile 2"}})
            }
            "windows" => json!({"windows":[window]}),
            "window" => json!({"window":window}),
            "cancel" => json!({"cancelled":true}),
            _ => panic!("unexpected synthetic native request"),
        })
    }
}
#[test]
fn original_service_chrome_start_and_null_status_survive_roundtrip() {
    use serde_json::json;
    let mut svc = copis_chrome::service::Service::new(RealChromeStartFixture, std::env::temp_dir());
    let status = protocol::response_for(svc.execute(json!({"action":"status"})), Scope::Chrome);
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Chrome, 0).unwrap();
    let r = br#"{"action":"status"}"#;
    m.begin("s", 1, "status", r, 1).unwrap();
    m.complete("s", 1, "status", &serde_json::to_vec(&status).unwrap(), 2)
        .unwrap();
    let cached: serde_json::Value =
        serde_json::from_slice(&m.query_cached("s", 1, "status", r).unwrap()).unwrap();
    assert_eq!(cached, status);
    let p = m.ack("s", 1, "status", 3).unwrap();
    m.normal_close("s", 1, "status", p).unwrap();
    let original = protocol::response_for(
        svc.execute(json!({"action":"chrome-start","profile":"mcc","maxWidthPx":1600})),
        Scope::Chrome,
    );
    assert_eq!(original["profile"]["directory"], "Profile 2");
    m.reserve_control("s", 4).unwrap();
    let r = br#"{"action":"chrome-start","profile":"mcc"}"#;
    m.begin("s", 2, "start", r, 5).unwrap();
    m.complete("s", 2, "start", &serde_json::to_vec(&original).unwrap(), 6)
        .unwrap();
    let cached: serde_json::Value =
        serde_json::from_slice(&m.query_cached("s", 2, "start", r).unwrap()).unwrap();
    assert_eq!(cached, original);
}
#[test]
fn malformed_known_shapes_rejected_not_projected_to_empty() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Desktop, 0).unwrap();
    let req = br#"{"action":"windows"}"#;
    m.begin("s", 1, "id", req, 1).unwrap();
    assert!(m
        .complete("s", 1, "id", br#"{"ok":true,"windows":[null]}"#, 2)
        .is_err());
    assert!(m.query_cached("s", 1, "id", req).is_err());
}
#[test]
fn dynamic_error_diagnostics_are_replaced_with_controlled_error_message() {
    let mut m = SessionManager::new("boot", false).unwrap();
    m.issue("s", Scope::Chrome, 0).unwrap();
    let req = br#"{"action":"status"}"#;
    m.begin("s", 1, "id", req, 1).unwrap();
    let response = protocol::response_for(
        Err(protocol::Error::new(
            "HTTP_ERROR",
            "https://host/secret?token=abc",
        )),
        Scope::Chrome,
    );
    m.complete("s", 1, "id", &serde_json::to_vec(&response).unwrap(), 2)
        .unwrap();
    let result: serde_json::Value =
        serde_json::from_slice(&m.query_cached("s", 1, "id", req).unwrap()).unwrap();
    let error: protocol::Error = serde_json::from_value(result["error"].clone()).unwrap();
    assert_eq!(error.code, "HTTP_ERROR");
    assert!(!error.message.contains("token"));
    assert_eq!(error.message, "远程操作失败，请查看错误代码");
}
#[test]
fn select_file_execution_requires_local_host_policy_and_caches_no_path() {
    let req = br#"{"action":"select-file","connectionId":"conn","path":"/approved/file.pdf"}"#;
    let mut denied = ProductionSession::new("boot", false).unwrap();
    denied.issue("s", Scope::Desktop, 0).unwrap();
    denied.claim_control("s", "conn", 0).unwrap();
    assert!(denied.begin_rpc("s", 1, "r", req, 1).is_err());
    let mut allowed = ProductionSession::new("boot", false).unwrap();
    allowed.set_allow_files(true).unwrap();
    allowed.issue("s", Scope::Desktop, 0).unwrap();
    assert!(allowed.set_allow_files(false).is_err());
    allowed.claim_control("s", "conn", 0).unwrap();
    let (_, ticket) = allowed.begin_rpc("s", 1, "r", req, 1).unwrap();
    allowed.complete("s",1,"r",br#"{"ok":true,"selected":true,"dialogClosed":true,"connectionId":"conn","path":"/approved/file.pdf"}"#,2).unwrap();
    let p = allowed.ack_rpc("s", 1, "r", ticket, 3).unwrap();
    allowed.normal_close("s", 1, "r", p).unwrap();
    let receipt: serde_json::Value =
        serde_json::from_slice(&allowed.query_cached("s", 1, "r", req).unwrap()).unwrap();
    assert_eq!(receipt["selected"], true);
    assert_eq!(receipt["dialogClosed"], true);
    assert!(receipt.get("path").is_none());
}
