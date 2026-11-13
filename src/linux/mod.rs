//! Ubuntu Xorg host/container implementation of the existing Native helper protocol.
pub mod x11;
use crate::{
    firefox::{actions, browser::Browser, gate::Gate},
    protocol::{Error, Result},
    service::{Bounds, Window},
};
use serde_json::{json, Value};
use std::{
    io::{BufReader, Read, Write},
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use x11::{Desktop, DesktopEvent};

type SharedGate = Arc<Mutex<Gate>>;
type Output = Arc<Mutex<std::io::Stdout>>;
fn lock<T>(value: &Mutex<T>) -> Result<std::sync::MutexGuard<'_, T>> {
    value
        .lock()
        .map_err(|_| Error::new("RECOVERY_REQUIRED", "桌面状态锁不可用"))
}
fn respond(output: &Output, id: Value, result: Result<Value>) {
    let value = match result {
        Ok(data) => json!({"id":id,"ok":true,"data":data}),
        Err(error) => json!({"id":id,"ok":false,"error":error}),
    };
    if let Ok(mut output) = output.lock() {
        let _ = writeln!(output, "{value}");
        let _ = output.flush();
    }
}
fn check(gate: &SharedGate, epoch: Option<u64>) -> Result<()> {
    lock(gate)?.check(epoch)
}

/// Sideband only mutates the shared permit. Browser release is ordered after its
/// outstanding command by the worker, never sent concurrently from this thread.
fn sideband(gate: &SharedGate, request: &Value) -> Result<Value> {
    let mut gate = lock(gate)?;
    match request["action"].as_str().unwrap_or("") {
        "transport-state" => {}
        "transport-pause" => return Ok(gate.transport_pause()),
        "transport-auto-resume" => {
            let lease = request["expectedLease"]
                .as_u64()
                .ok_or_else(|| Error::invalid("缺少 lease"))?;
            let epoch = request["expectedInputEpoch"]
                .as_u64()
                .ok_or_else(|| Error::invalid("缺少 epoch"))?;
            gate.auto_resume(lease, epoch)?;
            let mut out = gate.state();
            out["autoResumed"] = json!(true);
            return Ok(out);
        }
        "control" => match request["command"].as_str().unwrap_or("") {
            "state" => {}
            "pause" => gate.pause("explicitPause", false),
            "cancel" => gate.pause("explicitCancel", false),
            "resume" => gate.resume()?,
            _ => return Err(Error::invalid("control 仅允许 state/pause/resume/cancel")),
        },
        _ => return Err(Error::invalid("未知 sideband 操作")),
    }
    Ok(gate.state())
}

