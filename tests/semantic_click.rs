use copis_chrome::jev::Decision;
use copis_chrome::protocol::{Error, Result, Scope};
use copis_chrome::service::{Native, Service};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

struct Fixture {
    path: PathBuf,
    native: Arc<Mutex<Vec<Value>>>,
    decisions: Arc<Mutex<Vec<Value>>>,
    service: Service<FakeNative>,
    id: String,
    mutate_window: Arc<AtomicBool>,
}
struct FakeNative {
    calls: Arc<Mutex<Vec<Value>>>,
    ocr: Value,
    click_error: Option<&'static str>,
    metadata: bool,
    window_changed: Arc<AtomicBool>,
}
fn window() -> Value {
    json!({"windowId":42,"pid":123,"bundleId":"com.google.Chrome","bounds":{"x":100,"y":50,"width":400,"height":300},"title":"private title"})
}
fn ocr() -> Value {
    json!({"status":"ok","truncated":false,"items":[{"text":"保存","bbox":{"x":10,"y":20,"width":100,"height":40},"center":{"x":60,"y":40},"confidence":0.99}]})
}
fn response() -> Value {
    json!({"model":"typesafe/jev-1.13-20260917","answers":{"target":{"type":"choice","choice":"t0","confidence":0.98,"probabilities":{"t0":0.99,"none":0.01}}}})
}
impl Native for FakeNative {
    fn request(&mut self, request: Value) -> Result<Value> {
        self.calls.lock().unwrap().push(request.clone());
        match request["action"].as_str().unwrap() {
            "permissions" => Ok(json!({"screenRecording":true,"accessibility":true})),
            "windows" => Ok(json!({"windows":[window()]})),
            "window" => {
                let mut current = window();
                if self.window_changed.load(Ordering::Acquire) {
                    current["bounds"]["width"] = json!(450);
                }
                Ok(json!({"window":current}))
            }
            "observe" => {
                let path = request["imagePath"].as_str().unwrap();
                std::fs::write(path, [0xff, 0xd8, 0xff, 0xd9]).unwrap();
                let mut result = json!({"imagePath":path,"width":800,"height":600,"bounds":window()["bounds"],"capturedAtMs":1,"ocr":self.ocr,"coordinateSpace":"frame-pixels","imageTransform":"crop-only"});
                if self.metadata {
                    result["inputEpoch"] = json!(4);
                    result["observedAtUptime"] = json!(123.5);
                }
                Ok(result)
            }
            "click" => {
                if let Some(code) = self.click_error {
                    Err(Error::new(code, "fixture rejection"))
                } else {
                    Ok(json!({"sent":true}))
                }
            }
            "cancel" => Ok(json!({"cancelled":true})),
            _ => panic!("unexpected request {request}"),
        }
    }
}
struct FakeDecision {
    calls: Arc<Mutex<Vec<Value>>>,
    reply: Result<Value>,
    mutate_window: Arc<AtomicBool>,
    window_changed: Arc<AtomicBool>,
}
impl Decision for FakeDecision {
    fn decide(&mut self, endpoint: &str, key: &str, request: &Value) -> Result<Value> {
        assert_eq!(endpoint, "https://router.example/decisions");
        assert_eq!(key, "test-private-key");
        self.calls.lock().unwrap().push(request.clone());
        if self.mutate_window.load(Ordering::Acquire) {
            self.window_changed.store(true, Ordering::Release);
        }
        self.reply.clone()
    }
}
impl Fixture {
    fn new(
        ocr: Value,
        reply: Result<Value>,
        click_error: Option<&'static str>,
        metadata: bool,
    ) -> Self {
        let path = std::env::temp_dir().join(format!(
            "mcc-semantic-{}",
            copis_chrome::protocol::random_id().unwrap()
        ));
        std::fs::create_dir(&path).unwrap();
        let native = Arc::new(Mutex::new(Vec::new()));
        let decisions = Arc::new(Mutex::new(Vec::new()));
        let window_changed = Arc::new(AtomicBool::new(false));
        let mutate_window = Arc::new(AtomicBool::new(false));
        let mut service = Service::with_scope(
            FakeNative {
                calls: native.clone(),
                ocr,
                click_error,
                metadata,
                window_changed: window_changed.clone(),
            },
            path.clone(),
            Scope::Desktop,
        )
        .with_decider(Box::new(FakeDecision {
            calls: decisions.clone(),
            reply,
            mutate_window: mutate_window.clone(),
            window_changed,
        }));
        let id = service
            .execute(json!({"action":"connect","windowId":42}))
            .unwrap()["connectionId"]
            .as_str()
            .unwrap()
            .to_owned();
        Self {
            path,
            native,
            decisions,
            service,
            id,
            mutate_window,
        }
    }
    fn click(&mut self) -> Result<Value> {
        self.service.execute(json!({"action":"click-target","jevProtocol":"decisions-v1","jevUrl":"https://router.example/decisions","jevModel":"typesafe/jev-1.13","connectionId":self.id,"target":"保存按钮","jevKey":"test-private-key"}))
    }
    fn clicks(&self) -> usize {
        self.native
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r["action"] == "click")
            .count()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self
            .service
            .execute(json!({"action":"disconnect","connectionId":self.id}));
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
#[test]
fn semantic_click_reuses_original_input_conversion_and_reports_only_dispatch() {
    let mut f = Fixture::new(ocr(), Ok(response()), None, true);
    let receipt = f.click().unwrap();
    assert_eq!(f.clicks(), 1);
    assert_eq!(receipt["status"], "click_sent");
    assert_eq!(receipt["sent"], true);
    assert_eq!(receipt["effectVerified"], false);
    assert_eq!(receipt["selection"]["candidateId"], "t0");
    assert!(receipt["timingMs"]["total"].is_u64());
    let calls = f.native.lock().unwrap().clone();
    let click = calls.iter().find(|r| r["action"] == "click").unwrap();
    assert_eq!(click["screenX"], 130.0);
    assert_eq!(click["screenY"], 70.0);
    assert_eq!(click["clickCount"], 1);
    assert!(
        click.get("textGuard").is_none(),
        "semantic click must not add an OCR guard to original input"
    );
    assert_eq!(calls.iter().filter(|r| r["action"] == "observe").count(), 1);
    assert!(receipt["timingMs"]["click"].is_u64());
    assert!(receipt["timingMs"].get("guardedClick").is_none());
    assert!(!serde_json::to_string(&*calls)
        .unwrap()
        .contains("test-private-key"));
    assert!(!receipt.to_string().contains("test-private-key"));
    let decisions = f.decisions.lock().unwrap();
    assert_eq!(decisions.len(), 1);
    let cloud = decisions[0].to_string();
    for removed in [
        "bbox",
        "center",
        "width",
        "height",
        "exists",
        "noul",
        "ocrTruncated",
    ] {
        assert!(!cloud.contains(removed));
    }
    assert_eq!(
        decisions[0]["questions"]["target"]["criteria"]["t0"],
        "保存"
    );
    assert!(
        !cloud.contains("private title") && !cloud.contains(&f.id) && !cloud.contains("imagePath")
    );
}
#[test]
fn semantic_click_invalid_ocr_never_calls_model_or_clicks() {
    for invalid_ocr in [
        json!({"status":"unavailable","items":[],"truncated":false}),
        json!({"status":"ok","items":[],"truncated":false}),
        json!({"status":"ok","items":[],"truncated":true}),
    ] {
        let mut f = Fixture::new(invalid_ocr, Ok(response()), None, true);
        assert!(f.click().is_err());
        assert_eq!(f.clicks(), 0);
        assert!(f.decisions.lock().unwrap().is_empty());
    }
}
#[test]
fn semantic_click_model_failure_or_ambiguity_never_dispatches() {
    let mut ambiguous = response();
    ambiguous["answers"]["target"]["confidence"] = json!(0.4);
    ambiguous["answers"]["target"]["probabilities"] = json!({"t0":0.7,"none":0.3});
    for reply in [
        Err(Error::new("JEV_TIMEOUT", "fixture timeout")),
        Ok(ambiguous),
    ] {
        let mut f = Fixture::new(ocr(), reply, None, true);
        assert!(f.click().is_err());
        assert_eq!(f.clicks(), 0);
        assert_eq!(f.decisions.lock().unwrap().len(), 1);
    }
}
#[test]
fn semantic_click_native_rejection_is_not_retried_and_connection_remains() {
    for code in [
        "USER_PAUSED",
        "POINTER_OCCLUDED",
        "FRAME_GEOMETRY_CHANGED",
        "FOCUS_LOST",
    ] {
        let mut f = Fixture::new(ocr(), Ok(response()), Some(code), true);
        assert_eq!(f.click().unwrap_err().code, code);
        assert_eq!(f.clicks(), 1);
        assert_eq!(
            f.service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );
    }
}
#[test]
fn semantic_click_invalid_credentials_or_scope_fields_have_no_observation_or_cloud_side_effects() {
    let mut f = Fixture::new(ocr(), Ok(response()), None, true);
    for request in [
        json!({"action":"click-target","jevProtocol":"decisions-v1","jevUrl":"https://router.example/decisions","jevModel":"typesafe/jev-1.13","connectionId":"wrong","target":"保存","jevKey":"test-private-key"}),
        json!({"action":"click-target","jevProtocol":"decisions-v1","jevUrl":"https://router.example/decisions","jevModel":"typesafe/jev-1.13","connectionId":f.id,"target":"","jevKey":"test-private-key"}),
        json!({"action":"click-target","jevProtocol":"decisions-v1","jevUrl":"https://router.example/decisions","jevModel":"typesafe/jev-1.13","connectionId":f.id,"target":"保存","jevKey":""}),
        json!({"action":"click-target","jevProtocol":"decisions-v1","jevUrl":"https://router.example/decisions","jevModel":"typesafe/jev-1.13","connectionId":f.id,"target":"保存","jevKey":"test-private-key","x":1}),
    ] {
        assert!(f.service.execute(request).is_err());
    }
    assert_eq!(f.clicks(), 0);
    assert!(f.decisions.lock().unwrap().is_empty());
    assert!(!f
        .native
        .lock()
        .unwrap()
        .iter()
        .any(|r| r["action"] == "observe"));
}

#[test]
fn semantic_click_rechecks_original_window_geometry_after_model_returns() {
    let mut f = Fixture::new(ocr(), Ok(response()), None, true);
    f.mutate_window.store(true, Ordering::Release);
    assert_eq!(f.click().unwrap_err().code, "FRAME_GEOMETRY_CHANGED");
    assert_eq!(f.clicks(), 0);
    assert_eq!(f.decisions.lock().unwrap().len(), 1);
}

#[test]
fn semantic_click_requires_matching_provider_before_observation_or_sending_credentials() {
    let mut f = Fixture::new(ocr(), Ok(response()), None, true);
    for provider in [Value::Null, json!("typesafe"), json!("other")] {
        let mut request = json!({"action":"click-target","connectionId":f.id,"target":"保存","jevKey":"test-private-key","jevProtocol":provider});
        if provider.is_null() {
            request.as_object_mut().unwrap().remove("jevProtocol");
        }
        assert_eq!(
            f.service.execute(request).unwrap_err().code,
            "JEV_PROTOCOL_MISMATCH"
        );
    }
    assert!(f.decisions.lock().unwrap().is_empty());
    assert!(!f
        .native
        .lock()
        .unwrap()
        .iter()
        .any(|r| r["action"] == "observe"));
    assert_eq!(f.clicks(), 0);
}

#[test]
fn semantic_click_uses_original_click_without_recheck_or_observation_epoch_metadata() {
    let mut semantic = Fixture::new(ocr(), Ok(response()), None, false);
    let result = semantic.click().unwrap();
    let semantic_request = semantic
        .native
        .lock()
        .unwrap()
        .iter()
        .find(|r| r["action"] == "click")
        .unwrap()
        .clone();
    assert_eq!(semantic.clicks(), 1);
    assert_eq!(
        semantic
            .native
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r["action"] == "observe")
            .count(),
        1
    );
    assert!(result["timingMs"]["click"].is_u64());
    let mut original = Fixture::new(ocr(), Ok(response()), None, false);
    let frame = original
        .service
        .execute(json!({"action":"observe","connectionId":original.id}))
        .unwrap();
    original.service.execute(json!({"action":"click","connectionId":original.id,"frameId":frame["frameId"],"x":60,"y":40})).unwrap();
    let original_request = original
        .native
        .lock()
        .unwrap()
        .iter()
        .find(|r| r["action"] == "click")
        .unwrap()
        .clone();
    assert_eq!(
        semantic_request, original_request,
        "native click payload must be exactly the original click path"
    );
}

