use copis_chrome::protocol::{Result, Scope};
use copis_chrome::service::{Native, Service};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
struct DesktopNative {
    calls: Arc<Mutex<Vec<Value>>>,
    replace_bundle: Arc<Mutex<bool>>,
    omit_bundle: bool,
    selected_bundle_id: Option<String>,
}
impl Default for DesktopNative {
    fn default() -> Self {
        Self {
            calls: Arc::new(Mutex::new(Vec::new())),
            replace_bundle: Arc::new(Mutex::new(false)),
            omit_bundle: false,
            selected_bundle_id: Some("com.apple.TextEdit".into()),
        }
    }
}

fn window(window_id: u32, pid: i32, bundle_id: Option<&str>, app_name: &str) -> Value {
    let mut value = json!({
        "windowId": window_id,
        "pid": pid,
        "title": app_name,
        "appName": app_name,
        "bounds": {"x": 10.0, "y": 20.0, "width": 900.0, "height": 700.0}
    });
    if let Some(bundle_id) = bundle_id {
        value["bundleId"] = json!(bundle_id);
    }
    value
}

impl Native for DesktopNative {
    fn request(&mut self, request: Value) -> Result<Value> {
        self.calls.lock().unwrap().push(request.clone());
        match request["action"].as_str().unwrap() {
            "permissions" => Ok(json!({"screenRecording":true,"accessibility":true})),
            "apps" => Ok(json!({"apps":[
                {"pid":501,"bundleId":"com.apple.TextEdit","name":"TextEdit"},
                {"pid":502,"bundleId":"com.apple.finder","name":"Finder"}
            ]})),
            "windows" => Ok(json!({"windows":[
                window(51, 501, if self.omit_bundle { None } else { self.selected_bundle_id.as_deref() }, "TextEdit"),
                window(52, 502, Some("com.apple.finder"), "Finder")
            ]})),
            "window" => {
                let bundle_id = if *self.replace_bundle.lock().unwrap() {
                    Some("com.example.Replacement")
                } else if self.omit_bundle {
                    None
                } else {
                    self.selected_bundle_id.as_deref()
                };
                Ok(json!({"window":window(51, 501, bundle_id, "TextEdit")}))
            }
            "observe" => {
                std::fs::write(
                    request["imagePath"].as_str().unwrap(),
                    [0xff, 0xd8, 0xff, 0xd9],
                )
                .unwrap();
                Ok(json!({
                    "imagePath":request["imagePath"],"width":900,"height":700,
                    "bounds":{"x":10.0,"y":20.0,"width":900.0,"height":700.0},"capturedAtMs":1
                }))
            }
            "select-file" => Ok(json!({"selected":true,"dialogClosed":true})),
            "cancel" => Ok(json!({"cancelled":true})),
            _ => Ok(json!({"sent":true})),
        }
    }
}

fn service(native: DesktopNative, scope: Scope) -> Service<DesktopNative> {
    Service::with_scope(native, std::env::temp_dir(), scope)
}

fn connect(service: &mut Service<DesktopNative>, window_id: u32) -> Result<Value> {
    service.execute(json!({"action":"connect","windowId":window_id}))
}

#[test]
fn given_desktop_scope_when_listing_apps_and_filtered_windows_then_only_matching_app_is_returned() {
    let native = DesktopNative::default();
    let calls = native.calls.clone();
    let mut service = service(native, Scope::Desktop);

    let apps = service.execute(json!({"action":"apps"})).unwrap();
    let windows = service
        .execute(json!({"action":"windows","bundleId":"com.apple.finder"}))
        .unwrap();

    assert_eq!(apps["apps"].as_array().unwrap().len(), 2);
    assert_eq!(windows["windows"].as_array().unwrap().len(), 1);
    assert_eq!(windows["windows"][0]["bundleId"], "com.apple.finder");
    assert_eq!(windows["windows"][0]["appName"], "Finder");
    assert_eq!(calls.lock().unwrap()[0]["action"], "apps");
}

#[test]
fn given_chrome_scope_when_requesting_generic_app_commands_then_reject_without_native_expansion() {
    let native = DesktopNative::default();
    let calls = native.calls.clone();
    let mut service = Service::new(native, std::env::temp_dir());

    for request in [
        json!({"action":"apps"}),
        json!({"action":"windows","bundleId":"com.apple.finder"}),
    ] {
        assert_eq!(service.execute(request).unwrap_err().code, "SCOPE_MISMATCH");
    }
    assert!(calls.lock().unwrap().is_empty());
}