struct Target {
    browser: Browser,
    window: Window,
    frame: Option<(String, String, Bounds)>,
}
struct Helper {
    desktop: Arc<Mutex<Desktop>>,
    gate: SharedGate,
    stop: Arc<AtomicBool>,
    target: Option<Target>,
    serial: u64,
}
impl Helper {
    fn public_window(&self, real: &Window) -> Window {
        if let Some(target) = &self.target {
            if real.window_id == target.window.window_id && real.pid == target.window.pid {
                return Window {
                    window_id: real.window_id,
                    pid: real.pid,
                    title: real.title.clone(),
                    bundle_id: Some("org.mozilla.firefox".into()),
                    app_name: Some("Firefox".into()),
                    bounds: real.bounds,
                };
            }
        }
        real.clone()
    }
    fn permissions(&self) -> Result<Value> {
        let _desktop = lock(&self.desktop)?;
        let host = crate::execution::host_desktop_enabled(crate::protocol::Scope::Desktop);
        Ok(
            json!({"platform":if host {"linux-x11"} else {"linux-docker"},"screenRecording":true,"accessibility":true,"backend":"x11","ocr":{"engine":"tesseract","languages":["eng","chi_sim"]},"capabilities":["firefox.x11.v1","firefox.system-input.v1",if host {"linux.x11.v1"} else {"docker.x11.v1"}]}),
        )
    }
    fn request(&mut self, request: &Value) -> Result<Value> {
        lock(&self.gate)?.check_request(request["action"].as_str().unwrap_or(""))?;
        match request["action"].as_str().unwrap_or("") {
            "permissions" => self.permissions(),
            "apps" => {
                let windows = lock(&self.desktop)?.windows()?;
                let mut seen = std::collections::HashSet::new();
                Ok(
                    json!({"apps":windows.iter().filter(|w|seen.insert(w.pid)).map(|w|{let w=self.public_window(w);json!({"pid":w.pid,"bundleId":w.bundle_id,"name":w.app_name})}).collect::<Vec<_>>()}),
                )
            }
            "windows" => {
                let windows = lock(&self.desktop)?.windows()?;
                Ok(
                    json!({"windows":windows.iter().map(|w|self.public_window(w)).collect::<Vec<_>>()}),
                )
            }
            "window" => {
                let id = request["windowId"]
                    .as_u64()
                    .and_then(|v| u32::try_from(v).ok())
                    .ok_or_else(|| Error::invalid("windowId 无效"))?;
                let pid = request["pid"]
                    .as_i64()
                    .and_then(|v| i32::try_from(v).ok())
                    .ok_or_else(|| Error::invalid("pid 无效"))?;
                let real = lock(&self.desktop)?.window(id, pid)?;
                if request["prepareToast"] == true {
                    let mut gate = lock(&self.gate)?;
                    gate.check(None)?;
                    gate.bind(id, pid);
                }
                let public = self.public_window(&real);
                let backend = if public.bundle_id.as_deref() == Some("org.mozilla.firefox") {
                    "firefox-x11"
                } else {
                    "x11"
                };
                Ok(json!({"window":public,"backend":backend}))
            }
            "firefox-start" => self.start(request),
            "select-file" => self.select_file(request),
            "observe" => self.observe(request),
            "click" | "scroll" | "type" | "press" | "move" | "hover" | "drag" | "actions" => {
                self.input(request)
            }
            "cancel" => {
                self.disconnect()?;
                Ok(json!({"cancelled":true}))
            }
            "transport-disconnect" => {
                let epoch = request["expectedInputEpoch"]
                    .as_u64()
                    .ok_or_else(|| Error::invalid("缺少 expectedInputEpoch"))?;
                check(&self.gate, Some(epoch))?;
                self.close_target()?;
                let mut gate = lock(&self.gate)?;
                gate.check(Some(epoch))?;
                gate.reset();
                Ok(json!({"cancelled":true}))
            }
            "transport-recover" => {
                self.disconnect()?;
                Ok(lock(&self.gate)?.state())
            }
            "chrome-start" => Err(Error::new("ACTION_UNSUPPORTED", "Linux 未实现此原生功能")),
            _ => Err(Error::invalid("未知 Linux helper 操作")),
        }
    }
    fn start(&mut self, request: &Value) -> Result<Value> {
        check(&self.gate, request["expectedInputEpoch"].as_u64())?;
        if self.target.is_some() {
            return Err(Error::new("CONNECTION_BUSY", "owned Firefox 会话已存在"));
        }
        let profile = request["profile"].as_str().unwrap_or("mcc");
        let browser = Browser::start(profile, request["url"].as_str())?;
        let deadline = Instant::now() + Duration::from_secs(8);
        let window = loop {
            let windows = lock(&self.desktop)?.windows()?;
            let candidates: Vec<_> = windows
                .into_iter()
                .filter(|w| w.pid == browser.pid)
                .collect();
            if candidates.len() == 1 {
                break candidates.into_iter().next().unwrap();
            }
            if candidates.len() > 1 {
                return Err(Error::new(
                    "WINDOW_IDENTITY_UNAVAILABLE",
                    "Firefox 出现多个未明确选择的原生窗口",
                ));
            }
            if Instant::now() >= deadline || self.stop.load(Ordering::Acquire) {
                return Err(Error::new(
                    "WINDOW_IDENTITY_UNAVAILABLE",
                    "无法绑定 owned Firefox 的 X11 窗口",
                ));
            }
            std::thread::sleep(Duration::from_millis(30));
        };
        // A pause during launch must drop the local Browser and its profile
        // lock before publishing a target that Service has not connected yet.
        check(&self.gate, request["expectedInputEpoch"].as_u64())?;
        self.target = Some(Target {
            browser,
            window: window.clone(),
            frame: None,
        });
        Ok(
            json!({"window":self.public_window(&window),"backend":"firefox-x11","profile":{"name":profile},"created":true}),
        )
    }
    fn selected(&self, request: &Value) -> Result<Window> {
        let id = request["windowId"]
            .as_u64()
            .and_then(|v| u32::try_from(v).ok())
            .ok_or_else(|| Error::invalid("windowId 无效"))?;
        let pid = request["pid"]
            .as_i64()
            .and_then(|v| i32::try_from(v).ok())
            .ok_or_else(|| Error::invalid("pid 无效"))?;
        let real = lock(&self.desktop)?.window(id, pid)?;
        let public = self.public_window(&real);
        if request
            .get("bundleId")
            .is_some_and(|v| v.as_str() != public.bundle_id.as_deref())
        {
            return Err(Error::new("WINDOW_UNAVAILABLE", "应用身份变化"));
        }
        Ok(real)
    }
    fn observe(&mut self, request: &Value) -> Result<Value> {
        let real = self.selected(request)?;
        let path = Path::new(
            request["imagePath"]
                .as_str()
                .ok_or_else(|| Error::invalid("缺少 imagePath"))?,
        );
        if !path.is_absolute() {
            return Err(Error::invalid("imagePath 必须为绝对路径"));
        }
        let public = self.public_window(&real);
        let mut frame = None;
        let (width, height) = if let Some(target) = self
            .target
            .as_mut()
            .filter(|t| t.window.window_id == real.window_id)
        {
            if !target.browser.is_alive() {
                return Err(Error::new("BROWSER_SESSION_LOST", "Firefox 会话已失效"));
            }
            let (w, h) = lock(&self.desktop)?.capture(&real, path)?;
            self.serial += 1;
            let id = format!("x11-{}-{}", real.window_id, self.serial);
            target.frame = Some((id.clone(), real.title.clone(), real.bounds));
            frame = Some(id);
            (w, h)
        } else {
            lock(&self.desktop)?.capture(&real, path)?
        };
        let ocr = recognize(path, width, height, &self.stop);
        let mut out = json!({"imagePath":path,"width":width,"height":height,"bounds":public.bounds,"capturedAtMs":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64,"coordinateSpace":"frame-pixels","imageTransform":"crop-only","ocr":ocr});
        if let Some(id) = frame {
            out["backendFrameId"] = json!(id);
            out["backend"] = json!("firefox-x11");
        }
        Ok(out)
    }
    fn permit(&mut self, request: &Value, real: &Window) -> Result<u64> {
        self.permit_for(request, real, real)
    }
    fn permit_for(&mut self, request: &Value, real: &Window, lease: &Window) -> Result<u64> {
        let expected = {
            let gate = lock(&self.gate)?;
            gate.check(request["expectedInputEpoch"].as_u64())?;
            if gate.target != Some((lease.window_id, lease.pid)) {
                return Err(Error::new(
                    "WINDOW_UNAVAILABLE",
                    "输入目标未绑定到当前 lease",
                ));
            }
            gate.epoch
        };
        lock(&self.desktop)?.activate(real.window_id)?;
        let countdown = {
            let mut gate = lock(&self.gate)?;
            gate.check(Some(expected))?;
            gate.active = true;
            gate.begin_countdown()
        };
        if let Some(deadline) = countdown {
            self.wait_until(expected, real, deadline)?;
        }
        {
            let mut gate = lock(&self.gate)?;
            gate.check(Some(expected))?;
            gate.input_ready();
        }
        self.check_step(expected, real)?;
        Ok(expected)
    }
    fn check_step(&self, epoch: u64, real: &Window) -> Result<()> {
        check(&self.gate, Some(epoch))?;
        if self.stop.load(Ordering::Acquire) {
            return Err(Error::new("USER_PAUSED", "helper 正在停止"));
        }
        let desktop = lock(&self.desktop)?;
        let current = desktop.window(real.window_id, real.pid)?;
        if current.bounds != real.bounds
            || current.bundle_id != real.bundle_id
            || current.title != real.title
        {
            return Err(Error::new(
                "CONTEXT_CHANGED",
                "输入期间原生窗口身份、标题或几何变化；请重新 observe",
            ));
        }
        if !desktop.focused(real.window_id)? {
            lock(&self.gate)?.pause("focusLoss", false);
            return Err(Error::new(
                "FOCUS_LOST",
                "目标窗口失焦；当前动作已停止，下一条命令会重新激活目标",
            ));
        }
        Ok(())
    }
    fn compile_plan(&self, request: &Value, real: &Window) -> Result<Vec<actions::Segment>> {
        let mut normalized = request.clone();
        let offset = |point: &mut Value, x: &str, y: &str| {
            if let Some(n) = point[x].as_i64() {
                point[x] = json!(n + real.bounds.x as i64);
            }
            if let Some(n) = point[y].as_i64() {
                point[y] = json!(n + real.bounds.y as i64);
            }
        };
        match request["action"].as_str().unwrap_or("") {
            "move" | "hover" => offset(&mut normalized, "x", "y"),
            "drag" => {
                offset(&mut normalized, "fromX", "fromY");
                offset(&mut normalized, "toX", "toY");
            }
            "actions" => {
                if let Some(steps) = normalized["actions"]["steps"].as_array_mut() {
                    for step in steps {
                        if matches!(step["type"].as_str(), Some("move" | "scroll")) {
                            offset(step, "x", "y");
                        }
                    }
                }
            }
            _ => {}
        }
        let desktop = lock(&self.desktop)?;
        let (width, height) = desktop.screen_size();
        actions::compile(&normalized, width, height, desktop.pointer_position()?)
    }
    fn wait_until(&self, epoch: u64, real: &Window, deadline: Instant) -> Result<()> {
        loop {
            self.check_step(epoch, real)?;
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Ok(());
            }
            std::thread::sleep(remaining.min(Duration::from_millis(5)));
        }
    }
    fn input(&mut self, request: &Value) -> Result<Value> {
        let real = self.selected(request)?;
        let browser = self
            .target
            .as_ref()
            .is_some_and(|t| t.window.window_id == real.window_id);
        // Validate before countdown or focus changes, including all steps.
        let segments = if browser {
            let target = self.target.as_ref().unwrap();
            let (frame, title, bounds) = target
                .frame
                .as_ref()
                .ok_or_else(|| Error::new("FRAME_UNKNOWN", "先 observe 获取 Firefox 原生窗口帧"))?;
            if request["backendFrameId"].as_str() != Some(frame)
                || *title != real.title
                || *bounds != real.bounds
            {
                return Err(Error::new(
                    "CONTEXT_CHANGED",
                    "Firefox 帧、窗口标题或几何已变化；请重新 observe",
                ));
            }
            Some(self.compile_plan(request, &real)?)
        } else {
            None
        };
        let mut completed = 0;
        let mut dispatched = false;
        let result = (|| {
            let epoch = self.permit(request, &real)?;
            if segments.is_some() {
                // Read the physical cursor after activating the target.
                let segments = self.compile_plan(request, &real)?;
                let mut motion_started = Instant::now();
                for segment in segments {
                    self.check_step(epoch, &real)?;
                    if segment.motion.is_some_and(|timing| timing.at_ms == 0) {
                        motion_started = Instant::now();
                    }
                    let elapsed = motion_started.elapsed().as_millis() as u64;
                    if segment.wire.is_some() {
                        let Some(wire) = segment.wire_at(elapsed) else {
                            continue;
                        };
                        if let Some(timing) = segment.motion {
                            self.wait_until(
                                epoch,
                                &real,
                                motion_started + Duration::from_millis(timing.at_ms),
                            )?;
                        }
                        self.check_step(epoch, &real)?;
                        dispatched = true;
                        lock(&self.desktop)?.perform(&real, &wire, request["action"] == "type")?;
                    } else {
                        self.wait_until(
                            epoch,
                            &real,
                            Instant::now() + Duration::from_millis(segment.wait_ms),
                        )?;
                    }
                    if segment.completes_step {
                        completed += 1;
                    }
                }
                self.check_step(epoch, &real)?;
                Ok(
                    json!({"sent":true,"backend":"firefox-x11","dispatchState":"completed","completedSteps":completed,"inputState":"released","effectVerified":false}),
                )
            } else {
                // The desktop adapter has a bounded per-character input interface.
                if request["action"] == "type" {
                    let text = request["text"]
                        .as_str()
                        .ok_or_else(|| Error::invalid("缺少 text"))?;
                    if !text.is_ascii() {
                        return Err(Error::new(
                            "ACTION_UNSUPPORTED",
                            "原生窗口文本输入只支持 ASCII；Firefox 网页支持 Unicode",
                        ));
                    }
                    for c in text.chars() {
                        self.check_step(epoch, &real)?;
                        let mut one = request.clone();
                        one["text"] = json!(c.to_string());
                        lock(&self.desktop)?.native_input(&real, &one)?;
                    }
                } else {
                    lock(&self.desktop)?.native_input(&real, request)?;
                }
                Ok(json!({"sent":true,"backend":"x11","effectVerified":false}))
            }
        })();
        let mut desktop = lock(&self.desktop)?;
        let released = desktop.release_inputs();
        let reason = desktop.input_stop_reason();
        drop(desktop);
        let mut gate = lock(&self.gate)?;
        if let Some(reason) = reason {
            gate.pause(reason, false);
        }
        if result
            .as_ref()
            .err()
            .is_some_and(|e| e.code == "FOCUS_LOST")
        {
            gate.pause("focusLoss", false);
        }
        gate.active = false;
        drop(gate);
        if let Err(error) = released {
            lock(&self.gate)?.pause("unknownInput", true);
            if let Some(target) = &mut self.target {
                target.browser.abort();
            }
            return Err(error.with_receipt(json!({"backend":if browser{"firefox-x11"}else{"x11"},"dispatchState":"unknown","completedSteps":completed,"inputState":"unknown","effectVerified":false})));
        }
        if result
            .as_ref()
            .is_err_and(|e| e.code == "INPUT_STATE_UNKNOWN")
        {
            lock(&self.gate)?.pause("unknownInput", true);
            if let Some(target) = &mut self.target {
                target.browser.abort();
            }
        }
        result.map_err(|error|error.with_receipt(json!({"backend":if browser{"firefox-x11"}else{"x11"},"dispatchState":if dispatched{"partial"}else{"notSent"},"completedSteps":completed,"inputState":"released","effectVerified":false})))
    }
    fn close_target(&mut self) -> Result<()> {
        // Closing the owned window naturally changes focus. Revoke its UI
        // target first so that cleanup cannot be mistaken for human takeover.
        {
            let mut gate = lock(&self.gate)?;
            gate.target = None;
            gate.input_started = false;
        }
        if let Some(mut target) = self.target.take() {
            if let Err(error) = lock(&self.desktop)?.release_inputs() {
                target.browser.abort();
                lock(&self.gate)?.pause("unknownInput", true);
                return Err(error);
            }
            drop(target);
        }
        Ok(())
    }
    fn disconnect(&mut self) -> Result<()> {
        self.close_target()?;
        lock(&self.gate)?.reset();
        Ok(())
    }
    fn select_file(&mut self, request: &Value) -> Result<Value> {
        let parent = self.selected(request)?;
        if !self
            .target
            .as_ref()
            .is_some_and(|t| t.window.window_id == parent.window_id && t.window.pid == parent.pid)
        {
            return Err(Error::new(
                "FILE_DIALOG_UNSUPPORTED",
                "仅支持 owned Firefox 的文件选择框",
            ));
        }
        let path = request["path"]
            .as_str()
            .ok_or_else(|| Error::invalid("缺少文件路径"))?;
        if !Path::new(path).is_absolute()
            || path.len() > 4096
            || path.chars().any(char::is_control)
            || !std::fs::metadata(path).is_ok_and(|m| m.is_file())
        {
            return Err(Error::new("FILE_NOT_READABLE", "文件路径无效或不可读"));
        }
        let dialog = lock(&self.desktop)?.file_dialog(&parent)?;
        let mut dispatched = false;
        let mut completed = 0;
        let result = (|| -> Result<Value> {
            let epoch = self.permit_for(request, &dialog, &parent)?;
            for operation in [
                json!({"action":"press","key":"Control+l"}),
                json!({"action":"type","text":path}),
            ] {
                for segment in self.compile_plan(&operation, &dialog)? {
                    self.check_step(epoch, &dialog)?;
                    let verified = lock(&self.desktop)?.file_dialog(&parent)?;
                    if verified.window_id != dialog.window_id {
                        return Err(Error::new("FILE_DIALOG_UNVERIFIED", "选择框身份已变化"));
                    }
                    if let Some(wire) = segment.wire {
                        dispatched = true;
                        lock(&self.desktop)?.perform(
                            &dialog,
                            &wire,
                            operation["action"] == "type",
                        )?;
                    } else {
                        self.wait_until(
                            epoch,
                            &dialog,
                            Instant::now() + Duration::from_millis(segment.wait_ms),
                        )?;
                    }
                    if segment.completes_step {
                        completed += 1;
                    }
                }
            }
            self.check_step(epoch, &dialog)?;
            {
                let mut desktop = lock(&self.desktop)?;
                if desktop.file_dialog(&parent)?.window_id != dialog.window_id {
                    return Err(Error::new("FILE_DIALOG_UNVERIFIED", "选择框身份已变化"));
                }
                // Return may destroy the dialog on keyDown. The existing native
                // press primitive checks the target before pressing and always
                // releases its key, even when the dialog closes immediately.
                dispatched = true;
                desktop.native_input(
                    &dialog,
                    &json!({"action":"press","key":"Enter",
                    "windowId":dialog.window_id,"pid":dialog.pid,"expectedBounds":dialog.bounds}),
                )?;
                completed += 1;
            }
            lock(&self.desktop)?.release_inputs()?;
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                check(&self.gate, Some(epoch))?;
                if self.stop.load(Ordering::Acquire) {
                    return Err(Error::new("USER_PAUSED", "helper 正在停止"));
                }
                let desktop = lock(&self.desktop)?;
                if desktop.window(dialog.window_id, dialog.pid).is_err()
                    && desktop.focused(parent.window_id)?
                {
                    desktop.window(parent.window_id, parent.pid)?;
                    return Ok(
                        json!({"selected":true,"dialogClosed":true,"backend":"firefox-x11","effectVerified":false}),
                    );
                }
                drop(desktop);
                if Instant::now() >= deadline {
                    return Err(Error::new("FILE_DIALOG_TIMEOUT", "文件选择框未确认关闭"));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        })();
        let mut desktop = lock(&self.desktop)?;
        let released = desktop.release_inputs();
        let reason = desktop.input_stop_reason();
        drop(desktop);
        let mut gate = lock(&self.gate)?;
        if let Some(reason) = reason {
            gate.pause(reason, false);
        }
        if result
            .as_ref()
            .err()
            .is_some_and(|e| e.code == "FOCUS_LOST")
        {
            gate.pause("focusLoss", false);
        }
        gate.active = false;
        drop(gate);
        if let Err(error) = released {
            lock(&self.gate)?.pause("unknownInput", true);
            if let Some(t) = self.target.as_mut() {
                t.browser.abort();
            }
            return Err(error.with_receipt(json!({"backend":"firefox-x11",
                "dispatchState":"unknown","completedSteps":completed,
                "inputState":"unknown","effectVerified":false})));
        }
        if result
            .as_ref()
            .is_err_and(|e| e.code == "INPUT_STATE_UNKNOWN")
        {
            lock(&self.gate)?.pause("unknownInput", true);
            if let Some(t) = self.target.as_mut() {
                t.browser.abort();
            }
        }
        result.map_err(|e| {
            e.with_receipt(json!({"backend":"firefox-x11",
                "dispatchState":if dispatched{"partial"}else{"notSent"},
                "completedSteps":completed,"inputState":"released","effectVerified":false}))
        })
    }
}

