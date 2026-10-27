use copis_chrome::{
    protocol::Result,
    service::{Native, Service},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
struct Fake {
    calls: Arc<Mutex<Vec<Value>>>,
    legacy: bool,
}
impl Native for Fake {
    fn request(&mut self, request: Value) -> Result<Value> {
        self.calls.lock().unwrap().push(request.clone());
        let mut reply = json!({"screenRecording":true,"accessibility":true});
        if !self.legacy {
            reply["chromeAutomation"] = json!({"target":"com.google.Chrome","requested":request["request"],"granted":false,"status":"requires_consent","osStatus":-1744});
        }
        Ok(reply)
    }
}
#[test]
fn permissions_preserves_explicit_request_and_reports_consent_without_claiming_granted() {
    let calls = Arc::new(Mutex::new(vec![]));
    let mut service = Service::new(
        Fake {
            calls: calls.clone(),
            legacy: false,
        },
        std::env::temp_dir(),
    );
    for requested in [false, true] {
        let result = service
            .execute(json!({"action":"permissions","request":requested}))
            .unwrap();
        assert_eq!(result["chromeAutomation"]["requested"], requested);
        assert_eq!(result["chromeAutomation"]["granted"], false);
        assert_eq!(result["chromeAutomation"]["osStatus"], -1744);
        assert_eq!(
            calls.lock().unwrap().last().unwrap(),
            &json!({"action":"permissions","request":requested})
        );
    }
    let before = calls.lock().unwrap().len();
    assert!(service
        .execute(json!({"action":"permissions","request":1}))
        .is_err());
    assert_eq!(calls.lock().unwrap().len(), before);
}
#[test]
fn old_helper_cannot_claim_all_permissions_were_requested_without_chrome_automation_receipt() {
    let calls = Arc::new(Mutex::new(vec![]));
    let mut service = Service::new(
        Fake {
            calls,
            legacy: true,
        },
        std::env::temp_dir(),
    );
    assert_eq!(
        service
            .execute(json!({"action":"permissions","request":true}))
            .unwrap_err()
            .code,
        "HELPER_UPGRADE_REQUIRED"
    );
}
