use copis_chrome::protocol::{Error, Result};
use copis_chrome::service::{Native, Service};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

type CoordinateMarkers = Option<(Option<Value>, Option<Value>)>;

#[derive(Clone)]
struct Desktop {
    calls: Arc<Mutex<Vec<Value>>>,
    moved: Arc<Mutex<bool>>,
    missing: Arc<Mutex<bool>>,
    capture_size: Arc<Mutex<(u32, u32)>>,
    coordinate_markers: Arc<Mutex<CoordinateMarkers>>,
    ocr: Arc<Mutex<Option<Value>>>,
}
impl Default for Desktop {
    fn default() -> Self {
        Self {
            calls: Arc::new(Mutex::new(Vec::new())),
            moved: Arc::new(Mutex::new(false)),
            missing: Arc::new(Mutex::new(false)),
            capture_size: Arc::new(Mutex::new((1600, 1200))),
            coordinate_markers: Arc::new(Mutex::new(None)),
            ocr: Arc::new(Mutex::new(None)),
        }
    }
}
impl Desktop {
    fn set_capture_size(&self, width: u32, height: u32) {
        *self.capture_size.lock().unwrap() = (width, height);
    }

    fn declare_coordinate_contract(
        &self,
        coordinate_space: Option<Value>,
        image_transform: Option<Value>,
    ) {
        *self.coordinate_markers.lock().unwrap() = Some((coordinate_space, image_transform));
    }
}
impl Native for Desktop {
    fn request(&mut self, request: Value) -> Result<Value> {
        self.calls.lock().unwrap().push(request.clone());
        let bounds = if *self.moved.lock().unwrap() {
            json!({"x":-200.0,"y":20.0,"width":800.0,"height":600.0})
        } else {
            json!({"x":-300.0,"y":20.0,"width":800.0,"height":600.0})
        };
        let window = json!({"windowId":42,"pid":123,"title":"Example","bounds":bounds});
        match request["action"].as_str().unwrap() {
            "permissions" => Ok(json!({"screenRecording":true,"accessibility":true})),
            "windows" => Ok(json!({"windows":[window]})),
            "window" if *self.missing.lock().unwrap() => {
                Err(Error::new("WINDOW_UNAVAILABLE", "目标窗口已关闭"))
            }
            "window" => Ok(json!({"window":window})),
            "cancel" => Ok(json!({"cancelled":true})),
            "observe" => {
                std::fs::write(
                    request["imagePath"].as_str().unwrap(),
                    [0xff, 0xd8, 0xff, 0xd9],
                )
                .unwrap();
                let (width, height) = *self.capture_size.lock().unwrap();
                let mut response = json!({"imagePath":request["imagePath"],"width":width,"height":height,"bounds":bounds,"capturedAtMs":1});
                if let Some((coordinate_space, image_transform)) =
                    self.coordinate_markers.lock().unwrap().as_ref()
                {
                    if let Some(coordinate_space) = coordinate_space {
                        response["coordinateSpace"] = coordinate_space.clone();
                    }
                    if let Some(image_transform) = image_transform {
                        response["imageTransform"] = image_transform.clone();
                    }
                }
                if let Some(ocr) = self.ocr.lock().unwrap().as_ref() { response["ocr"] = ocr.clone(); }
                Ok(response)
            }
            _ => Ok(json!({"sent":true})),
        }
    }
}
fn setup() -> (Service<Desktop>, Desktop, std::path::PathBuf) {
    let desktop = Desktop::default();
    let path = std::env::temp_dir().join(format!(
        "chrome-behavior-{}-{}",
        std::process::id(),
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&path).unwrap();
    (Service::new(desktop.clone(), path.clone()), desktop, path)
}
fn connect(service: &mut Service<Desktop>) -> String {
    service
        .execute(json!({"action":"connect","windowId":42}))
        .unwrap()["connectionId"]
        .as_str()
        .unwrap()
        .to_owned()
}
fn observe(service: &mut Service<Desktop>, connection: &str) -> String {
    service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap()["frameId"]
        .as_str()
        .unwrap()
        .to_owned()
}
#[test]
fn given_one_observation_when_reused_multiple_times_then_all_inputs_are_sent_without_age_limit() {
    let (mut service, desktop, path) = setup();
    let connection = connect(&mut service);
    let frame = observe(&mut service, &connection);
    for _ in 0..3 {
        service.execute(json!({"action":"click","connectionId":connection,"frameId":frame,"x":400,"y":300,"clickCount":1})).unwrap();
    }
    let calls = desktop.calls.lock().unwrap();
    let clicks: Vec<_> = calls.iter().filter(|v| v["action"] == "click").collect();
    assert_eq!(clicks.len(), 3);
    assert_eq!(clicks[0]["screenX"], -100.0);
    assert_eq!(clicks[0]["screenY"], 170.0);
    drop(calls);
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn given_helper_declares_frame_pixels_and_crop_only_when_observing_then_expose_only_that_contract()
{
    let (mut service, desktop, path) = setup();
    desktop.declare_coordinate_contract(Some(json!("frame-pixels")), Some(json!("crop-only")));
    let connection = connect(&mut service);

    let frame = service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap();

    assert_eq!(frame["coordinateSpace"], "frame-pixels");
    assert_eq!(frame["imageTransform"], "crop-only");
    assert_eq!(frame["width"], 1600);
    assert_eq!(frame["height"], 1200);
    assert_eq!(frame["bounds"]["x"], -300.0);
    drop(service);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_legacy_helper_without_coordinate_markers_when_observing_then_keep_legacy_frame_without_inventing_contract(
) {
    let (mut service, _, path) = setup();
    let connection = connect(&mut service);

    let frame = service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap();

    assert!(frame.get("coordinateSpace").is_none());
    assert!(frame.get("imageTransform").is_none());
    assert_eq!(frame["width"], 1600);
    assert_eq!(frame["height"], 1200);
    assert_eq!(frame["bounds"]["x"], -300.0);
    drop(service);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_unsupported_or_incomplete_coordinate_marker_when_observing_then_reject_helper_protocol() {
    for (coordinate_space, image_transform) in [
        (Some(json!("screen-pixels")), Some(json!("crop-only"))),
        (Some(json!("frame-pixels")), Some(json!("scaled"))),
        (Some(json!("frame-pixels")), Some(Value::Null)),
        (Some(Value::Null), Some(json!("crop-only"))),
        (Some(json!({"private": "marker"})), Some(json!("crop-only"))),
        (Some(json!("frame-pixels")), None),
        (None, Some(json!("crop-only"))),
    ] {
        let (mut service, desktop, path) = setup();
        desktop.declare_coordinate_contract(coordinate_space, image_transform);
        let connection = connect(&mut service);

        let error = service
            .execute(json!({"action":"observe","connectionId":connection}))
            .unwrap_err();

        assert_eq!(error.code, "HELPER_PROTOCOL");
        assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
        drop(service);
        std::fs::remove_dir_all(path).unwrap();
    }
}

#[test]
fn given_one_x_or_two_x_frame_sampling_when_clicking_and_scrolling_then_cli_maps_pixels_using_bounds_and_receipts_match_delivery(
) {
    for (width, height) in [(800, 600), (1600, 1200)] {
        let (mut service, desktop, path) = setup();
        desktop.set_capture_size(width, height);
        let connection = connect(&mut service);
        let frame = observe(&mut service, &connection);
        // 同一相对位置在 1x/2x 帧中像素值不同，但应映射到同一屏幕点。
        let (x, y) = (width / 2, height / 2);
        let expected = json!({"x":100.0,"y":320.0});
        let click = service
            .execute(
                json!({"action":"click","connectionId":connection,"frameId":frame,"x":x,"y":y}),
            )
            .unwrap();
        let scroll = service
            .execute(json!({"action":"scroll","connectionId":connection,"frameId":frame,"x":x,"y":y,"deltaY":120}))
            .unwrap();

        assert_eq!(click["screenPoint"], expected);
        assert_eq!(scroll["screenPoint"], expected);
        let calls = desktop.calls.lock().unwrap();
        for action in ["click", "scroll"] {
            let delivered = calls.iter().find(|call| call["action"] == action).unwrap();
            assert_eq!(delivered["screenX"], expected["x"]);
            assert_eq!(delivered["screenY"], expected["y"]);
            let receipt = if action == "click" { &click } else { &scroll };
            assert_eq!(delivered["screenX"], receipt["screenPoint"]["x"]);
            assert_eq!(delivered["screenY"], receipt["screenPoint"]["y"]);
        }
        drop(calls);
        drop(service);
        std::fs::remove_dir_all(path).unwrap();
    }
}

#[test]
fn given_type_or_press_when_succeeded_then_receipt_does_not_claim_a_screen_point() {
    let (mut service, _, path) = setup();
    let connection = connect(&mut service);
    let frame = observe(&mut service, &connection);

    for request in [
        json!({"action":"type","connectionId":connection,"frameId":frame,"text":"hello"}),
        json!({"action":"press","connectionId":connection,"frameId":frame,"key":"Enter"}),
    ] {
        let receipt = service.execute(request).unwrap();
        assert!(receipt.get("screenPoint").is_none());
    }
    drop(service);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_capture_exceeds_1600_pixel_edge_when_observing_then_reject_with_image_too_large() {
    let (mut service, desktop, path) = setup();
    desktop.set_capture_size(1601, 1200);
    let connection = connect(&mut service);

    let error = service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap_err();

    assert_eq!(error.code, "IMAGE_TOO_LARGE");
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
    drop(service);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_pixel_coordinate_outside_frame_when_clicking_then_reject_without_native_input() {
    let (mut service, desktop, path) = setup();
    let connection = connect(&mut service);
    let frame = observe(&mut service, &connection);

    let error = service
        .execute(json!({"action":"click","connectionId":connection,"frameId":frame,"x":1600,"y":0}))
        .unwrap_err();

    assert_eq!(error.code, "INVALID_ARGUMENT");
    assert!(!desktop
        .calls
        .lock()
        .unwrap()
        .iter()
        .any(|call| call["action"] == "click"));
    drop(service);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_two_frames_when_older_frame_is_reused_then_it_is_not_rejected_as_not_latest() {
    let (mut service, _, path) = setup();
    let connection = connect(&mut service);
    let frame = observe(&mut service, &connection);
    observe(&mut service, &connection);
    service
        .execute(json!({"action":"press","connectionId":connection,"frameId":frame,"key":"Enter"}))
        .unwrap();
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn given_window_moved_when_input_requested_then_no_native_input_is_sent() {
    let (mut service, desktop, path) = setup();
    let connection = connect(&mut service);
    let frame = observe(&mut service, &connection);
    *desktop.moved.lock().unwrap() = true;
    let error = service
        .execute(json!({"action":"click","connectionId":connection,"frameId":frame,"x":1,"y":1}))
        .unwrap_err();
    assert_eq!(error.code, "FRAME_GEOMETRY_CHANGED");
    assert!(!desktop
        .calls
        .lock()
        .unwrap()
        .iter()
        .any(|v| v["action"] == "click"));
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn given_connection_exists_when_another_agent_connects_then_connection_is_not_stolen_or_disclosed()
{
    let (mut service, _, path) = setup();
    let connection = connect(&mut service);
    assert_eq!(
        service
            .execute(json!({"action":"connect","windowId":42}))
            .unwrap_err()
            .code,
        "CONNECTION_BUSY"
    );
    let status = service.execute(json!({"action":"status"})).unwrap();
    assert!(!status.to_string().contains(&connection));
    assert_eq!(status["connected"], true);
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn given_invalid_credentials_or_parameters_then_input_is_never_sent() {
    let (mut service, desktop, path) = setup();
    let connection = connect(&mut service);
    let frame = observe(&mut service, &connection);
    for request in [
        json!({"action":"click","connectionId":"wrong","frameId":frame,"x":1,"y":1}),
        json!({"action":"click","connectionId":connection,"frameId":frame,"x":1600,"y":1}),
        json!({"action":"type","connectionId":connection,"frameId":frame,"text":"bad\ntext"}),
        json!({"action":"press","connectionId":connection,"frameId":frame,"key":"Cmd+Q"}),
        json!({"action":"scroll","connectionId":connection,"frameId":frame,"x":1,"y":1,"deltaY":0}),
    ] {
        assert!(service.execute(request).is_err());
    }
    assert!(!desktop
        .calls
        .lock()
        .unwrap()
        .iter()
        .any(|v| ["click", "type", "scroll", "press"].contains(&v["action"].as_str().unwrap())));
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn given_disconnect_when_old_credentials_are_used_then_connection_and_images_are_gone() {
    let (mut service, _, path) = setup();
    let connection = connect(&mut service);
    observe(&mut service, &connection);
    service
        .execute(json!({"action":"disconnect","connectionId":connection}))
        .unwrap();
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
    assert_eq!(
        service
            .execute(json!({"action":"observe","connectionId":connection}))
            .unwrap_err()
            .code,
        "CONNECTION_INVALID"
    );
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn given_33_frames_when_oldest_is_used_then_bounded_retention_is_explicit() {
    let (mut service, _, path) = setup();
    let connection = connect(&mut service);
    let oldest = observe(&mut service, &connection);
    for _ in 0..32 {
        observe(&mut service, &connection);
    }
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 32);
    assert_eq!(
        service
            .execute(
                json!({"action":"press","connectionId":connection,"frameId":oldest,"key":"Enter"})
            )
            .unwrap_err()
            .code,
        "FRAME_UNKNOWN"
    );
    std::fs::remove_dir_all(path).unwrap();
}
#[test]
fn given_target_closed_when_observing_then_control_is_released() {
    let (mut service, desktop, path) = setup();
    let connection = connect(&mut service);
    *desktop.missing.lock().unwrap() = true;
    assert_eq!(
        service
            .execute(json!({"action":"observe","connectionId":connection}))
            .unwrap_err()
            .code,
        "WINDOW_UNAVAILABLE"
    );
    assert_eq!(
        service.execute(json!({"action":"status"})).unwrap()["connected"],
        false
    );
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_native_geometry_race_when_input_rejected_then_public_error_is_normalized_and_connection_kept(
) {
    struct GeometryRace(Desktop);
    impl Native for GeometryRace {
        fn request(&mut self, request: Value) -> Result<Value> {
            if request["action"] == "press" {
                Err(Error::new("IMAGE_GEOMETRY_CHANGED", "原生二次校验几何变化"))
            } else {
                self.0.request(request)
            }
        }
    }
    let (service, desktop, path) = setup();
    drop(service);
    let mut service = Service::new(GeometryRace(desktop), path.clone());
    let connection = service
        .execute(json!({"action":"connect","windowId":42}))
        .unwrap()["connectionId"]
        .clone();
    let frame = service
        .execute(json!({"action":"observe","connectionId":connection}))
        .unwrap()["frameId"]
        .clone();
    let error = service
        .execute(json!({"action":"press","connectionId":connection,"frameId":frame,"key":"Enter"}))
        .unwrap_err();
    assert_eq!(error.code, "FRAME_GEOMETRY_CHANGED");
    assert_eq!(
        service.execute(json!({"action":"status"})).unwrap()["connected"],
        true
    );
    assert!(service
        .execute(json!({"action":"observe","connectionId":connection}))
        .is_ok());
    drop(service);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_finite_but_overflowing_bounds_when_connecting_then_invalid_coordinate_mapping_is_rejected()
{
    struct InvalidBounds(Desktop);
    impl Native for InvalidBounds {
        fn request(&mut self, request: Value) -> Result<Value> {
            let mut response = self.0.request(request.clone())?;
            if request["action"] == "windows" {
                response["windows"][0]["bounds"] =
                    json!({"x":f64::MAX,"y":0,"width":f64::MAX,"height":600});
            }
            Ok(response)
        }
    }
    let (service, desktop, path) = setup();
    drop(service);
    let mut service = Service::new(InvalidBounds(desktop), path.clone());
    assert_eq!(
        service
            .execute(json!({"action":"connect","windowId":42}))
            .unwrap_err()
            .code,
        "HELPER_PROTOCOL"
    );
    drop(service);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn given_native_capture_backend_when_observing_then_only_known_backend_labels_are_exposed() {
    struct BackendInfo(Desktop, Value);
    impl Native for BackendInfo {
        fn request(&mut self, request: Value) -> Result<Value> {
            let mut result = self.0.request(request.clone())?;
            if request["action"] == "observe" {
                result["captureBackend"] = self.1.clone();
            }
            Ok(result)
        }
    }
    for backend in [
        json!("screencapture"),
        json!("screen-capture-kit"),
        json!("private-token arbitrary backend text"),
        json!({"secret": "private-token"}),
    ] {
        let (original, desktop, path) = setup();
        drop(original);
        let mut service = Service::new(BackendInfo(desktop, backend.clone()), path.clone());
        let connection = service
            .execute(json!({"action":"connect","windowId":42}))
            .unwrap()["connectionId"]
            .clone();
        let frame = service
            .execute(json!({"action":"observe","connectionId":connection}))
            .unwrap();
        if backend == "screencapture" || backend == "screen-capture-kit" {
            assert_eq!(frame["captureBackend"], backend);
        } else {
            assert!(frame.get("captureBackend").is_none());
            assert!(!frame.to_string().contains("private-token"));
        }
        drop(service);
        std::fs::remove_dir_all(path).unwrap();
    }
}

#[test]
fn given_same_frame_ocr_when_observing_then_forward_text_without_triggering_input() {
    let (mut service, desktop, path) = setup();
    let ocr = json!({"status":"ok","items":[{"text":"上传视频","bbox":{"x":10,"y":20,"width":100,"height":40},"center":{"x":60,"y":40},"confidence":0.9}],"truncated":false});
    *desktop.ocr.lock().unwrap() = Some(ocr.clone());
    let connection = connect(&mut service);
    let frame = service.execute(json!({"action":"observe","connectionId":connection})).unwrap();
    assert_eq!(frame["ocr"], ocr);
    assert_eq!(frame["untrusted"], true);
    assert!(!desktop.calls.lock().unwrap().iter().any(|v| ["click","press","type","scroll"].contains(&v["action"].as_str().unwrap())));
    *desktop.ocr.lock().unwrap() = Some(json!({"status":"bad"}));
    let frame = service.execute(json!({"action":"observe","connectionId":connection})).unwrap();
    assert_eq!(frame["ocr"]["status"], "unavailable");
    assert!(frame["frameId"].is_string());
    std::fs::remove_dir_all(path).unwrap();
}
