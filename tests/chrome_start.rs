use copis_chrome::{
    protocol::{Result, Scope},
    service::{Native, Service},
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
struct Fake {
    calls: Arc<Mutex<Vec<Value>>>,
    permissions: bool,
    profile_reply: Option<Value>,
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
            "chrome-start" => {
                let mut reply = json!({"window":window(),"layout":{"maxWidthPx":1600,"scale":2}});
                if let Some(name) = request["profile"].as_str() {
                    std::fs::write(
                        request["profileMarkerPath"].as_str().unwrap(),
                        "synthetic marker",
                    )
                    .unwrap();
                    reply["profile"]=self.profile_reply.clone().unwrap_or_else(|| json!({"name":name,"directory":"Profile 2","path":"/profiles/Profile 2"}));
                }
                reply
            }
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
            profile_reply: None,
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
            profile_reply: None,
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

#[test]
fn selected_profile_is_forwarded_and_returned_without_changing_connect_contract() {
    let calls = Arc::new(Mutex::new(vec![]));
    let mut service = Service::new(
        Fake {
            calls: calls.clone(),
            permissions: true,
            profile_reply: None,
        },
        std::env::temp_dir(),
    );
    let value = service
        .execute(json!({"action":"chrome-start","profile":"mcc","maxWidthPx":1600}))
        .unwrap();
    assert_eq!(
        value["profile"],
        json!({"name":"mcc","directory":"Profile 2","path":"/profiles/Profile 2"})
    );
    let marker = calls
        .lock()
        .unwrap()
        .iter()
        .find(|v| v["action"] == "chrome-start")
        .unwrap()["profileMarkerPath"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        !std::path::Path::new(&marker).exists(),
        "marker must be cleaned after success"
    );
    assert_eq!(value["connected"], true);
    assert_eq!(
        calls
            .lock()
            .unwrap()
            .iter()
            .find(|v| v["action"] == "chrome-start")
            .unwrap()["profile"],
        "mcc"
    );
}
#[test]
fn malformed_profile_never_reaches_native_and_unverified_reply_never_connects() {
    let calls = Arc::new(Mutex::new(vec![]));
    let mut service = Service::new(
        Fake {
            calls: calls.clone(),
            permissions: true,
            profile_reply: None,
        },
        std::env::temp_dir(),
    );
    for name in [
        json!(""),
        json!(" mcc"),
        json!("x\n"),
        json!(true),
        Value::Null,
    ] {
        assert!(service
            .execute(json!({"action":"chrome-start","profile":name,"maxWidthPx":1600}))
            .is_err());
    }
    assert!(calls.lock().unwrap().is_empty());
    for reply in [
        Value::Null,
        json!({"name":"other","directory":"Profile 2","path":"/profiles/Profile 2"}),
        json!({"name":"mcc","directory":"../other","path":"/profiles/../other"}),
        json!({"name":"mcc","directory":"Profile 2","path":"/profiles/other"}),
        json!({"name":"mcc","directory":"Profile 2","path":"/profiles/Profile 2","email":"private"}),
    ] {
        let calls = Arc::new(Mutex::new(vec![]));
        let mut s = Service::new(
            Fake {
                calls: calls.clone(),
                permissions: true,
                profile_reply: Some(reply),
            },
            std::env::temp_dir(),
        );
        assert_eq!(
            s.execute(json!({"action":"chrome-start","profile":"mcc","maxWidthPx":1600}))
                .unwrap_err()
                .code,
            "PROFILE_UNVERIFIED"
        );
        assert!(calls
            .lock()
            .unwrap()
            .iter()
            .all(|r| r["action"] != "windows" && r["action"] != "window"));
        let marker = calls
            .lock()
            .unwrap()
            .iter()
            .find(|v| v["action"] == "chrome-start")
            .unwrap()["profileMarkerPath"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(
            !std::path::Path::new(&marker).exists(),
            "marker must be cleaned after rejected reply"
        );
        assert_eq!(
            s.execute(json!({"action":"status"})).unwrap()["connected"],
            false
        );
    }
}
