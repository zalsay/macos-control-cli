use copis_chrome::{
    args::{parse_for_scope, Command},
    protocol::Scope,
};
use serde_json::json;

#[cfg(unix)]
#[test]
fn local_control_cli_reaches_sideband_without_busy_service_preflight() {
    use copis_chrome::{protocol::read_message, runtime::Runtime};
    use std::{
        io::{BufReader, Write},
        process::Command as Process,
    };
    let root = std::path::PathBuf::from("/tmp").join(format!(
        "mcc-ctrl-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    let runtime = Runtime {
        socket: root.join("daemon.sock"),
        frames: root.join("frames"),
        root: root.clone(),
        scope: Scope::Desktop,
    };
    runtime.prepare().unwrap();
    let listener = runtime.bind_listener().unwrap();
    listener.set_nonblocking(false).unwrap();
    let server = std::thread::spawn(move || loop {
        let (mut stream, _) = listener.accept().unwrap();
        let Some(value) = read_message(&mut BufReader::new(&stream)).unwrap() else {
            continue;
        };
        let control = value["request"]["action"] == "control";
        let response = if control {
            json!({"ok":true,"protocolVersion":1,"scope":"desktop","paused":true})
        } else {
            json!({"ok":false,"protocolVersion":1,"scope":"desktop","error":{"code":"BUSY","message":"Service is executing Actions"}})
        };
        writeln!(stream, "{response}").unwrap();
        break value["request"].clone();
    });
    let output = Process::new(env!("CARGO_BIN_EXE_mcc"))
        .env("COPIS_DESKTOP_RUNTIME_DIR", &root)
        .env("MCC_DOCKER", "1")
        .args(["control", "--command", "pause"])
        .output()
        .unwrap();
    let received = server.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
    assert_eq!(received, json!({"action":"control","command":"pause"}));
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
}

#[test]
fn firefox_start_reuses_a_desktop_request_and_does_not_allow_driver_urls() {
    let Command::Request { request, .. } = parse_for_scope(
        [
            "firefox",
            "start",
            "--profile",
            "test",
            "--url",
            "https://example.com/",
        ]
        .map(str::to_owned),
        Scope::Desktop,
    )
    .unwrap() else {
        panic!("expected normal request")
    };
    assert_eq!(
        request,
        json!({"action":"firefox-start","profile":"test","url":"https://example.com/"})
    );
    assert!(parse_for_scope(
        ["firefox", "start", "--driver-url", "http://example.com/"].map(str::to_owned),
        Scope::Desktop
    )
    .is_err());
    assert!(parse_for_scope(["firefox", "start"].map(str::to_owned), Scope::Chrome).is_err());
}

#[test]
fn firefox_pointer_command_preserves_frame_and_duration() {
    let Command::Request { request, .. } = parse_for_scope(
        [
            "move",
            "--connection",
            "c",
            "--frame",
            "f",
            "--x",
            "12",
            "--y",
            "34",
            "--duration-ms",
            "200",
        ]
        .map(str::to_owned),
        Scope::Desktop,
    )
    .unwrap() else {
        panic!("expected normal request")
    };
    assert_eq!(
        request,
        json!({"action":"move","connectionId":"c","frameId":"f","x":12,"y":34,"durationMs":200})
    );
}

fn desktop(args: &[&str]) -> serde_json::Value {
    match parse_for_scope(args.iter().map(|s| (*s).to_owned()), Scope::Desktop).unwrap() {
        Command::Request { request, .. } => request,
        _ => panic!("expected request"),
    }
}

#[test]
fn firefox_click_and_drag_options_are_typed_and_chrome_rejects_new_options() {
    assert_eq!(
        desktop(&[
            "click",
            "--connection",
            "c",
            "--frame",
            "f",
            "--x",
            "1",
            "--y",
            "2",
            "--button",
            "right",
            "--modifiers",
            "shift,control"
        ]),
        json!({"action":"click","connectionId":"c","frameId":"f","x":1,"y":2,"button":"right","modifiers":"shift,control"})
    );
    assert_eq!(
        desktop(&[
            "drag",
            "--connection",
            "c",
            "--frame",
            "f",
            "--from-x",
            "1",
            "--from-y",
            "2",
            "--to-x",
            "3",
            "--to-y",
            "4",
            "--duration-ms",
            "800"
        ]),
        json!({"action":"drag","connectionId":"c","frameId":"f","fromX":1,"fromY":2,"toX":3,"toY":4,"durationMs":800})
    );
    assert!(parse_for_scope(
        [
            "click",
            "--connection",
            "c",
            "--frame",
            "f",
            "--x",
            "1",
            "--y",
            "2",
            "--button",
            "right"
        ]
        .map(str::to_owned),
        Scope::Chrome
    )
    .is_err());
    assert!(parse_for_scope(
        [
            "move",
            "--connection",
            "c",
            "--frame",
            "f",
            "--x",
            "1",
            "--y",
            "2",
            "--duration-ms",
            "2001"
        ]
        .map(str::to_owned),
        Scope::Desktop
    )
    .is_err());
}

#[test]
fn actions_file_is_inlined_bounded_and_does_not_reach_remote_as_a_path() {
    let path = std::env::temp_dir().join(format!(
        "mcc-actions-{}.json",
        copis_chrome::protocol::random_id().unwrap()
    ));
    let actions = json!({"version":1,"steps":[{"type":"move","x":10,"y":20,"durationMs":10}]});
    std::fs::write(&path, actions.to_string()).unwrap();
    let request = desktop(&[
        "actions",
        "--connection",
        "c",
        "--frame",
        "f",
        "--file",
        path.to_str().unwrap(),
    ]);
    assert_eq!(
        request,
        json!({"action":"actions","connectionId":"c","frameId":"f","actions":actions})
    );
    std::fs::write(&path, vec![b' '; 65537]).unwrap();
    assert!(parse_for_scope(
        [
            "actions",
            "--connection",
            "c",
            "--frame",
            "f",
            "--file",
            path.to_str().unwrap()
        ]
        .map(str::to_owned),
        Scope::Desktop
    )
    .is_err());
    std::fs::remove_file(path).unwrap();
}

#[derive(Clone)]
struct FirefoxNative(std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>);
fn firefox_window() -> serde_json::Value {
    json!({"windowId":7,"pid":42,"title":"Firefox","bundleId":"org.mozilla.firefox","appName":"Firefox","bounds":{"x":0.0,"y":0.0,"width":1200.0,"height":800.0}})
}
impl copis_chrome::service::Native for FirefoxNative {
    fn request(
        &mut self,
        request: serde_json::Value,
    ) -> copis_chrome::protocol::Result<serde_json::Value> {
        self.0.lock().unwrap().push(request.clone());
        Ok(match request["action"].as_str().unwrap() {
            "firefox-start" => {
                json!({"window":firefox_window(),"created":true,"backend":"firefox-x11","profile":{"name":request["profile"]}})
            }
            "permissions" => json!({"screenRecording":true,"accessibility":true}),
            "windows" => json!({"windows":[firefox_window()]}),
            "window" => json!({"window":firefox_window()}),
            "observe" => {
                std::fs::write(
                    request["imagePath"].as_str().unwrap(),
                    [0xff, 0xd8, 0xff, 0xd9],
                )
                .unwrap();
                json!({"imagePath":request["imagePath"],"width":1200,"height":800,"bounds":firefox_window()["bounds"],"capturedAtMs":1,"coordinateSpace":"frame-pixels","imageTransform":"crop-only","backendFrameId":"private-backend-frame"})
            }
            "cancel" => json!({"cancelled":true}),
            _ => {
                json!({"sent":true,"backend":"firefox-x11","dispatchState":"completed","completedSteps":1,"inputState":"released","effectVerified":false})
            }
        })
    }
}
#[test]
fn firefox_start_connects_once_and_private_backend_frame_and_receipt_survive_input() {
    let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let mut service = copis_chrome::service::Service::with_scope(
        FirefoxNative(requests.clone()),
        std::env::temp_dir(),
        Scope::Desktop,
    );
    let connected = service
        .execute(json!({"action":"firefox-start","profile":"test","url":"https://example.com/"}))
        .unwrap();
    assert_eq!(connected["backend"], "firefox-x11");
    assert_eq!(connected["profile"], json!({"name":"test"}));
    assert!(connected["connectionId"].is_string());
    assert_eq!(
        service
            .execute(
                json!({"action":"firefox-start","profile":"test","url":"https://example.com/"})
            )
            .unwrap_err()
            .code,
        "CONNECTION_BUSY"
    );
    let observed = service
        .execute(json!({"action":"observe","connectionId":connected["connectionId"]}))
        .unwrap();
    assert!(observed.get("backendFrameId").is_none());
    let receipt = service.execute(json!({"action":"move","connectionId":connected["connectionId"],"frameId":observed["frameId"],"x":10,"y":20,"durationMs":300})).unwrap();
    assert_eq!(receipt["backend"], "firefox-x11");
    assert_eq!(receipt["dispatchState"], "completed");
    assert_eq!(receipt["completedSteps"], 1);
    assert_eq!(receipt["inputState"], "released");
    assert_eq!(receipt["effectVerified"], false);
    let requests = requests.lock().unwrap();
    let input = requests.iter().find(|r| r["action"] == "move").unwrap();
    assert_eq!(input["backendFrameId"], "private-backend-frame");
    assert_eq!(input["x"], 10);
    assert_eq!(input["y"], 20);
    assert_eq!(input["durationMs"], 300);
    assert_eq!(input["windowId"], 7);
    assert_eq!(input["pid"], 42);
}

#[test]
fn remote_schema_accepts_desktop_firefox_and_refuses_unknown_and_file_fields() {
    use copis_chrome::remote::protocol::validate_action;
    assert!(validate_action(
        Scope::Desktop,
        &json!({"action":"firefox-start","profile":"test","url":"https://example.com/"})
    )
    .is_ok());
    assert!(validate_action(
        Scope::Chrome,
        &json!({"action":"firefox-start","profile":"test","url":"https://example.com/"})
    )
    .is_err());
    assert!(validate_action(Scope::Desktop, &json!({"action":"actions","connectionId":"c","frameId":"f","actions":{"version":1,"steps":[{"type":"pause","durationMs":10}]}})).is_ok());
    assert!(validate_action(
        Scope::Desktop,
        &json!({"action":"actions","connectionId":"c","frameId":"f","file":"/tmp/actions.json"})
    )
    .is_err());
    assert!(validate_action(Scope::Desktop, &json!({"action":"move","connectionId":"c","frameId":"f","x":1,"y":2,"durationMs":10,"secret":true})).is_err());
}

#[test]
fn native_firefox_identity_does_not_silently_enable_managed_options() {
    let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let mut service = copis_chrome::service::Service::with_scope(
        FirefoxNative(requests.clone()),
        std::env::temp_dir(),
        Scope::Desktop,
    );
    let connected = service
        .execute(json!({"action":"connect","windowId":7}))
        .unwrap();
    let observed = service
        .execute(json!({"action":"observe","connectionId":connected["connectionId"]}))
        .unwrap();
    assert_eq!(service.execute(json!({"action":"click","connectionId":connected["connectionId"],"frameId":observed["frameId"],"x":10,"y":20,"button":"right"})).unwrap_err().code,"ACTION_UNSUPPORTED");
    assert!(!requests
        .lock()
        .unwrap()
        .iter()
        .any(|r| r["action"] == "click"));
}

#[test]
fn docker_desktop_permissions_do_not_require_macos_chrome_automation() {
    struct Permissions;
    impl copis_chrome::service::Native for Permissions {
        fn request(
            &mut self,
            _: serde_json::Value,
        ) -> copis_chrome::protocol::Result<serde_json::Value> {
            Ok(
                json!({"platform":"linux-docker","screenRecording":true,"accessibility":true,"backend":"x11"}),
            )
        }
    }
    let mut desktop = copis_chrome::service::Service::with_scope(
        Permissions,
        std::env::temp_dir(),
        Scope::Desktop,
    );
    assert_eq!(
        desktop.execute(json!({"action":"permissions"})).unwrap()["platform"],
        "linux-docker"
    );
    let mut chrome = copis_chrome::service::Service::new(Permissions, std::env::temp_dir());
    assert_eq!(
        chrome
            .execute(json!({"action":"permissions"}))
            .unwrap_err()
            .code,
        "HELPER_UPGRADE_REQUIRED"
    );
}

#[test]
fn managed_firefox_accepts_control_and_shift_chords_without_remapping_cmd() {
    let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let mut service = copis_chrome::service::Service::with_scope(
        FirefoxNative(requests.clone()),
        std::env::temp_dir(),
        Scope::Desktop,
    );
    let connected = service
        .execute(json!({"action":"firefox-start","profile":"test"}))
        .unwrap();
    let observed = service
        .execute(json!({"action":"observe","connectionId":connected["connectionId"]}))
        .unwrap();
    for key in ["Control+L", "Shift+Tab"] {
        assert_eq!(service.execute(json!({"action":"press","connectionId":connected["connectionId"],"frameId":observed["frameId"],"key":key})).unwrap()["sent"],true);
    }
    assert_eq!(service.execute(json!({"action":"press","connectionId":connected["connectionId"],"frameId":observed["frameId"],"key":"Cmd+L"})).unwrap_err().code,"INVALID_ARGUMENT");
    let keys: Vec<_> = requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r["action"] == "press")
        .map(|r| r["key"].clone())
        .collect();
    assert_eq!(keys, vec![json!("Control+L"), json!("Shift+Tab")]);
}

