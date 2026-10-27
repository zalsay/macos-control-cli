use copis_chrome::{
    protocol::{Result, Scope},
    service::{Native, Service},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
struct Fake {
    calls: Arc<Mutex<Vec<Value>>>,
    permissions: bool,
}
fn window() -> Value {
    json!({"windowId":42,"pid":123,"bundleId":"com.google.Chrome","title":"test","bounds":{"x":0.0,"y":25.0,"width":800.0,"height":1000.0}})
}
impl Native for Fake {
    fn request(&mut self, request: Value) -> Result<Value> {
        self.calls.lock().unwrap().push(request.clone());
        Ok(match request["action"].as_str().unwrap() {
            "permissions" => {
                json!({"screenRecording":self.permissions,"accessibility":self.permissions})
            }
            "chrome-start" => json!({"window":window(),"layout":{"maxWidthPx":1600,"scale":2}}),
            "windows" => json!({"windows":[window()]}),
            "window" => json!({"window":window()}),
            "cancel" => json!({"cancelled":true}),
            action => panic!("unexpected {action}"),
        })
    }
}
#[test]
fn launch_returns_original_connect_contract_and_never_replaces_an_existing_connection() {
    let calls = Arc::new(Mutex::new(vec![]));
    let mut service = Service::with_scope(
        Fake {
            calls: calls.clone(),
            permissions: true,
        },
        std::env::temp_dir(),
        Scope::Desktop,
    );
    let request = json!({"action":"chrome-start","maxWidthPx":1600,"url":"https://example.com/"});
    let result = service.execute(request.clone()).unwrap();
    assert_eq!(result["created"], true);
    assert_eq!(result["connected"], true);
    assert_eq!(result["window"], window());
    assert!(result["connectionId"].is_string());
    assert_eq!(result["layout"]["scale"], 2);
    let before = calls.lock().unwrap().len();
    assert_eq!(
        service.execute(request).unwrap_err().code,
        "CONNECTION_BUSY"
    );
    assert_eq!(calls.lock().unwrap().len(), before);
    service
        .execute(json!({"action":"disconnect","connectionId":result["connectionId"]}))
        .unwrap();
}
#[test]
fn launch_validates_before_side_effects_and_permissions_before_window_creation() {
    let calls = Arc::new(Mutex::new(vec![]));
    let mut service = Service::new(
        Fake {
            calls: calls.clone(),
            permissions: false,
        },
        std::env::temp_dir(),
    );
    for request in [
        json!({"action":"chrome-start","maxWidthPx":0}),
        json!({"action":"chrome-start","maxWidthPx":1601}),
        json!({"action":"chrome-start","maxWidthPx":1600,"url":"file:///tmp/private"}),
        json!({"action":"chrome-start","maxWidthPx":1600,"url":"https://user:secret@example.com/"}),
    ] {
        assert!(service.execute(request).is_err());
    }
    assert!(calls.lock().unwrap().is_empty());
    assert_eq!(
        service
            .execute(json!({"action":"chrome-start","maxWidthPx":1600}))
            .unwrap_err()
            .code,
        "SCREEN_PERMISSION_REQUIRED"
    );
    assert_eq!(calls.lock().unwrap().len(), 1);
}