#[test]
fn semantic_click_with_truncated_valid_ocr_still_calls_jev_and_original_click() {
    let mut partial = ocr();
    partial["truncated"] = json!(true);
    let mut f = Fixture::new(partial, Ok(response()), None, false);
    let receipt = f
        .click()
        .expect("truncation alone must not reject a semantic click");
    assert_eq!(receipt["sent"], true);
    assert_eq!(f.clicks(), 1);
    assert_eq!(f.decisions.lock().unwrap().len(), 1);
    assert_eq!(
        f.decisions.lock().unwrap()[0]["state"],
        json!({"target":"保存按钮"})
    );
    assert_eq!(
        f.decisions.lock().unwrap()[0]["questions"]
            .as_object()
            .unwrap()
            .len(),
        1
    );
    assert!(!f
        .native
        .lock()
        .unwrap()
        .iter()
        .find(|r| r["action"] == "click")
        .unwrap()
        .as_object()
        .unwrap()
        .contains_key("textGuard"));
}

#[test]
fn semantic_click_uses_configured_model_in_request_selection_and_receipt() {
    let mut reply = response();
    reply["model"] = json!("different-vendor/decision-20261027");
    let mut f = Fixture::new(ocr(), Ok(reply), None, true);
    let result = f
        .service
        .execute(json!({"action":"click-target","jevProtocol":"decisions-v1",
        "jevUrl":"https://router.example/decisions","jevModel":"different-vendor/decision",
        "connectionId":f.id,"target":"保存","jevKey":"test-private-key"}))
        .unwrap();
    assert_eq!(
        result["selection"]["requestedModel"],
        "different-vendor/decision"
    );
    assert_eq!(
        f.decisions.lock().unwrap()[0]["model"],
        "different-vendor/decision"
    );
    assert_eq!(f.clicks(), 1);
}