fn recognize(path: &Path, width: u32, height: u32, stop: &AtomicBool) -> Value {
    let unavailable = || json!({"status":"unavailable","items":[],"truncated":false});
    let Ok(mut child) = std::process::Command::new("/usr/bin/tesseract")
        .arg(path)
        .args(["stdout", "-l", "eng+chi_sim", "tsv"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    else {
        return unavailable();
    };
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return unavailable();
    };
    let reader = std::thread::spawn(move || {
        let mut bytes = vec![];
        let _ = stdout.take(1024 * 1024).read_to_end(&mut bytes);
        bytes
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    let success = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Err(_) => break false,
            _ => {}
        }
        if Instant::now() >= deadline || stop.load(Ordering::Acquire) {
            let _ = child.kill();
            let _ = child.wait();
            break false;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let bytes = reader.join().unwrap_or_default();
    if !success {
        return unavailable();
    }
    let text = String::from_utf8_lossy(&bytes);
    let mut items = vec![];
    let mut truncated = false;
    let mut chars = 0;
    for line in text.lines().skip(1) {
        let fields: Vec<_> = line.splitn(12, '\t').collect();
        if fields.len() != 12 || fields[0] != "5" || fields[11].trim().is_empty() {
            continue;
        }
        let n = |i: usize| fields[i].parse::<u32>().ok();
        let (Some(x), Some(y), Some(w), Some(h), Some(conf)) =
            (n(6), n(7), n(8), n(9), fields[10].parse::<f64>().ok())
        else {
            continue;
        };
        if !conf.is_finite()
            || !(0.0..=100.0).contains(&conf)
            || w == 0
            || h == 0
            || x.checked_add(w).is_none_or(|v| v > width)
            || y.checked_add(h).is_none_or(|v| v > height)
        {
            continue;
        }
        let value = fields[11].trim();
        let count = value.chars().count();
        if count > 256 {
            truncated = true;
            continue;
        }
        if items.len() >= 128 || chars + count > 8192 {
            truncated = true;
            break;
        }
        chars += count;
        items.push(json!({"text":value,"bbox":{"x":x,"y":y,"width":w,"height":h},"center":{"x":x+w/2,"y":y+h/2},"confidence":conf/100.0}));
    }
    json!({"status":"ok","items":items,"truncated":truncated})
}

pub fn run() -> Result<()> {
    let mode = crate::execution::validate_linux_environment()?;
    let host_desktop = mode == crate::execution::LinuxDesktopMode::Host;
    let desktop = Arc::new(Mutex::new(Desktop::connect()?));
    let gate = Arc::new(Mutex::new(if host_desktop {
        Gate::for_host_desktop()
    } else {
        Gate::new()
    }));
    let stop = Arc::new(AtomicBool::new(false));
    let output = Arc::new(Mutex::new(std::io::stdout()));
    for signal in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        signal_hook::flag::register(signal, stop.clone())
            .map_err(|e| Error::io("无法设置 helper 退出处理", e))?;
    }
    let (tx, rx) = mpsc::sync_channel::<Value>(16);
    let reader_gate = gate.clone();
    let reader_output = output.clone();
    let reader_stop = stop.clone();
    std::thread::spawn(move || {
        let mut input = BufReader::new(std::io::stdin());
        loop {
            let request = match crate::protocol::read_message(&mut input) {
                Ok(Some(v)) => v,
                _ => {
                    reader_stop.store(true, Ordering::Release);
                    break;
                }
            };
            let action = request["action"].as_str().unwrap_or("");
            if action == "cancel" && request["id"] == "cancel" {
                if let Ok(mut gate) = reader_gate.lock() {
                    gate.pause("explicitCancel", false);
                }
                reader_stop.store(true, Ordering::Release);
                break;
            }
            if matches!(
                action,
                "transport-state" | "transport-pause" | "transport-auto-resume" | "control"
            ) {
                respond(
                    &reader_output,
                    request["id"].clone(),
                    sideband(&reader_gate, &request),
                );
            } else if tx.try_send(request.clone()).is_err() {
                respond(
                    &reader_output,
                    request["id"].clone(),
                    Err(Error::new("BUSY", "helper 请求队列已满，不排队重放输入")),
                );
            }
        }
    });
    let ui_desktop = desktop.clone();
    let ui_gate = gate.clone();
    let ui_stop = stop.clone();
    let ui = std::thread::spawn(move || {
        let mut previous_status = String::new();
        while !ui_stop.load(Ordering::Acquire) {
            let result = (|| -> Result<()> {
                let mut desktop = lock(&ui_desktop)?;
                let events = desktop.poll_events()?;
                let mut gate = lock(&ui_gate)?;
                for event in events {
                    match event {
                        DesktopEvent::Pause => gate.pause("explicitPause", false),
                        DesktopEvent::Cancel => gate.pause("explicitCancel", false),
                        DesktopEvent::Resume => {
                            let _ = gate.resume();
                        }
                        DesktopEvent::UserInteraction if host_desktop && gate.target.is_some() => {
                            gate.pause("userInteraction", false)
                        }
                        DesktopEvent::FocusChanged
                            if host_desktop && (gate.input_started || gate.active) =>
                        {
                            if let Some((id, pid)) = gate.target {
                                if !desktop.lease_focused(id, pid)? {
                                    gate.pause("focusLoss", false);
                                }
                            }
                        }
                        _ => {}
                    }
                }
                let status = if gate.recovery {
                    "RECOVERY REQUIRED".to_owned()
                } else if gate.paused {
                    "PAUSED".to_owned()
                } else if let Some(remaining) = gate.countdown_remaining() {
                    format!("MCC START IN {}s", remaining.as_millis().div_ceil(1000))
                } else if gate.target.is_some() {
                    "MCC CONTROL".to_owned()
                } else {
                    "MCC READY".to_owned()
                };
                if status != previous_status {
                    desktop.draw_control(&status)?;
                    previous_status = status;
                }
                Ok(())
            })();
            if result.is_err() {
                if let Ok(mut gate) = ui_gate.lock() {
                    gate.pause("displayLost", true);
                }
                ui_stop.store(true, Ordering::Release);
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    });
    let mut helper = Helper {
        desktop,
        gate,
        stop: stop.clone(),
        target: None,
        serial: 0,
    };
    while !stop.load(Ordering::Acquire) {
        match rx.recv_timeout(Duration::from_millis(20)) {
            Ok(request) => {
                let result = helper.request(&request);
                respond(&output, request["id"].clone(), result);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
    }
    stop.store(true, Ordering::Release);
    let released = helper.disconnect();
    let _ = ui.join();
    respond(
        &output,
        json!("cancel"),
        released.map(|_| json!({"cancelled":true})),
    );
    Ok(())
}
