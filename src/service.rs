use crate::protocol::{
    fields, integer, random_id, string, Error, Result, Scope, USER_PAUSED_PUBLIC_MESSAGE,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

pub trait Native: Send {
    fn request(&mut self, request: Value) -> Result<Value>;
    fn set_input_epoch(&mut self, _epoch: Option<u64>) {}
    fn set_owner_guard(&mut self, _guard: Option<Arc<dyn Fn() -> bool + Send + Sync>>) {}
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct Bounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Bounds {
    fn valid(self) -> bool {
        [
            self.x,
            self.y,
            self.width,
            self.height,
            self.x + self.width,
            self.y + self.height,
        ]
        .iter()
        .all(|v| v.is_finite())
            && self.width >= 50.0
            && self.height >= 50.0
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub window_id: u32,
    pub pid: i32,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_name: Option<String>,
    pub bounds: Bounds,
}
#[derive(Clone)]
struct Frame {
    id: String,
    path: PathBuf,
    width: u32,
    height: u32,
    bounds: Bounds,
}
struct Connection {
    id: String,
    window: Window,
    frames: VecDeque<Frame>,
    release_pending: bool,
}
pub struct Service<N: Native> {
    native: N,
    frames_dir: PathBuf,
    scope: Scope,
    connection: Option<Connection>,
    decider: Box<dyn crate::jev::Decision>,
    operation_cancel: Option<Arc<AtomicBool>>,
    operation_owner: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
    preserve_pause: bool,
}
impl<N: Native> Service<N> {
    pub fn new(native: N, frames_dir: PathBuf) -> Self {
        Self::with_scope(native, frames_dir, Scope::Chrome)
    }

    pub fn with_scope(native: N, frames_dir: PathBuf, scope: Scope) -> Self {
        Self {
            native,
            frames_dir,
            scope,
            connection: None,
            decider: Box::new(crate::jev::JevClient::default()),
            operation_cancel: None,
            operation_owner: None,
            preserve_pause: false,
        }
    }
    pub fn with_decider(mut self, decider: Box<dyn crate::jev::Decision>) -> Self {
        self.decider = decider;
        self
    }

    pub(crate) fn execute_remote_read(
        &mut self,
        request: Value,
        preserve_pause: bool,
    ) -> Result<Value> {
        self.preserve_pause = preserve_pause;
        let result = self.execute(request);
        self.preserve_pause = false;
        result
    }
    pub(crate) fn connected(&self) -> bool {
        self.connection.is_some()
    }
    pub(crate) fn clear_remote_connection(&mut self) {
        self.clear();
    }
    pub(crate) fn execute_remote(
        &mut self,
        request: Value,
        epoch: u64,
        cancelled: Arc<AtomicBool>,
        stopping: Arc<AtomicBool>,
        owner_alive: Arc<dyn Fn() -> bool + Send + Sync>,
    ) -> Result<Value> {
        self.native.set_owner_guard(Some(owner_alive.clone()));
        self.operation_owner = Some(owner_alive);
        self.native.set_input_epoch(Some(epoch));
        self.decider.set_cancellation(Some(cancelled.clone()));
        self.operation_cancel = Some(cancelled);
        let result = self
            .check_operation_cancelled()
            .and_then(|()| self.execute(request))
            .and_then(|value| {
                self.check_operation_cancelled()?;
                Ok(value)
            });
        self.operation_cancel = None;
        self.operation_owner = None;
        self.native.set_owner_guard(None);
        self.decider.set_cancellation(Some(stopping));
        self.native.set_input_epoch(None);
        result
    }
    fn check_operation_cancelled(&self) -> Result<()> {
        if self
            .operation_cancel
            .as_ref()
            .is_some_and(|flag| flag.load(Ordering::Acquire))
            || self.operation_owner.as_ref().is_some_and(|alive| !alive())
        {
            return Err(Error::new("USER_PAUSED", USER_PAUSED_PUBLIC_MESSAGE));
        }
        Ok(())
    }
    pub fn execute(&mut self, request: Value) -> Result<Value> {
        let action = string(&request, "action")?;
        let allowed: &[&str] = match action {
            "chrome-start" => &["action", "url", "maxWidthPx", "profile"],
            "status" | "apps" => &["action"],
            "windows" => &["action", "bundleId"],
            "permissions" => &["action", "request"],
            "connect" => &["action", "windowId"],
            "observe" | "disconnect" => &["action", "connectionId"],
            "click" => &["action", "connectionId", "frameId", "x", "y", "clickCount"],
            "click-target" => &[
                "action",
                "connectionId",
                "target",
                "jevKey",
                "jevUrl",
                "jevModel",
                "jevProtocol",
            ],
            "scroll" => &["action", "connectionId", "frameId", "x", "y", "deltaY"],
            "type" => &["action", "connectionId", "frameId", "text"],
            "press" => &["action", "connectionId", "frameId", "key"],
            "select-file" => &["action", "connectionId", "path"],
            _ => return Err(Error::invalid("不支持的命令")),
        };
        fields(&request, allowed)?;
        let result = match action {
            "status" => Ok(
                json!({"running":true,"connected":self.connection.is_some(),"window":self.connection.as_ref().map(|c| &c.window),
                    "version":env!("CARGO_PKG_VERSION"),"jev":{"protocol":crate::jev::DECISION_PROTOCOL,"dynamicEndpoint":true}}),
            ),
            "apps" => {
                self.require_scope(Scope::Desktop)?;
                self.native.request(json!({"action":"apps"}))
            }
            "windows" => self.windows(&request),
            "permissions" => {
                if request.get("request").is_some_and(|v| !v.is_boolean()) {
                    return Err(Error::invalid("request 必须为布尔值"));
                }
                let requested = request["request"].as_bool().unwrap_or(false);
                self.native.request(json!({"action":"permissions","request":requested})).and_then(|result| {
                    let automation = &result["chromeAutomation"];
                    if automation["target"] != "com.google.Chrome"
                        || automation["requested"] != requested
                        || !automation["granted"].is_boolean()
                        || !automation["status"].is_string()
                        || automation["osStatus"].as_i64().is_none() {
                        return Err(Error::new("HELPER_UPGRADE_REQUIRED", "原生helper未完整报告Chrome自动化授权；请升级本任务helper，不要把旧版结果当成已申请授权"));
                    }
                    Ok(result)
                })
            }
            "connect" => self.connect(&request),
            "chrome-start" => self.chrome_start(&request),
            _ => {
                let connection_id = string(&request, "connectionId")?;
                let connection = self.require_connection(connection_id)?;
                if connection.release_pending && !matches!(action, "disconnect" | "observe") {
                    return Err(Error::new(
                        "CANCEL_UNCONFIRMED",
                        "原生 helper 未确认停止；连接仍保留，请勿继续输入",
                    ));
                }
                match action {
                    "disconnect" => self.disconnect(),
                    "observe" => self.observe(),
                    "select-file" => self.select_file(&request),
                    "click-target" => self.click_target(&request),
                    _ => self.input(&request),
                }
            }
        };
        let result = result.map_err(|mut error| {
            if error.code == "IMAGE_GEOMETRY_CHANGED" {
                error.code = "FRAME_GEOMETRY_CHANGED".into();
            }
            error
        });
        if let Err(error) = &result {
            match error.code.as_str() {
                "WINDOW_UNAVAILABLE" | "CHROME_WINDOW_UNAVAILABLE" => {
                    // 窗口失效时 helper 通常仍存活；尽力撤销 toast/执行门禁，
                    // 但保留最初窗口错误作为公开结果。
                    if !self.preserve_pause && self.operation_cancel.is_none() {
                        if action != "disconnect" {
                            let _ = self.cancel_native();
                        }
                        self.clear();
                    }
                }
                "HELPER_EOF" | "HELPER_TIMEOUT" | "HELPER_PROTOCOL" => self.clear(),
                _ => {}
            }
        }
        result
    }
    fn require_scope(&self, expected: Scope) -> Result<()> {
        if self.scope == expected {
            Ok(())
        } else {
            Err(Error::new(
                "SCOPE_MISMATCH",
                "该命令不适用于当前桌面控制模式",
            ))
        }
    }

    fn windows(&mut self, request: &Value) -> Result<Value> {
        let bundle_id = match request.get("bundleId") {
            None => None,
            Some(Value::String(value)) if valid_bundle_id(value) => Some(value.as_str()),
            Some(_) => return Err(Error::invalid("bundleId 必须为非空字符串")),
        };
        if bundle_id.is_some() {
            self.require_scope(Scope::Desktop)?;
        }
        let mut result = self.native.request(json!({"action":"windows"}))?;
        if let Some(bundle_id) = bundle_id {
            let windows = result["windows"]
                .as_array_mut()
                .ok_or_else(|| Error::new("HELPER_PROTOCOL", "原生窗口列表无效"))?;
            windows.retain(|window| window["bundleId"] == bundle_id);
        }
        Ok(result)
    }

    fn cancel_native(&mut self) -> Result<()> {
        let receipt = self.native.request(json!({"action":"cancel"}))?;
        if receipt["cancelled"] != true {
            return Err(Error::new(
                "CANCEL_UNCONFIRMED",
                "原生 helper 未确认停止；连接仍保留，请勿继续输入",
            ));
        }
        Ok(())
    }

    fn disconnect(&mut self) -> Result<Value> {
        self.connection
            .as_mut()
            .expect("已校验连接")
            .release_pending = true;
        self.cancel_native()?;
        self.clear();
        Ok(json!({"connected":false}))
    }

    fn require_connection(&self, id: &str) -> Result<&Connection> {
        self.connection
            .as_ref()
            .filter(|c| c.id == id)
            .ok_or_else(|| {
                Error::new(
                    "CONNECTION_INVALID",
                    "控制连接不存在或凭据不匹配，请显式 connect",
                )
            })
    }
    fn chrome_start(&mut self, request: &Value) -> Result<Value> {
        if self.connection.is_some() {
            return Err(Error::new(
                "CONNECTION_BUSY",
                "已有控制连接；启动不会替换原连接或绕过暂停，请先用原连接凭据 disconnect",
            ));
        }
        let width = integer(request, "maxWidthPx")?;
        if !(400..=1600).contains(&width) {
            return Err(Error::invalid("maxWidthPx 必须为400..1600原始像素"));
        }
        if let Some(url) = request.get("url") {
            let url = url
                .as_str()
                .ok_or_else(|| Error::invalid("URL必须为字符串"))?;
            let parsed = url::Url::parse(url)
                .map_err(|_| Error::invalid("Chrome URL 必须为绝对 HTTP(S) 地址"))?;
            if url.len() > 4096
                || url.chars().any(char::is_control)
                || !["http", "https"].contains(&parsed.scheme())
                || parsed.host_str().is_none()
                || !parsed.username().is_empty()
                || parsed.password().is_some()
            {
                return Err(Error::invalid(
                    "Chrome URL 必须为不含用户凭据的绝对 HTTP(S) 地址",
                ));
            }
        }
        let requested_profile = request
            .get("profile")
            .map(|raw| {
                let name = raw
                    .as_str()
                    .ok_or_else(|| Error::invalid("profile必须为Chrome显示名称字符串"))?;
                crate::config::validate_chrome_profile(name)?;
                Ok(name)
            })
            .transpose()?;
        let permissions = self
            .native
            .request(json!({"action":"permissions","request":false}))?;
        if permissions["screenRecording"] != true {
            return Err(Error::new(
                "SCREEN_PERMISSION_REQUIRED",
                "Chrome 启动连接需要屏幕录制权限；尚未创建窗口",
            ));
        }
        if permissions["accessibility"] != true {
            return Err(Error::new(
                "ACCESSIBILITY_PERMISSION_REQUIRED",
                "Chrome 窗口布局需要辅助功能权限；尚未创建窗口",
            ));
        }
        let mut native_request = request.clone();
        let marker_path = if requested_profile.is_some() {
            let path = self
                .frames_dir
                .join(format!("mcc-profile-{}.html", random_id()?));
            native_request["profileMarkerPath"] = json!(path);
            Some(path)
        } else {
            None
        };
        let launched = self.native.request(native_request);
        // Own the resource in the existing daemon/frames lifecycle, including helper
        // failures and cancellation. The browser never receives account data here.
        if let Some(path) = marker_path {
            let _ = std::fs::remove_file(path);
        }
        let launched = launched?;
        let selected_profile = if let Some(name) = requested_profile {
            let raw = &launched["profile"];
            let valid = raw.as_object().is_some_and(|p| p.len() == 3)
                && raw["name"].as_str() == Some(name)
                && raw["directory"].as_str().is_some_and(|directory| {
                    !directory.is_empty()
                        && directory.len() <= 255
                        && ![".", "..", "Guest Profile", "System Profile"].contains(&directory)
                        && !directory.contains(['/', '\\'])
                        && !directory.chars().any(char::is_control)
                        && raw["path"].as_str().is_some_and(|path| {
                            let p = Path::new(path);
                            path.len() <= 4096
                                && !path.chars().any(char::is_control)
                                && p.is_absolute()
                                && p.file_name().and_then(|v| v.to_str()) == Some(directory)
                                && !p.components().any(|c| {
                                    matches!(
                                        c,
                                        std::path::Component::ParentDir
                                            | std::path::Component::CurDir
                                    )
                                })
                        })
                });
            if !valid {
                return Err(Error::new(
                    "PROFILE_UNVERIFIED",
                    "原生返回的profile身份无法与指定名称及目录对应；未建立连接",
                ));
            }
            Some(raw.clone())
        } else {
            None
        };
        let window: Window = decode(launched["window"].clone())?;
        if window.window_id == 0
            || window.pid <= 0
            || window.bundle_id.as_deref() != Some("com.google.Chrome")
            || !window.bounds.valid()
        {
            return Err(Error::new("HELPER_PROTOCOL", "新建 Chrome 窗口身份无效"));
        }
        let mut connected =
            self.connect(&json!({"action":"connect","windowId":window.window_id}))?;
        let verified: Window = decode(connected["window"].clone())?;
        if verified.pid != window.pid
            || verified.bundle_id != window.bundle_id
            || verified.bounds != window.bounds
        {
            // Keep the newly connected identity only on a completely verified handoff.
            let _ = self.disconnect();
            return Err(Error::new(
                "WINDOW_CHANGED",
                "启动与连接之间窗口身份或几何变化；未执行输入",
            ));
        }
        if let Some(profile) = selected_profile {
            connected["profile"] = profile;
        }
        connected["layout"] = launched["layout"].clone();
        connected["created"] = json!(true);
        Ok(connected)
    }

    fn connect(&mut self, request: &Value) -> Result<Value> {
        let id = u32::try_from(integer(request, "windowId")?)
            .ok()
            .filter(|v| *v > 0)
            .ok_or_else(|| Error::invalid("windowId 必须为正整数"))?;
        if self.connection.is_some() {
            return Err(Error::new(
                "CONNECTION_BUSY",
                "已有控制连接；请先用原连接凭据 disconnect，或显式停止后台进程",
            ));
        }
        let permissions = self
            .native
            .request(json!({"action":"permissions","request":false}))?;
        if permissions["screenRecording"] != true {
            return Err(Error::new(
                "SCREEN_PERMISSION_REQUIRED",
                "请为原生 helper 授予屏幕录制权限；可运行 permissions --request",
            ));
        }
        let windows = self.native.request(json!({"action":"windows"}))?;
        let selected = windows["windows"]
            .as_array()
            .and_then(|items| items.iter().find(|v| v["windowId"] == id))
            .cloned()
            .ok_or_else(|| {
                Error::new(
                    "WINDOW_UNAVAILABLE",
                    "找不到指定应用窗口，请重新执行 windows",
                )
            })?;
        let window: Window = decode(selected)?;
        if !window.bounds.valid() || window.pid <= 0 {
            return Err(Error::new("HELPER_PROTOCOL", "原生窗口几何或身份无效"));
        }
        match (self.scope, window.bundle_id.as_deref()) {
            (Scope::Desktop, Some(bundle_id)) if valid_bundle_id(bundle_id) => {}
            (Scope::Desktop, _) => {
                return Err(Error::new("HELPER_PROTOCOL", "通用模式窗口应用身份无效"));
            }
            (Scope::Chrome, Some("com.google.Chrome")) | (Scope::Chrome, None) => {}
            (Scope::Chrome, Some(_)) => {
                return Err(Error::new(
                    "HELPER_PROTOCOL",
                    "Chrome 模式返回了其他应用身份",
                ));
            }
        }
        // 仅对已选窗口只读复核，并让原生层在进入模态对话框前准备顶部提示区域。
        let mut query = json!({"action":"window","windowId":window.window_id,"pid":window.pid,"prepareToast":true});
        if let Some(bundle_id) = &window.bundle_id {
            query["bundleId"] = json!(bundle_id);
        }
        let verified: Window = decode(self.native.request(query)?["window"].clone())?;
        if verified.window_id != window.window_id
            || verified.pid != window.pid
            || verified.bundle_id != window.bundle_id
            || !verified.bounds.valid()
        {
            return Err(Error::new(
                "WINDOW_UNAVAILABLE",
                "连接期间目标应用窗口身份变化",
            ));
        }
        let window = verified;
        let id = random_id()?;
        let result =
            json!({"connectionId":id,"connected":true,"window":window,"permissions":permissions});
        self.connection = Some(Connection {
            id,
            window,
            frames: VecDeque::new(),
            release_pending: false,
        });
        Ok(result)
    }
    fn current_window(&mut self) -> Result<Window> {
        let target = &self.connection.as_ref().expect("已校验连接").window;
        let mut request = json!({"action":"window","windowId":target.window_id,"pid":target.pid});
        if let Some(bundle_id) = &target.bundle_id {
            request["bundleId"] = json!(bundle_id);
        }
        let response = self.native.request(request)?;
        let window: Window = decode(response["window"].clone())?;
        if window.window_id != target.window_id
            || window.pid != target.pid
            || window.bundle_id != target.bundle_id
            || (self.scope == Scope::Desktop && window.bundle_id.is_none())
            || !window.bounds.valid()
        {
            return Err(Error::new(
                "WINDOW_UNAVAILABLE",
                "目标应用窗口身份或几何发生异常",
            ));
        }
        Ok(window)
    }
    fn select_file(&mut self, request: &Value) -> Result<Value> {
        let identity = &self
            .connection
            .as_ref()
            .expect("已校验连接")
            .window
            .bundle_id;
        if self.scope == Scope::Desktop && identity.as_deref() != Some("com.google.Chrome") {
            return Err(Error::new(
                "FILE_DIALOG_UNSUPPORTED",
                "原生文件选择当前仅支持 Google Chrome",
            ));
        }
        let path = selectable_file_path(string(request, "path")?)?;
        let window = self.current_window()?;
        let mut native_request = json!({
            "action":"select-file",
            "windowId":window.window_id,
            "pid":window.pid,
            "path":path,
        });
        if let Some(bundle_id) = &self
            .connection
            .as_ref()
            .expect("已校验连接")
            .window
            .bundle_id
        {
            native_request["bundleId"] = json!(bundle_id);
        }
        let receipt = self
            .native
            .request(native_request)
            .map_err(sanitize_file_selection_error)?;
        if receipt["selected"] != true || receipt["dialogClosed"] != true {
            return Err(Error::new(
                "HELPER_PROTOCOL",
                "原生文件选择未返回有效完成回执",
            ));
        }
        Ok(json!({
            "selected":true,
            "dialogClosed":true,
            "connectionId":self.connection.as_ref().expect("已校验连接").id,
        }))
    }

    fn observe(&mut self) -> Result<Value> {
        let window = self.current_window()?;
        let id = random_id()?;
        let path = self.frames_dir.join(format!("{id}.jpg"));
        let result = self.capture(&window, &id, &path);
        if result.is_err() {
            let _ = std::fs::remove_file(&path);
        }
        result
    }
    fn capture(&mut self, window: &Window, id: &str, path: &std::path::Path) -> Result<Value> {
        let mut request = json!({"action":"observe","windowId":window.window_id,"pid":window.pid,"imagePath":path,"maxEdge":1600});
        if let Some(bundle_id) = &self
            .connection
            .as_ref()
            .expect("已校验连接")
            .window
            .bundle_id
        {
            request["bundleId"] = json!(bundle_id);
        }
        let image = self.native.request(request)?;
        let width = dimension(&image, "width")?;
        let height = dimension(&image, "height")?;
        let bounds: Bounds = decode(image["bounds"].clone())?;
        if !bounds.valid() || bounds != window.bounds {
            return Err(Error::new(
                "FRAME_GEOMETRY_CHANGED",
                "截图期间窗口几何变化，请重新观察",
            ));
        }
        if image["imagePath"].as_str() != path.to_str() || image["capturedAtMs"].as_u64().is_none()
        {
            return Err(Error::new("HELPER_PROTOCOL", "截图元数据无效"));
        }
        let coordinate_space = helper_marker(&image, "coordinateSpace", "frame-pixels")?;
        let image_transform = helper_marker(&image, "imageTransform", "crop-only")?;
        if coordinate_space.is_some() != image_transform.is_some() {
            return Err(Error::new("HELPER_PROTOCOL", "原生截图坐标声明不完整"));
        }
        let metadata =
            std::fs::symlink_metadata(path).map_err(|e| Error::io("无法读取原生截图文件", e))?;
        if !metadata.is_file() || metadata.len() == 0 || metadata.len() >= 1024 * 1024 {
            return Err(Error::new("HELPER_PROTOCOL", "原生截图文件类型或大小无效"));
        }
        let connection = self.connection.as_mut().expect("已校验连接");
        connection.window = window.clone();
        connection.frames.push_back(Frame {
            id: id.into(),
            path: path.into(),
            width,
            height,
            bounds,
        });
        if connection.frames.len() > 32 {
            if let Some(oldest) = connection.frames.pop_front() {
                let _ = std::fs::remove_file(oldest.path);
            }
        }
        let mut result = json!({"connectionId":connection.id,"frameId":id,"imagePath":path,"width":width,"height":height,"bounds":bounds,"capturedAtMs":image["capturedAtMs"],"untrusted":true});
        if let Some(coordinate_space) = coordinate_space {
            result["coordinateSpace"] = json!(coordinate_space);
        }
        if let Some(image_transform) = image_transform {
            result["imageTransform"] = json!(image_transform);
        }
        if let Some(backend @ ("screen-capture-kit" | "screencapture")) =
            image["captureBackend"].as_str()
        {
            result["captureBackend"] = json!(backend);
        }
        if let Some(ocr) = image.get("ocr") {
            result["ocr"] = crate::ocr::sanitize(ocr, width, height);
        }
        Ok(result)
    }
    fn click_target(&mut self, request: &Value) -> Result<Value> {
        use std::time::Instant;
        let total = Instant::now();
        if request["jevProtocol"] != crate::jev::DECISION_PROTOCOL {
            return Err(Error::new(
                "JEV_PROTOCOL_MISMATCH",
                "动态 Decisions 契约不匹配；未发送网络请求",
            ));
        }
        let target = string(request, "target")?;
        crate::target::validate_target(target)?;
        let model = crate::config::Model {
            // Persisted enable/disable is resolved by the CLI before daemon startup.
            enabled: true,
            url: string(request, "jevUrl")?.into(),
            model: string(request, "jevModel")?.into(),
            api_key: crate::jev::resolve_key(request.get("jevKey").and_then(Value::as_str), None)?,
        };
        crate::config::validate_model(&model)?;
        let observation = self.observe()?;
        let observe_ms = total.elapsed().as_millis() as u64;
        if observation["coordinateSpace"] != "frame-pixels"
            || observation["imageTransform"] != "crop-only"
        {
            return Err(Error::new(
                "HELPER_UPGRADE_REQUIRED",
                "语义点击需要原像素截图坐标声明，请使用匹配的原生 helper",
            ));
        }
        let candidates = crate::target::Candidates::from_observation(&observation)?;
        let decision_start = Instant::now();
        let response = self.decider.decide(
            &model.url,
            &model.api_key,
            &candidates.request(target, &model.model),
        )?;
        self.check_operation_cancelled()?;
        let decision_ms = decision_start.elapsed().as_millis() as u64;
        let selection = candidates.select(&response, &model.model)?;
        let click = json!({"action":"click","connectionId":request["connectionId"],
            "frameId":observation["frameId"],"x":selection.x,"y":selection.y,"clickCount":1});
        let click_start = Instant::now();
        let mut receipt = self.input(&click)?;
        receipt["status"] = json!("click_sent");
        receipt["effectVerified"] = json!(false);
        receipt["untrusted"] = json!(true);
        receipt["selection"] = json!({"candidateId":selection.id,"text":selection.text,
            "center":{"x":selection.x,"y":selection.y},"model":selection.model,"requestedModel":model.model,
            "confidence":selection.confidence,"probability":selection.probability});
        receipt["timingMs"] = json!({"observe":observe_ms,"decision":decision_ms,
            "click":click_start.elapsed().as_millis() as u64,"total":total.elapsed().as_millis() as u64});
        Ok(receipt)
    }

    fn input(&mut self, request: &Value) -> Result<Value> {
        let frame_id = string(request, "frameId")?;
        let frame = self
            .connection
            .as_ref()
            .expect("已校验连接")
            .frames
            .iter()
            .find(|f| f.id == frame_id)
            .cloned()
            .ok_or_else(|| {
                Error::new(
                    "FRAME_UNKNOWN",
                    "找不到本连接的帧，或已超出最近 32 帧保留范围；请重新 observe",
                )
            })?;
        let action = string(request, "action")?;
        let mut native = json!({"action":action,"expectedBounds":frame.bounds});
        let mut screen_point = None;
        match action {
            "click" | "scroll" => {
                let x = integer(request, "x")?;
                let y = integer(request, "y")?;
                if x < 0 || y < 0 || x >= frame.width as i64 || y >= frame.height as i64 {
                    return Err(Error::invalid("坐标超出截图范围"));
                }
                let screen_x = frame.bounds.x + x as f64 / frame.width as f64 * frame.bounds.width;
                let screen_y =
                    frame.bounds.y + y as f64 / frame.height as f64 * frame.bounds.height;
                native["screenX"] = json!(screen_x);
                native["screenY"] = json!(screen_y);
                screen_point = Some(json!({"x":screen_x,"y":screen_y}));
                if action == "click" {
                    let count = if request.get("clickCount").is_some() {
                        integer(request, "clickCount")?
                    } else {
                        1
                    };
                    if ![1, 2].contains(&count) {
                        return Err(Error::invalid("clickCount 只能为 1 或 2"));
                    }
                    native["clickCount"] = json!(count);
                } else {
                    let delta = integer(request, "deltaY")?;
                    if delta == 0 || !(-1200..=1200).contains(&delta) {
                        return Err(Error::invalid("deltaY 必须为 [-1200,1200] 内的非零整数"));
                    }
                    native["deltaY"] = json!(delta);
                }
            }
            "type" => {
                let text = string(request, "text")?;
                if text.chars().count() > 4096 || text.chars().any(char::is_control) {
                    return Err(Error::invalid(
                        "文本必须为 1–4096 个 Unicode 字符且不能包含控制字符",
                    ));
                }
                native["text"] = json!(text);
            }
            "press" => {
                let key = string(request, "key")?;
                if !KEYS.contains(&key) {
                    return Err(Error::invalid("按键不在允许的 21 个按键或组合键中"));
                }
                native["key"] = json!(key);
            }
            _ => return Err(Error::invalid("不支持的输入动作")),
        }
        // 帧不消费且没有时间硬过期；只检查连接、保留范围与几何。
        let window = self.current_window()?;
        if window.bounds != frame.bounds {
            return Err(Error::new(
                "FRAME_GEOMETRY_CHANGED",
                "窗口已移动或缩放，请重新 observe 后再输入",
            ));
        }
        native["windowId"] = json!(window.window_id);
        native["pid"] = json!(window.pid);
        if let Some(bundle_id) = &self
            .connection
            .as_ref()
            .expect("已校验连接")
            .window
            .bundle_id
        {
            native["bundleId"] = json!(bundle_id);
        }
        let receipt = self.native.request(native)?;
        if receipt["sent"] != true {
            return Err(Error::new("HELPER_PROTOCOL", "原生输入未返回投递回执"));
        }
        let mut result = json!({"sent":true,"connectionId":self.connection.as_ref().unwrap().id,"frameId":frame_id});
        if let Some(screen_point) = screen_point {
            result["screenPoint"] = screen_point;
        }
        Ok(result)
    }
    fn clear(&mut self) {
        if let Some(connection) = self.connection.take() {
            for frame in connection.frames {
                let _ = std::fs::remove_file(frame.path);
            }
        }
    }
}
impl<N: Native> Drop for Service<N> {
    fn drop(&mut self) {
        self.clear();
    }
}
fn valid_bundle_id(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 255 && !value.chars().any(char::is_control)
}

fn selectable_file_path(value: &str) -> Result<PathBuf> {
    if value.len() > 4096
        || value.chars().any(char::is_control)
        || !Path::new(value).is_absolute()
        || value
            .split('/')
            .any(|segment| segment == "." || segment == "..")
    {
        return Err(Error::invalid(
            "path 必须是绝对普通文件路径，不超过 4096 UTF-8 字节且不含控制字符或点分段",
        ));
    }

    let canonical = Path::new(value)
        .canonicalize()
        .map_err(|_| file_not_readable())?;
    let canonical_text = canonical
        .to_str()
        .filter(|path| is_valid_canonical_file_path(path))
        .ok_or_else(file_not_readable)?;
    if !std::fs::metadata(canonical_text).is_ok_and(|metadata| metadata.is_file()) {
        return Err(file_not_readable());
    }
    std::fs::File::open(canonical_text).map_err(|_| file_not_readable())?;
    Ok(canonical)
}

fn is_valid_canonical_file_path(path: &str) -> bool {
    path.len() <= 4096
        && !path.chars().any(char::is_control)
        && !path
            .split('/')
            .any(|segment| segment == "." || segment == "..")
}

fn file_not_readable() -> Error {
    Error::new("FILE_NOT_READABLE", "指定路径不是可读取的普通文件")
}

fn sanitize_file_selection_error(error: Error) -> Error {
    let (code, message) = match error.code.as_str() {
        "FILE_NOT_READABLE" => ("FILE_NOT_READABLE", "指定路径不是可读取的普通文件"),
        "FILE_DIALOG_NOT_FOUND" => ("FILE_DIALOG_NOT_FOUND", "未找到 Chrome 文件选择对话框"),
        "UNSUPPORTED" | "FILE_DIALOG_UNSUPPORTED" => (
            "FILE_DIALOG_UNSUPPORTED",
            "当前 Chrome 文件选择操作不受支持",
        ),
        "UNVERIFIED" | "FILE_DIALOG_UNVERIFIED" | "FOCUS_UNVERIFIED" => {
            ("FILE_DIALOG_UNVERIFIED", "无法验证 Chrome 文件选择结果")
        }
        "TIMEOUT" | "FILE_DIALOG_TIMEOUT" => ("FILE_DIALOG_TIMEOUT", "Chrome 文件选择操作超时"),
        "INPUT_FAILED" | "FILE_SELECTION_FAILED" => {
            ("FILE_SELECTION_FAILED", "Chrome 文件选择失败")
        }
        "USER_PAUSED" => ("USER_PAUSED", USER_PAUSED_PUBLIC_MESSAGE),
        "ACCESSIBILITY_PERMISSION_REQUIRED" => (
            "ACCESSIBILITY_PERMISSION_REQUIRED",
            "需要授予 Chrome 桌面自动化辅助功能权限",
        ),
        "CANCELLED" => ("CANCELLED", "文件选择已取消"),
        "FOCUS_LOST" => (
            "FOCUS_LOST",
            "目标 Chrome 文件选择框已失去焦点，请确认后重试",
        ),
        "ACTIVATION_FAILED" => (
            "FILE_DIALOG_UNVERIFIED",
            "无法确认目标 Chrome 文件选择框状态",
        ),
        "HELPER_TIMEOUT" => (
            "HELPER_TIMEOUT",
            "原生 helper 请求超时；当前连接已失效，请重新连接",
        ),
        "HELPER_EOF" => ("HELPER_EOF", "原生 helper 已停止"),
        "HELPER_PROTOCOL" => ("HELPER_PROTOCOL", "原生 helper 响应无效"),
        "WINDOW_UNAVAILABLE" | "CHROME_WINDOW_UNAVAILABLE" => {
            ("WINDOW_UNAVAILABLE", "授权 Chrome 窗口不可用，请重新连接")
        }
        "IMAGE_GEOMETRY_CHANGED" | "FRAME_GEOMETRY_CHANGED" => (
            "FRAME_GEOMETRY_CHANGED",
            "授权 Chrome 窗口几何已变化，请重新确认",
        ),
        _ => return Error::new("FILE_SELECTION_FAILED", "Chrome 文件选择失败"),
    };
    Error::new(code, message)
}

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T> {
    serde_json::from_value(value).map_err(|_| Error::new("HELPER_PROTOCOL", "原生响应字段无效"))
}
fn helper_marker<'a>(image: &'a Value, key: &str, expected: &'a str) -> Result<Option<&'a str>> {
    match image.get(key) {
        None => Ok(None),
        Some(Value::String(value)) if value == expected => Ok(Some(expected)),
        Some(_) => Err(Error::new("HELPER_PROTOCOL", "原生截图坐标声明无效")),
    }
}
fn dimension(image: &Value, key: &str) -> Result<u32> {
    let value = image[key]
        .as_u64()
        .filter(|value| *value > 0)
        .ok_or_else(|| Error::new("HELPER_PROTOCOL", "原生截图尺寸无效"))?;
    if value > if key == "height" { 8192 } else { 1600 } {
        return Err(Error::new(
            "IMAGE_TOO_LARGE",
            "原生截图超过宽1600/高8192原像素限制",
        ));
    }
    Ok(value as u32)
}
pub const KEYS: &[&str] = &[
    "Enter",
    "Tab",
    "Shift+Tab",
    "Escape",
    "Backspace",
    "Delete",
    "ArrowUp",
    "ArrowDown",
    "ArrowLeft",
    "ArrowRight",
    "Home",
    "End",
    "PageUp",
    "PageDown",
    "Cmd+L",
    "Cmd+A",
    "Cmd+R",
    "Cmd+T",
    "Cmd+W",
    "Alt+ArrowLeft",
    "Alt+ArrowRight",
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;

    #[derive(Default)]
    struct FakeNative {
        requests: Vec<Value>,
        replies: VecDeque<Result<Value>>,
    }

    impl Native for FakeNative {
        fn request(&mut self, request: Value) -> Result<Value> {
            self.requests.push(request.clone());
            let response = self.replies.pop_front().expect("测试应预置原生响应")?;
            if request["action"] == "observe" && response == json!({"fixtureCapture":true}) {
                let image_path = request["imagePath"].as_str().expect("截图路径");
                fs::write(image_path, [0xff, 0xd8, 0xff, 0xd9]).unwrap();
                return Ok(json!({
                    "imagePath":image_path,
                    "width":100,
                    "height":100,
                    "bounds":window()["bounds"],
                    "capturedAtMs":1
                }));
            }
            Ok(response)
        }
    }

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let unique = crate::protocol::random_id().unwrap();
            let path = std::env::temp_dir().join(format!("copis-select-file-{unique}"));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn window() -> Value {
        json!({
            "windowId": 7,
            "pid": 42,
            "title": "Chrome",
            "bounds": {"x": 10.0, "y": 20.0, "width": 900.0, "height": 700.0}
        })
    }

    fn connected_service(selection_reply: Result<Value>) -> (Service<FakeNative>, String) {
        connected_service_with_cancel_reply(selection_reply, Ok(json!({"cancelled":true})))
    }

    fn connected_service_with_cancel_reply(
        selection_reply: Result<Value>,
        cancel_reply: Result<Value>,
    ) -> (Service<FakeNative>, String) {
        let native = FakeNative {
            requests: Vec::new(),
            replies: VecDeque::from([
                Ok(json!({"screenRecording": true})),
                Ok(json!({"windows": [window()]})),
                Ok(json!({"window":window()})),
                Ok(json!({
                    "window": {
                        "windowId":7,
                        "pid":42,
                        "title":"Chrome",
                        "bounds":{"x":14.0,"y":24.0,"width":880.0,"height":680.0}
                    }
                })),
                selection_reply,
                cancel_reply,
            ]),
        };
        let mut service = Service::new(native, std::env::temp_dir());
        let connected = service
            .execute(json!({"action":"connect","windowId":7}))
            .unwrap();
        (
            service,
            connected["connectionId"].as_str().unwrap().to_owned(),
        )
    }

    #[test]
    fn permission_query_native_eof_keeps_original_connection_invalidation() {
        let (mut service, _) = connected_service(Ok(json!({"selected":true})));
        service.native.replies = VecDeque::from([Err(Error::new("HELPER_EOF", "fixture"))]);
        assert_eq!(
            service
                .execute(json!({"action":"permissions"}))
                .unwrap_err()
                .code,
            "HELPER_EOF"
        );
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            false
        );
    }

    fn select_request(connection_id: &str, path: &str) -> Value {
        json!({"action":"select-file","connectionId":connection_id,"path":path})
    }

    fn service_with_connection(
        replies: impl IntoIterator<Item = Result<Value>>,
    ) -> (Service<FakeNative>, String) {
        let connection_id = "authorized-connection".to_owned();
        let mut service = Service::new(
            FakeNative {
                requests: Vec::new(),
                replies: replies.into_iter().collect(),
            },
            std::env::temp_dir(),
        );
        service.connection = Some(Connection {
            id: connection_id.clone(),
            window: serde_json::from_value(window()).unwrap(),
            frames: VecDeque::new(),
            release_pending: false,
        });
        (service, connection_id)
    }

    fn current_window_reply() -> Value {
        json!({"window":window()})
    }

    #[test]
    fn given_native_user_paused_when_selecting_file_then_preserve_guidance_and_connection_without_raw_message(
    ) {
        let dir = TestDir::new();
        let path = dir.0.join("private file.txt");
        fs::write(&path, "content").unwrap();
        let path = path.to_str().unwrap().to_owned();
        let (mut service, connection_id) = service_with_connection([
            Ok(current_window_reply()),
            Err(Error::new(
                "USER_PAUSED",
                &format!("sensitive detail: {path}"),
            )),
        ]);

        let error = service
            .execute(select_request(&connection_id, &path))
            .unwrap_err();

        assert_eq!(error.code, "USER_PAUSED");
        assert_eq!(error.message, USER_PAUSED_PUBLIC_MESSAGE);
        assert!(!error.message.contains(&path));
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );
    }

    #[test]
    fn given_native_user_paused_when_regular_input_then_propagate_code_and_keep_connection() {
        let dir = TestDir::new();
        let frame_path = dir.0.join("frame.jpg");
        fs::write(&frame_path, b"frame").unwrap();
        let (mut service, connection_id) = service_with_connection([
            Ok(current_window_reply()),
            Err(Error::new("USER_PAUSED", "Native says USER_PAUSED")),
        ]);
        let bounds = service.connection.as_ref().unwrap().window.bounds;
        service
            .connection
            .as_mut()
            .unwrap()
            .frames
            .push_back(Frame {
                id: "frame-1".into(),
                path: frame_path,
                width: 100,
                height: 100,
                bounds,
            });

        let error = service
            .execute(json!({
                "action":"press",
                "connectionId":connection_id,
                "frameId":"frame-1",
                "key":"Enter"
            }))
            .unwrap_err();

        assert_eq!(error.code, "USER_PAUSED");
        assert_eq!(error.message, "Native says USER_PAUSED");
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );
    }

    #[test]
    fn given_existing_fatal_native_errors_when_clearing_then_do_not_send_another_cancel() {
        for code in ["HELPER_TIMEOUT", "HELPER_EOF", "HELPER_PROTOCOL"] {
            let (mut service, connection_id) =
                service_with_connection([Err(Error::new(code, "native failure"))]);

            let error = service
                .execute(json!({"action":"observe","connectionId":connection_id}))
                .unwrap_err();

            assert_eq!(error.code, code);
            assert_eq!(
                service.native.requests,
                vec![json!({"action":"window","windowId":7,"pid":42})]
            );
            assert_eq!(
                service.execute(json!({"action":"status"})).unwrap()["connected"],
                false
            );
        }
    }

    #[test]
    fn given_window_unavailable_when_cleanup_cancel_fails_then_preserve_original_error_and_clear() {
        let (mut service, connection_id) = service_with_connection([
            Err(Error::new("WINDOW_UNAVAILABLE", "window vanished")),
            Ok(json!({"cancelled":false})),
        ]);

        let error = service
            .execute(json!({"action":"observe","connectionId":connection_id}))
            .unwrap_err();

        assert_eq!(error.code, "WINDOW_UNAVAILABLE");
        assert_eq!(error.message, "window vanished");
        assert_eq!(
            service.native.requests,
            vec![
                json!({"action":"window","windowId":7,"pid":42}),
                json!({"action":"cancel"}),
            ]
        );
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            false
        );
    }

    #[test]
    fn given_disconnect_when_native_cancel_acknowledges_then_clear_connection_and_frames() {
        let dir = TestDir::new();
        let frame_path = dir.0.join("frame.jpg");
        fs::write(&frame_path, b"frame").unwrap();
        let (mut service, connection_id) = service_with_connection([Ok(json!({"cancelled":true}))]);
        let bounds = service.connection.as_ref().unwrap().window.bounds;
        service
            .connection
            .as_mut()
            .unwrap()
            .frames
            .push_back(Frame {
                id: "frame-1".into(),
                path: frame_path.clone(),
                width: 100,
                height: 100,
                bounds,
            });

        let result = service
            .execute(json!({"action":"disconnect","connectionId":connection_id}))
            .unwrap();

        assert_eq!(result, json!({"connected":false}));
        assert_eq!(service.native.requests, vec![json!({"action":"cancel"})]);
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            false
        );
        assert!(!frame_path.exists());
    }

    #[test]
    fn given_disconnect_when_native_cancel_is_not_acknowledged_then_keep_connection_and_frames() {
        let dir = TestDir::new();
        let frame_path = dir.0.join("frame.jpg");
        fs::write(&frame_path, b"frame").unwrap();
        let (mut service, connection_id) =
            service_with_connection([Ok(json!({"cancelled":false}))]);
        let bounds = service.connection.as_ref().unwrap().window.bounds;
        service
            .connection
            .as_mut()
            .unwrap()
            .frames
            .push_back(Frame {
                id: "frame-1".into(),
                path: frame_path.clone(),
                width: 100,
                height: 100,
                bounds,
            });

        let error = service
            .execute(json!({"action":"disconnect","connectionId":connection_id}))
            .unwrap_err();

        assert_eq!(error.code, "CANCEL_UNCONFIRMED");
        assert_eq!(service.native.requests, vec![json!({"action":"cancel"})]);
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );
        assert!(frame_path.exists());
    }

    #[test]
    fn given_cancel_unconfirmed_then_block_input_allow_retry_and_revoke_old_credential() {
        let dir = TestDir::new();
        let frame_path = dir.0.join("frame.jpg");
        fs::write(&frame_path, b"frame").unwrap();
        let (mut service, connection_id) = service_with_connection([
            Ok(json!({"cancelled":false})),
            Ok(json!({"cancelled":true})),
        ]);
        let bounds = service.connection.as_ref().unwrap().window.bounds;
        service
            .connection
            .as_mut()
            .unwrap()
            .frames
            .push_back(Frame {
                id: "frame-1".into(),
                path: frame_path,
                width: 100,
                height: 100,
                bounds,
            });

        let first_disconnect = service
            .execute(json!({"action":"disconnect","connectionId":connection_id}))
            .unwrap_err();
        assert_eq!(first_disconnect.code, "CANCEL_UNCONFIRMED");
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );

        let blocked = service
            .execute(json!({
                "action":"press",
                "connectionId":connection_id,
                "frameId":"frame-1",
                "key":"Enter"
            }))
            .unwrap_err();
        assert_eq!(blocked.code, "CANCEL_UNCONFIRMED");
        assert_eq!(service.native.requests, vec![json!({"action":"cancel"})]);

        assert_eq!(
            service
                .execute(json!({"action":"disconnect","connectionId":connection_id}))
                .unwrap(),
            json!({"connected":false})
        );
        assert_eq!(service.native.requests.len(), 2);
        assert_eq!(
            service
                .execute(json!({"action":"observe","connectionId":connection_id}))
                .unwrap_err()
                .code,
            "CONNECTION_INVALID"
        );
    }

    #[test]
    fn given_cancel_unconfirmed_then_block_all_inputs_allow_observe_and_retry_disconnect() {
        let dir = TestDir::new();
        let frame_path = dir.0.join("frame.jpg");
        fs::write(&frame_path, b"frame").unwrap();
        let (mut service, connection_id) = service_with_connection([
            Ok(json!({"cancelled":false})),
            Ok(current_window_reply()),
            Ok(json!({"fixtureCapture":true})),
            Ok(json!({"cancelled":true})),
        ]);
        let bounds = service.connection.as_ref().unwrap().window.bounds;
        service
            .connection
            .as_mut()
            .unwrap()
            .frames
            .push_back(Frame {
                id: "frame-1".into(),
                path: frame_path,
                width: 100,
                height: 100,
                bounds,
            });

        assert_eq!(
            service
                .execute(json!({"action":"disconnect","connectionId":connection_id}))
                .unwrap_err()
                .code,
            "CANCEL_UNCONFIRMED"
        );
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );

        for request in [
            json!({"action":"click","connectionId":connection_id,"frameId":"frame-1","x":1,"y":1}),
            json!({"action":"scroll","connectionId":connection_id,"frameId":"frame-1","x":1,"y":1,"deltaY":1}),
            json!({"action":"type","connectionId":connection_id,"frameId":"frame-1","text":"hello"}),
            json!({"action":"press","connectionId":connection_id,"frameId":"frame-1","key":"Enter"}),
            select_request(&connection_id, "/tmp/not-opened.txt"),
        ] {
            assert_eq!(
                service.execute(request).unwrap_err().code,
                "CANCEL_UNCONFIRMED"
            );
        }

        assert!(service
            .execute(json!({"action":"observe","connectionId":connection_id}))
            .is_ok());
        assert_eq!(
            service
                .execute(json!({"action":"disconnect","connectionId":connection_id}))
                .unwrap(),
            json!({"connected":false})
        );
        assert_eq!(
            service.native.requests,
            vec![
                json!({"action":"cancel"}),
                json!({"action":"window","windowId":7,"pid":42}),
                json!({"action":"observe","windowId":7,"pid":42,"maxEdge":1600,"imagePath":service.native.requests[2]["imagePath"]}),
                json!({"action":"cancel"}),
            ]
        );
        assert_eq!(
            service
                .execute(json!({"action":"observe","connectionId":connection_id}))
                .unwrap_err()
                .code,
            "CONNECTION_INVALID"
        );
    }

    #[test]
    fn given_disconnect_when_native_cancel_fails_then_do_not_report_success_or_clear_connection() {
        let (mut service, connection_id) =
            service_with_connection([Err(Error::new("CANCEL_FAILED", "native cancel failed"))]);

        let error = service
            .execute(json!({"action":"disconnect","connectionId":connection_id}))
            .unwrap_err();

        assert_eq!(error.code, "CANCEL_FAILED");
        assert_ne!(error.code, "OK");
        assert_eq!(service.native.requests, vec![json!({"action":"cancel"})]);
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );
    }

    #[test]
    fn given_no_authorized_connection_when_selecting_file_then_reject_without_native_request() {
        let native = FakeNative::default();
        let mut service = Service::new(native, std::env::temp_dir());
        let error = service
            .execute(select_request("unknown", "/tmp/file"))
            .unwrap_err();
        assert_eq!(error.code, "CONNECTION_INVALID");
        assert!(service.native.requests.is_empty());
    }

    #[test]
    fn given_file_and_authorized_connection_when_selecting_then_refresh_identity_without_frame_or_bounds_constraint(
    ) {
        let dir = TestDir::new();
        let path = dir.0.join("空 格.txt");
        fs::write(&path, "content").unwrap();
        let path = path.canonicalize().unwrap().to_str().unwrap().to_owned();
        let (mut service, connection_id) = connected_service(Ok(json!({
            "selected": true,
            "dialogClosed": true
        })));

        let result = service
            .execute(select_request(&connection_id, &path))
            .unwrap();

        assert_eq!(
            result,
            json!({
                "selected": true,
                "dialogClosed": true,
                "connectionId": connection_id
            })
        );
        assert_eq!(
            service.native.requests[3],
            json!({
                "action":"window",
                "windowId":7,
                "pid":42
            })
        );
        assert_eq!(
            service.native.requests[4],
            json!({
                "action":"select-file",
                "windowId":7,
                "pid":42,
                "path":path
            })
        );
    }

    #[test]
    fn given_unknown_request_field_when_selecting_then_reject_before_native_dialog_action() {
        let dir = TestDir::new();
        let path = dir.0.join("file.txt");
        fs::write(&path, "content").unwrap();
        let (mut service, connection_id) = connected_service(Ok(json!({
            "selected": true,
            "dialogClosed": true
        })));

        let mut request = select_request(&connection_id, path.to_str().unwrap());
        request["frameId"] = json!("must-not-be-accepted");
        let error = service.execute(request).unwrap_err();

        assert_eq!(error.code, "INVALID_ARGUMENT");
        assert_eq!(service.native.requests.len(), 3);
    }

    #[test]
    fn given_invalid_or_unreadable_path_when_selecting_then_reject_without_closing_connection() {
        let dir = TestDir::new();
        let directory = dir.0.to_str().unwrap().to_owned();
        let missing = dir.0.join("missing.txt").to_str().unwrap().to_owned();
        let mut traversal = directory.clone();
        traversal.push_str("/../secret");
        let mut dot_segment = directory.clone();
        dot_segment.push_str("/./file");
        let mut control = directory.clone();
        control.push('\n');
        let mut too_long = String::from("/");
        too_long.push_str(&"a".repeat(4096));

        for path in [
            "relative.txt".to_owned(),
            "file:///tmp/file.txt".to_owned(),
            traversal,
            dot_segment,
            control,
            too_long,
            format!("/{}", "文".repeat(1366)),
        ] {
            let (mut service, connection_id) = connected_service(Ok(json!({
                "selected": true,
                "dialogClosed": true
            })));
            let error = service
                .execute(select_request(&connection_id, &path))
                .unwrap_err();
            assert_eq!(
                error.code, "INVALID_ARGUMENT",
                "malformed path must be rejected"
            );
            assert!(!error.to_string().contains(&path));
            assert_eq!(
                service.execute(json!({"action":"status"})).unwrap()["connected"],
                true
            );
            assert_eq!(
                service.native.requests.len(),
                3,
                "invalid path must not open native dialog"
            );
        }
        for path in [
            missing,
            directory,
            format!("/{}", "a".repeat(4095)), // 4096 UTF-8 字节仍通过路径语法检查。
        ] {
            let (mut service, connection_id) = connected_service(Ok(json!({
                "selected": true,
                "dialogClosed": true
            })));
            let error = service
                .execute(select_request(&connection_id, &path))
                .unwrap_err();
            assert_eq!(error.code, "FILE_NOT_READABLE");
            assert!(!error.to_string().contains(&path));
            assert_eq!(
                service.execute(json!({"action":"status"})).unwrap()["connected"],
                true
            );
            assert_eq!(
                service.native.requests.len(),
                3,
                "unreadable path must not open native dialog"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn given_symlink_to_regular_file_when_selecting_then_send_canonical_target_path() {
        let dir = TestDir::new();
        let target = dir.0.join("目标 file.txt");
        let link = dir.0.join("alias.txt");
        fs::write(&target, "content").unwrap();
        symlink(&target, &link).unwrap();
        let canonical_target = target.canonicalize().unwrap().to_str().unwrap().to_owned();
        let (mut service, connection_id) = connected_service(Ok(json!({
            "selected": true,
            "dialogClosed": true
        })));

        service
            .execute(select_request(&connection_id, link.to_str().unwrap()))
            .unwrap();

        assert_eq!(service.native.requests[4]["path"], canonical_target);
    }

    #[test]
    fn given_native_receipt_without_both_true_flags_when_selecting_then_reject_as_protocol_error() {
        let dir = TestDir::new();
        let path = dir.0.join("file.txt");
        fs::write(&path, "content").unwrap();
        for receipt in [
            json!({"selected":false,"dialogClosed":true}),
            json!({"selected":true,"dialogClosed":false}),
            json!({"selected":true}),
            json!({"dialogClosed":true}),
        ] {
            let (mut service, connection_id) = connected_service(Ok(receipt));
            let error = service
                .execute(select_request(&connection_id, path.to_str().unwrap()))
                .unwrap_err();
            assert_eq!(error.code, "HELPER_PROTOCOL");
        }
    }

    #[test]
    fn given_recoverable_native_file_selection_error_when_selecting_then_keep_connection_and_hide_path(
    ) {
        let dir = TestDir::new();
        let path = dir.0.join("secret file.txt");
        fs::write(&path, "content").unwrap();
        let path = path.to_str().unwrap().to_owned();
        for (native_code, public_code) in [
            ("FILE_DIALOG_NOT_FOUND", "FILE_DIALOG_NOT_FOUND"),
            ("UNSUPPORTED", "FILE_DIALOG_UNSUPPORTED"),
            ("FILE_DIALOG_UNSUPPORTED", "FILE_DIALOG_UNSUPPORTED"),
            ("UNVERIFIED", "FILE_DIALOG_UNVERIFIED"),
            ("FILE_DIALOG_UNVERIFIED", "FILE_DIALOG_UNVERIFIED"),
            ("FOCUS_UNVERIFIED", "FILE_DIALOG_UNVERIFIED"),
            ("TIMEOUT", "FILE_DIALOG_TIMEOUT"),
            ("FILE_DIALOG_TIMEOUT", "FILE_DIALOG_TIMEOUT"),
            ("INPUT_FAILED", "FILE_SELECTION_FAILED"),
            ("FILE_SELECTION_FAILED", "FILE_SELECTION_FAILED"),
            ("USER_PAUSED", "USER_PAUSED"),
            (
                "ACCESSIBILITY_PERMISSION_REQUIRED",
                "ACCESSIBILITY_PERMISSION_REQUIRED",
            ),
            ("CANCELLED", "CANCELLED"),
            ("FOCUS_LOST", "FOCUS_LOST"),
            ("ACTIVATION_FAILED", "FILE_DIALOG_UNVERIFIED"),
        ] {
            let (mut service, connection_id) = connected_service(Err(Error::new(
                native_code,
                &format!("native failure for {path}"),
            )));
            let error = service
                .execute(select_request(&connection_id, &path))
                .unwrap_err();
            assert_eq!(error.code, public_code);
            assert!(!error.to_string().contains(&path));
            assert!(!error.message.contains("native failure"));
            assert_eq!(
                service.execute(json!({"action":"status"})).unwrap()["connected"],
                true
            );
        }

        let (mut service, connection_id) = connected_service(Err(Error::new(
            "UNRECOGNIZED_NATIVE_ERROR",
            &format!("private path {path} leaked by native helper"),
        )));
        let error = service
            .execute(select_request(&connection_id, &path))
            .unwrap_err();
        assert_eq!(error.code, "FILE_SELECTION_FAILED");
        assert!(!error.to_string().contains(&path));
        assert!(!error.to_string().contains("UNRECOGNIZED_NATIVE_ERROR"));
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            true
        );
    }

    #[test]
    fn given_canonical_file_path_contains_control_or_exceeds_limit_then_reject_as_invalid_file() {
        assert!(!is_valid_canonical_file_path(&format!(
            "/{}",
            "a".repeat(4096)
        )));
        assert!(!is_valid_canonical_file_path("/tmp/private\nfile"));
        assert!(is_valid_canonical_file_path(&format!(
            "/{}",
            "a".repeat(4095)
        )));

        #[cfg(unix)]
        {
            let dir = TestDir::new();
            let target = dir.0.join("private\nfile.txt");
            let link = dir.0.join("alias.txt");
            fs::write(&target, "content").unwrap();
            symlink(&target, &link).unwrap();
            let (mut service, connection_id) = connected_service(Ok(json!({
                "selected":true,
                "dialogClosed":true
            })));
            let error = service
                .execute(select_request(&connection_id, link.to_str().unwrap()))
                .unwrap_err();
            assert_eq!(error.code, "FILE_NOT_READABLE");
            assert!(!error.to_string().contains("private"));
            assert_eq!(service.native.requests.len(), 3);
            assert_eq!(
                service.execute(json!({"action":"status"})).unwrap()["connected"],
                true
            );
        }
    }

    #[test]
    fn given_native_reports_authorized_window_gone_during_selection_then_invalidate_connection() {
        let dir = TestDir::new();
        let path = dir.0.join("file.txt");
        fs::write(&path, "content").unwrap();
        let (mut service, connection_id) = connected_service(Err(Error::new(
            "WINDOW_UNAVAILABLE",
            "window disappeared while selecting a file",
        )));

        let error = service
            .execute(select_request(&connection_id, path.to_str().unwrap()))
            .unwrap_err();

        assert_eq!(error.code, "WINDOW_UNAVAILABLE");
        assert!(!error.to_string().contains(path.to_str().unwrap()));
        assert_eq!(
            service.native.requests,
            vec![
                json!({"action":"permissions","request":false}),
                json!({"action":"windows"}),
                json!({"action":"window","windowId":7,"pid":42,"prepareToast":true}),
                json!({"action":"window","windowId":7,"pid":42}),
                json!({
                    "action":"select-file",
                    "windowId":7,
                    "pid":42,
                    "path":path.canonicalize().unwrap()
                }),
                json!({"action":"cancel"}),
            ]
        );
        assert_eq!(
            service.execute(json!({"action":"status"})).unwrap()["connected"],
            false
        );
    }
    #[test]
    fn late_success_after_remote_pause_is_not_reported_as_success() {
        struct CancelOnReply(Arc<AtomicBool>);
        impl Native for CancelOnReply {
            fn request(&mut self, _: Value) -> Result<Value> {
                self.0.store(true, Ordering::Release);
                Ok(
                    json!({"screenRecording":true,"accessibility":true,"chromeAutomation":{"target":"com.google.Chrome","requested":false,"granted":true,"status":"granted","osStatus":0}}),
                )
            }
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        let stopping = Arc::new(AtomicBool::new(false));
        let mut service = Service::new(CancelOnReply(cancelled.clone()), std::env::temp_dir());
        let result = service.execute_remote(
            json!({"action":"permissions","request":false}),
            0,
            cancelled,
            stopping,
            Arc::new(|| true),
        );
        assert_eq!(result.unwrap_err().code, "USER_PAUSED");
    }
    #[test]
    fn paused_remote_observe_window_failure_never_calls_cancel_or_clears_lease() {
        let (mut service, connection) =
            service_with_connection([Err(Error::new("WINDOW_UNAVAILABLE", "fixture"))]);
        let error = service
            .execute_remote_read(json!({"action":"observe","connectionId":connection}), true)
            .unwrap_err();
        assert_eq!(error.code, "WINDOW_UNAVAILABLE");
        assert_eq!(service.native.requests.len(), 1);
        assert_eq!(service.native.requests[0]["action"], "window");
        assert!(service.connected());
    }
    #[test]
    fn remote_window_failure_does_not_cancel_or_clear_original_connection() {
        let (mut service, connection) = service_with_connection([
            Err(Error::new("WINDOW_UNAVAILABLE", "fixture")),
            Ok(json!({"cancelled":true})),
        ]);
        let cancelled = Arc::new(AtomicBool::new(false));
        let stopping = Arc::new(AtomicBool::new(false));
        let error = service
            .execute_remote(
                json!({"action":"observe","connectionId":connection}),
                0,
                cancelled,
                stopping,
                Arc::new(|| true),
            )
            .unwrap_err();
        assert_eq!(error.code, "WINDOW_UNAVAILABLE");
        assert_eq!(service.native.requests.len(), 1);
        assert_eq!(service.native.requests[0]["action"], "window");
        assert!(service.connected());
    }
}