#[test]
fn firefox_capabilities_are_negotiated_and_old_hosts_reject_before_dispatch() {
    use copis_chrome::remote::{
        protocol::{require_capability, Hello},
        wire::parse_hello,
    };
    let start = json!({"action":"firefox-start","profile":"test"});
    assert_eq!(
        require_capability(&start, &["remote-v1".into()])
            .unwrap_err()
            .code,
        "ACTION_UNSUPPORTED"
    );
    let capabilities = vec![
        "remote-v1".into(),
        "firefox.x11.v1".into(),
        "firefox.system-input.v1".into(),
    ];
    assert!(require_capability(&start, &capabilities).is_ok());
    assert!(require_capability(
        &json!({"action":"click","button":"right"}),
        &["remote-v1".into()]
    )
    .is_err());
    assert!(require_capability(&json!({"action":"click"}), &["remote-v1".into()]).is_ok());
    let hello = Hello {
        remote_protocol: 1,
        version: env!("CARGO_PKG_VERSION").into(),
        scope: Scope::Desktop,
        boot_id: "boot".into(),
        capabilities,
    };
    assert!(parse_hello(
        &serde_json::to_vec(&hello).unwrap(),
        env!("CARGO_PKG_VERSION"),
        Scope::Desktop
    )
    .is_ok());
}

#[test]
fn public_pause_envelopes_keep_partial_receipts_while_redacting_helper_diagnostics() {
    use copis_chrome::protocol::{response_for, response_for_host, Error};
    let receipt = json!({"backend":"firefox-x11","dispatchState":"partial","completedSteps":2,"inputState":"released","effectVerified":false});
    for scope in [Scope::Chrome, Scope::Desktop] {
        for response in [
            response_for(
                Err(Error::new("USER_PAUSED", "private helper diagnostics")
                    .with_receipt(receipt.clone())),
                scope,
            ),
            response_for_host(
                Err(Error::new("USER_PAUSED", "private helper diagnostics")
                    .with_receipt(receipt.clone())),
                scope,
            ),
        ] {
            assert_eq!(response["ok"], false);
            assert_eq!(response["protocolVersion"], 1);
            assert_eq!(response["error"]["code"], "FOCUS_LOST");
            assert_eq!(response["error"]["reason"], "USER_PAUSED");
            assert_eq!(response["error"]["receipt"], receipt);
            assert!(!response["error"]["message"]
                .as_str()
                .unwrap()
                .contains("private"));
            if scope == Scope::Desktop {
                assert_eq!(response["scope"], "desktop");
            }
        }
    }
}