#[test]
fn given_desktop_connection_when_observing_and_inputting_then_fixed_bundle_identity_is_sent_to_helper(
) {
    let native = DesktopNative::default();
    let calls = native.calls.clone();
    let mut service = service(native, Scope::Desktop);
    let connection = connect(&mut service, 51).unwrap()["connectionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let frame = service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap()["frameId"]
        .as_str()
        .unwrap()
        .to_owned();
    for request in [
        json!({"action":"click","connectionId":connection,"frameId":frame,"x":10,"y":10}),
        json!({"action":"scroll","connectionId":connection,"frameId":frame,"x":10,"y":10,"deltaY":100}),
        json!({"action":"type","connectionId":connection,"frameId":frame,"text":"hello"}),
        json!({"action":"press","connectionId":connection,"frameId":frame,"key":"Enter"}),
    ] {
        service.execute(request).unwrap();
    }

    let calls = calls.lock().unwrap();
    for action in ["window", "observe", "click", "scroll", "type", "press"] {
        let request = calls
            .iter()
            .find(|request| request["action"] == action)
            .unwrap();
        assert_eq!(
            request["bundleId"], "com.apple.TextEdit",
            "{action} 必须保持已连接应用身份"
        );
    }
}

#[test]
fn given_pid_is_reused_by_another_bundle_when_revalidating_then_connection_is_revoked_without_input(
) {
    let native = DesktopNative::default();
    let replaced = native.replace_bundle.clone();
    let calls = native.calls.clone();
    let mut service = service(native, Scope::Desktop);
    let connection = connect(&mut service, 51).unwrap()["connectionId"]
        .as_str()
        .unwrap()
        .to_owned();
    *replaced.lock().unwrap() = true;

    let error = service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap_err();

    assert_eq!(error.code, "WINDOW_UNAVAILABLE");
    assert!(!calls
        .lock()
        .unwrap()
        .iter()
        .any(|request| request["action"] == "observe"));
    assert_eq!(
        service.execute(json!({"action":"status"})).unwrap()["connected"],
        false
    );
}

#[test]
fn given_chrome_scope_when_helper_reports_other_bundle_id_then_reject_connection() {
    let native = DesktopNative {
        selected_bundle_id: Some("com.apple.TextEdit".into()),
        ..DesktopNative::default()
    };
    let mut service = Service::new(native, std::env::temp_dir());
    assert_eq!(
        connect(&mut service, 51).unwrap_err().code,
        "HELPER_PROTOCOL"
    );
}

#[test]
fn given_desktop_window_has_no_bundle_id_when_connecting_then_reject_and_keep_unconnected() {
    let native = DesktopNative {
        omit_bundle: true,
        ..DesktopNative::default()
    };
    let mut service = service(native, Scope::Desktop);

    assert_eq!(
        connect(&mut service, 51).unwrap_err().code,
        "HELPER_PROTOCOL"
    );
    assert_eq!(
        service.execute(json!({"action":"status"})).unwrap()["connected"],
        false
    );
}

#[test]
fn given_desktop_non_chrome_connection_when_selecting_file_then_fail_before_helper_dialog_action() {
    let native = DesktopNative::default();
    let calls = native.calls.clone();
    let mut service = service(native, Scope::Desktop);
    let connection = connect(&mut service, 51).unwrap()["connectionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let path = std::env::temp_dir().join(format!(
        "app-scope-{}.txt",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::write(&path, "fixture").unwrap();

    let error = service
        .execute(json!({"action":"select-file","connectionId":connection,"path":path}))
        .unwrap_err();

    assert_eq!(error.code, "FILE_DIALOG_UNSUPPORTED");
    assert!(!calls
        .lock()
        .unwrap()
        .iter()
        .any(|request| request["action"] == "select-file"));
    let _ = std::fs::remove_file(path);
}

#[test]
fn given_legacy_chrome_window_without_bundle_metadata_when_observing_then_old_helper_payload_remains_compatible(
) {
    let native = DesktopNative {
        omit_bundle: true,
        ..DesktopNative::default()
    };
    let calls = native.calls.clone();
    let mut service = Service::new(native, std::env::temp_dir());
    let connection = connect(&mut service, 51).unwrap()["connectionId"]
        .as_str()
        .unwrap()
        .to_owned();
    service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap();

    let calls = calls.lock().unwrap();
    assert!(calls
        .iter()
        .filter(|request| ["window", "observe"].contains(&request["action"].as_str().unwrap()))
        .all(|request| request.get("bundleId").is_none()));
}

#[test]
fn given_desktop_scope_when_selecting_file_for_google_chrome_then_fixed_identity_is_preserved() {
    let native = DesktopNative {
        selected_bundle_id: Some("com.google.Chrome".into()),
        ..DesktopNative::default()
    };
    let calls = native.calls.clone();
    let mut service = service(native, Scope::Desktop);
    let connection = connect(&mut service, 51).unwrap()["connectionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let path = std::env::temp_dir().join(format!(
        "app-scope-{}.txt",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::write(&path, "fixture").unwrap();

    service
        .execute(json!({"action":"select-file","connectionId":connection,"path":path}))
        .unwrap();

    let request = calls
        .lock()
        .unwrap()
        .iter()
        .find(|request| request["action"] == "select-file")
        .unwrap()
        .clone();
    assert_eq!(request["bundleId"], "com.google.Chrome");
    let _ = std::fs::remove_file(path);
}

#[test]
fn given_connection_when_selecting_target_then_revalidate_native_window_before_input() {
    let native = DesktopNative::default();
    let calls = native.calls.clone();
    let mut service = service(native, Scope::Desktop);
    connect(&mut service, 51).unwrap();
    let calls = calls.lock().unwrap();
    let primed = calls
        .iter()
        .find(|v| v["action"] == "window")
        .expect("连接时必须只读复核目标窗口，为原生顶部提示预读几何");
    assert_eq!(primed["windowId"], 51);
    assert_eq!(primed["pid"], 501);
    assert_eq!(primed["bundleId"], "com.apple.TextEdit");
}
