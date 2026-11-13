//! X11 desktop adapter. Business permits and pause state belong to the helper.
use crate::protocol::{Error, Result};
use crate::service::{Bounds, Window};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesktopEvent {
    UserInteraction,
    FocusChanged,
    Pause,
    Resume,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CaptureRect {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
}
fn capture_rect(bounds: Bounds, screen: (u16, u16)) -> Result<CaptureRect> {
    let values = [bounds.x, bounds.y, bounds.width, bounds.height];
    if values.iter().any(|v| !v.is_finite() || v.fract() != 0.)
        || bounds.x < 0.
        || bounds.y < 0.
        || bounds.width < 1.
        || bounds.height < 1.
        || bounds.width > 1600.
        || bounds.height > 8192.
        || bounds.x + bounds.width > f64::from(screen.0)
        || bounds.y + bounds.height > f64::from(screen.1)
        || bounds.x > f64::from(i16::MAX)
        || bounds.y > f64::from(i16::MAX)
    {
        return Err(Error::new(
            "IMAGE_TOO_LARGE",
            "截图必须为屏幕内的整数原像素区域，宽不超过 1600，高不超过 8192",
        ));
    }
    Ok(CaptureRect {
        x: bounds.x as i16,
        y: bounds.y as i16,
        width: bounds.width as u16,
        height: bounds.height as u16,
    })
}
fn decode_pixels(
    data: &[u8],
    width: u16,
    height: u16,
    bits: u8,
    pad: u8,
    little: bool,
    masks: [u32; 3],
) -> Result<Vec<u8>> {
    if ![16, 24, 32].contains(&bits) || ![8, 16, 32].contains(&pad) || masks.contains(&0) {
        return Err(Error::new(
            "CAPTURE_UNSUPPORTED",
            "X11 图像像素格式不受支持",
        ));
    }
    let stride =
        (usize::from(width) * usize::from(bits)).div_ceil(usize::from(pad)) * usize::from(pad) / 8;
    if data.len() != stride * usize::from(height) {
        return Err(Error::new("CAPTURE_FAILED", "X11 图像长度不符合像素几何"));
    }
    let mut rgb = Vec::with_capacity(usize::from(width) * usize::from(height) * 3);
    for row in data.chunks_exact(stride) {
        for pixel in
            row[..usize::from(width) * usize::from(bits) / 8].chunks_exact(usize::from(bits) / 8)
        {
            let mut value = 0u32;
            for (index, byte) in pixel.iter().enumerate() {
                let shift = if little {
                    index
                } else {
                    pixel.len() - 1 - index
                } * 8;
                value |= u32::from(*byte) << shift;
            }
            for mask in masks {
                let max = mask >> mask.trailing_zeros();
                rgb.push((((value & mask) >> mask.trailing_zeros()) * 255 / max) as u8);
            }
        }
    }
    Ok(rgb)
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Injected {
    sequence: u16,
    kind: u8,
    detail: u32,
}
fn consume_own(pending: &mut Vec<Injected>, event: Injected, release_fence: Option<u16>) -> bool {
    if let Some(index) = pending.iter().position(|expected| {
        *expected == event
            || (matches!(event.kind, 3 | 5)
                && expected.kind == event.kind
                && expected.detail == event.detail
                && release_fence.is_some_and(|end| {
                    event.sequence.wrapping_sub(expected.sequence)
                        <= end.wrapping_sub(expected.sequence)
                }))
    }) {
        pending.remove(index);
        true
    } else {
        false
    }
}
fn validate_native(window: &Window, request: &Value) -> Result<()> {
    let object = request
        .as_object()
        .ok_or_else(|| Error::invalid("原生输入必须为对象"))?;
    let action = request["action"]
        .as_str()
        .ok_or_else(|| Error::invalid("缺少原生输入动作"))?;
    if action == "release-inputs" {
        if object
            .keys()
            .any(|key| !["id", "action"].contains(&key.as_str()))
        {
            return Err(Error::invalid("释放请求包含未知字段"));
        }
        return Ok(());
    }
    let extra: &[&str] = match action {
        "click" => &["screenX", "screenY", "clickCount"],
        "scroll" => &["screenX", "screenY", "deltaY"],
        "type" => &["text"],
        "press" => &["key"],
        _ => return Err(Error::new("ACTION_UNSUPPORTED", "此原生输入动作不受支持")),
    };
    if object.keys().any(|key| {
        ![
            "id",
            "action",
            "windowId",
            "pid",
            "bundleId",
            "expectedBounds",
            "expectedInputEpoch",
        ]
        .contains(&key.as_str())
            && !extra.contains(&key.as_str())
    }) {
        return Err(Error::invalid("原生输入包含未知字段"));
    }
    if request["windowId"].as_u64() != Some(u64::from(window.window_id))
        || request["pid"].as_i64() != Some(i64::from(window.pid))
        || request
            .get("bundleId")
            .is_some_and(|value| value.as_str() != window.bundle_id.as_deref())
    {
        return Err(Error::new("WINDOW_UNAVAILABLE", "原生输入窗口身份不匹配"));
    }
    let bounds: Bounds = serde_json::from_value(request["expectedBounds"].clone())
        .map_err(|_| Error::invalid("缺少有效的 expectedBounds"))?;
    if bounds != window.bounds {
        return Err(Error::new(
            "FRAME_GEOMETRY_CHANGED",
            "窗口几何已变化，请重新 observe",
        ));
    }
    if [bounds.x, bounds.y, bounds.width, bounds.height]
        .iter()
        .any(|value| !value.is_finite())
        || bounds.width < 1.
        || bounds.height < 1.
    {
        return Err(Error::invalid("窗口几何无效"));
    }
    if matches!(action, "click" | "scroll") {
        let x = request["screenX"]
            .as_f64()
            .ok_or_else(|| Error::invalid("screenX 必须为有限数值"))?;
        let y = request["screenY"]
            .as_f64()
            .ok_or_else(|| Error::invalid("screenY 必须为有限数值"))?;
        if !x.is_finite()
            || !y.is_finite()
            || x < bounds.x
            || y < bounds.y
            || x >= bounds.x + bounds.width
            || y >= bounds.y + bounds.height
            || x < 0.
            || y < 0.
            || x > f64::from(i16::MAX)
            || y > f64::from(i16::MAX)
        {
            return Err(Error::invalid("屏幕坐标超出窗口区域"));
        }
    }
    match action {
        "click" if !matches!(request["clickCount"].as_u64(), Some(1 | 2)) => {
            return Err(Error::invalid("clickCount 只能为 1 或 2"))
        }
        "scroll"
            if !request["deltaY"]
                .as_i64()
                .is_some_and(|v| v != 0 && (-1200..=1200).contains(&v)) =>
        {
            return Err(Error::invalid("deltaY 必须为 [-1200,1200] 内非零整数"))
        }
        "type" => {
            let text = request["text"]
                .as_str()
                .ok_or_else(|| Error::invalid("text 必须为字符串"))?;
            if text.is_empty() || text.chars().count() > 4096 || text.chars().any(char::is_control)
            {
                return Err(Error::invalid("文本必须为 1–4096 个非控制字符"));
            }
            if !text.is_ascii() {
                return Err(Error::new("ACTION_UNSUPPORTED", "X11 原生文本仅支持当前键盘布局内的 ASCII；Unicode 请使用受管理的 Firefox 系统输入连接"));
            }
        }
        "press"
            if request["key"]
                .as_str()
                .is_some_and(|key| key.starts_with("Cmd+")) =>
        {
            return Err(Error::new(
                "ACTION_UNSUPPORTED",
                "Ubuntu 原生输入不支持 Cmd 快捷键；不会将 Meta/Command 改写为 Control",
            ));
        }
        "press" if key_spec(request["key"].as_str().unwrap_or("")).is_none() => {
            return Err(Error::invalid("原生按键不在允许列表中"))
        }
        _ => {}
    }
    Ok(())
}
fn process_identity(status: &str, stat: &str, expected_uid: u32) -> Result<u64> {
    let uid = status
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .ok_or_else(|| Error::new("WINDOW_UNVERIFIED", "无法确认窗口进程 UID"))?;
    let uids = uid
        .split_whitespace()
        .map(str::parse::<u32>)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| Error::new("WINDOW_UNVERIFIED", "窗口进程 UID 无效"))?;
    if uids.len() != 4 || uids.iter().any(|uid| *uid != expected_uid) {
        return Err(Error::new("WINDOW_UNVERIFIED", "窗口不属于当前普通用户"));
    }
    // comm may contain spaces and ')' characters. Field 22 is offset 19 after comm.
    stat.rsplit_once(')')
        .and_then(|(_, tail)| tail.split_whitespace().nth(19))
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .ok_or_else(|| Error::new("WINDOW_UNVERIFIED", "无法确认窗口进程创建身份"))
}
fn key_spec(key: &str) -> Option<(u32, Option<u32>)> {
    Some(match key {
        "Enter" => (0xff0d, None),
        "Tab" => (0xff09, None),
        "Shift+Tab" => (0xff09, Some(0xffe1)),
        "Escape" => (0xff1b, None),
        "Backspace" => (0xff08, None),
        "Delete" => (0xffff, None),
        "ArrowUp" => (0xff52, None),
        "ArrowDown" => (0xff54, None),
        "ArrowLeft" => (0xff51, None),
        "ArrowRight" => (0xff53, None),
        "Home" => (0xff50, None),
        "End" => (0xff57, None),
        "PageUp" => (0xff55, None),
        "PageDown" => (0xff56, None),
        "Alt+ArrowLeft" => (0xff51, Some(0xffe9)),
        "Alt+ArrowRight" => (0xff53, Some(0xffe9)),
        _ => return None,
    })
}

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::res::ConnectionExt as _;
use x11rb::protocol::xinput::ConnectionExt as _;
use x11rb::protocol::xproto::ConnectionExt as _;
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::protocol::{res, xinput, xproto, Event};
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

fn xerror(error: impl std::fmt::Display) -> Error {
    Error::new("X11_UNAVAILABLE", &format!("X11 桌面操作失败: {error}"))
}
#[derive(Clone, PartialEq, Eq)]
struct Identity {
    pid: i32,
    start: u64,
    executable: PathBuf,
}
#[derive(Clone, Copy, PartialEq, Eq)]
struct PointerStamp {
    kind: u8,
    detail: u32,
    time: u32,
}
struct PendingPointer {
    stamp: PointerStamp,
    received: Instant,
}
struct Atoms {
    clients: u32,
    stacking: u32,
    active: u32,
    name: u32,
    utf8: u32,
    dock: u32,
    window_type: u32,
    dialog_type: u32,
    role: u32,
    state: u32,
    modal: u32,
    strut: u32,
    strut_partial: u32,
}
/// One managed X11 display. Only this object's exact, synchronously drained
/// XTEST requests are excluded from user activity; another XTEST client (noVNC)
/// remains observable. This object never grants input permission or resumes it.
pub struct Desktop {
    connection: RustConnection,
    root: u32,
    screen: usize,
    control: u32,
    gc: u32,
    atoms: Atoms,
    identities: RefCell<HashMap<u32, Identity>>,
    own_events: Vec<Injected>,
    release_fence: Option<u16>,
    pending_pointer: Vec<PendingPointer>,
    control_pointer: Vec<PendingPointer>,
    events: VecDeque<DesktopEvent>,
    held_keys: Vec<u8>,
    held_buttons: Vec<u8>,
    logical_keys: HashMap<String, (u8, Option<u8>)>,
    remapped_keys: HashMap<u8, Vec<u32>>,
    control_status: RefCell<String>,
}
impl Desktop {
    pub fn connect() -> Result<Self> {
        // XRes LOCAL_CLIENT_PID is meaningful only for a local transport. Never
        // accept a remote DISPLAY and then compare its PIDs against local /proc.
        let display = std::env::var("DISPLAY")
            .map_err(|_| Error::new("X11_UNAVAILABLE", "未配置 DISPLAY"))?;
        if !(display.starts_with(':') || display.starts_with("unix:")) {
            return Err(Error::new(
                "X11_UNVERIFIED",
                "只允许专属本地 X11 Unix 显示连接",
            ));
        }
        let (connection, screen) = x11rb::connect(Some(&display)).map_err(xerror)?;
        let root = connection.setup().roots[screen].root;
        let res_version = connection
            .res_query_version(1, 2)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        if (res_version.server_major, res_version.server_minor) < (1, 2) {
            return Err(Error::new(
                "X11_UNVERIFIED",
                "X server 必须提供 XRes 1.2 进程身份",
            ));
        }
        // XI 2.1 delivers raw events even while another client owns a pointer
        // grab (Firefox grabs during drags). XI 2.0 can hide human takeover.
        let input_version = connection
            .xinput_xi_query_version(2, 1)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        if (input_version.major_version, input_version.minor_version) < (2, 1) {
            return Err(Error::new(
                "X11_UNVERIFIED",
                "人工接管监测需要 XInput 2.1 或更新版本",
            ));
        }
        connection
            .xtest_get_version(2, 2)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let atom = |name: &[u8]| -> Result<u32> {
            Ok(connection
                .intern_atom(false, name)
                .map_err(xerror)?
                .reply()
                .map_err(xerror)?
                .atom)
        };
        let atoms = Atoms {
            clients: atom(b"_NET_CLIENT_LIST")?,
            stacking: atom(b"_NET_CLIENT_LIST_STACKING")?,
            active: atom(b"_NET_ACTIVE_WINDOW")?,
            name: atom(b"_NET_WM_NAME")?,
            utf8: atom(b"UTF8_STRING")?,
            dock: atom(b"_NET_WM_WINDOW_TYPE_DOCK")?,
            window_type: atom(b"_NET_WM_WINDOW_TYPE")?,
            dialog_type: atom(b"_NET_WM_WINDOW_TYPE_DIALOG")?,
            role: atom(b"WM_WINDOW_ROLE")?,
            state: atom(b"_NET_WM_STATE")?,
            modal: atom(b"_NET_WM_STATE_MODAL")?,
            strut: atom(b"_NET_WM_STRUT")?,
            strut_partial: atom(b"_NET_WM_STRUT_PARTIAL")?,
        };
        connection
            .change_window_attributes(
                root,
                &xproto::ChangeWindowAttributesAux::new().event_mask(
                    xproto::EventMask::PROPERTY_CHANGE | xproto::EventMask::SUBSTRUCTURE_NOTIFY,
                ),
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        connection
            .xinput_xi_select_events(
                root,
                &[xinput::EventMask {
                    deviceid: 1,
                    mask: vec![
                        xinput::XIEventMask::RAW_KEY_PRESS
                            | xinput::XIEventMask::RAW_KEY_RELEASE
                            | xinput::XIEventMask::RAW_BUTTON_PRESS
                            | xinput::XIEventMask::RAW_BUTTON_RELEASE
                            | xinput::XIEventMask::RAW_MOTION,
                    ],
                }],
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        let control = connection.generate_id().map_err(xerror)?;
        let gc = connection.generate_id().map_err(xerror)?;
        let control_width = connection.setup().roots[screen].width_in_pixels.min(760);
        connection
            .create_window(
                x11rb::COPY_DEPTH_FROM_PARENT,
                control,
                root,
                0,
                0,
                control_width,
                36,
                0,
                xproto::WindowClass::INPUT_OUTPUT,
                0,
                &xproto::CreateWindowAux::new()
                    .background_pixel(0x172533u32)
                    .override_redirect(1)
                    .event_mask(
                        xproto::EventMask::EXPOSURE
                            | xproto::EventMask::BUTTON_PRESS
                            | xproto::EventMask::BUTTON_RELEASE
                            | xproto::EventMask::POINTER_MOTION,
                    ),
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        connection
            .create_gc(
                gc,
                control,
                &xproto::CreateGCAux::new()
                    .foreground(0xffffffu32)
                    .background(0x172533u32),
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        connection
            .change_property8(
                xproto::PropMode::REPLACE,
                control,
                atoms.name,
                atoms.utf8,
                b"MCC desktop control - Pause / Resume / Cancel",
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        connection
            .change_property8(
                xproto::PropMode::REPLACE,
                control,
                xproto::AtomEnum::WM_CLASS,
                xproto::AtomEnum::STRING,
                b"mcc-control\0MCC\0",
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        connection
            .change_property32(
                xproto::PropMode::REPLACE,
                control,
                atoms.window_type,
                xproto::AtomEnum::ATOM,
                &[atoms.dock],
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        // Reserve the strip for EWMH managers that honor struts on override windows.
        connection
            .change_property32(
                xproto::PropMode::REPLACE,
                control,
                atoms.strut,
                xproto::AtomEnum::CARDINAL,
                &[0, 0, 36, 0],
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        connection
            .change_property32(
                xproto::PropMode::REPLACE,
                control,
                atoms.strut_partial,
                xproto::AtomEnum::CARDINAL,
                &[
                    0,
                    0,
                    36,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    u32::from(control_width) - 1,
                    0,
                    0,
                ],
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        connection
            .map_window(control)
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        let desktop = Self {
            connection,
            root,
            screen,
            control,
            gc,
            atoms,
            identities: RefCell::new(HashMap::new()),
            own_events: Vec::new(),
            release_fence: None,
            pending_pointer: Vec::new(),
            control_pointer: Vec::new(),
            events: VecDeque::new(),
            held_keys: Vec::new(),
            held_buttons: Vec::new(),
            logical_keys: HashMap::new(),
            remapped_keys: HashMap::new(),
            control_status: RefCell::new(String::new()),
        };
        desktop.draw_control("Ready - helper manages input permission")?;
        Ok(desktop)
    }
    fn property_u32(&self, id: u32, atom: u32, type_: xproto::AtomEnum) -> Result<Vec<u32>> {
        let reply = self
            .connection
            .get_property(false, id, atom, type_, 0, 4096)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        Ok(reply
            .value32()
            .map(|values| values.collect())
            .unwrap_or_default())
    }
    fn identity(&self, id: u32) -> Result<Identity> {
        let reply = self
            .connection
            .res_query_client_ids(&[res::ClientIdSpec {
                client: id,
                mask: res::ClientIdMask::LOCAL_CLIENT_PID,
            }])
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let pid = reply
            .ids
            .iter()
            .find(|entry| {
                entry
                    .spec
                    .mask
                    .contains(res::ClientIdMask::LOCAL_CLIENT_PID)
            })
            .and_then(|entry| (entry.value.len() == 1).then(|| entry.value[0]))
            .and_then(|pid| i32::try_from(pid).ok())
            .filter(|pid| *pid > 0)
            .ok_or_else(|| Error::new("WINDOW_UNVERIFIED", "XRes 未返回可信本地窗口进程"))?;
        let process = PathBuf::from(format!("/proc/{pid}"));
        let status = std::fs::read_to_string(process.join("status"))
            .map_err(|_| Error::new("WINDOW_UNAVAILABLE", "窗口进程已退出或无法读取"))?;
        let stat = std::fs::read_to_string(process.join("stat"))
            .map_err(|_| Error::new("WINDOW_UNAVAILABLE", "窗口进程已退出或无法读取"))?;
        let start = process_identity(&status, &stat, unsafe { libc::geteuid() })?;
        let executable = std::fs::read_link(process.join("exe"))
            .map_err(|_| Error::new("WINDOW_UNVERIFIED", "无法验证窗口进程可执行文件"))?;
        let identity = Identity {
            pid,
            start,
            executable,
        };
        let mut identities = self.identities.borrow_mut();
        if identities
            .get(&id)
            .is_some_and(|previous| previous != &identity)
        {
            return Err(Error::new(
                "WINDOW_UNAVAILABLE",
                "窗口资源或进程创建身份已变化",
            ));
        }
        identities.insert(id, identity.clone());
        Ok(identity)
    }
    fn describe(&self, id: u32) -> Result<Window> {
        if id == 0 || id == self.control || id == self.root {
            return Err(Error::new("WINDOW_UNAVAILABLE", "窗口不可控制"));
        }
        let attrs = self
            .connection
            .get_window_attributes(id)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        if attrs.map_state != xproto::MapState::VIEWABLE
            || attrs.class != xproto::WindowClass::INPUT_OUTPUT
            || attrs.override_redirect
        {
            return Err(Error::new("WINDOW_UNAVAILABLE", "窗口不可见或不是应用窗口"));
        }
        let identity = self.identity(id)?;
        let geometry = self
            .connection
            .get_geometry(id)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let origin = self
            .connection
            .translate_coordinates(id, self.root, 0, 0)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        if !origin.same_screen || geometry.width == 0 || geometry.height == 0 {
            return Err(Error::new("WINDOW_UNAVAILABLE", "窗口几何不可验证"));
        }
        let title = self
            .connection
            .get_property(false, id, self.atoms.name, self.atoms.utf8, 0, 1024)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?
            .value;
        let title = if title.is_empty() {
            self.connection
                .get_property(
                    false,
                    id,
                    xproto::AtomEnum::WM_NAME,
                    xproto::AtomEnum::STRING,
                    0,
                    1024,
                )
                .map_err(xerror)?
                .reply()
                .map_err(xerror)?
                .value
        } else {
            title
        };
        self.connection
            .change_window_attributes(
                id,
                &xproto::ChangeWindowAttributesAux::new().event_mask(
                    xproto::EventMask::FOCUS_CHANGE | xproto::EventMask::STRUCTURE_NOTIFY,
                ),
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        Ok(Window {
            window_id: id,
            pid: identity.pid,
            title: String::from_utf8_lossy(&title)
                .chars()
                .filter(|ch| !ch.is_control())
                .take(1024)
                .collect(),
            bundle_id: Some(format!("linux.{}.{}", identity.pid, identity.start)),
            app_name: identity
                .executable
                .file_name()
                .map(|name| name.to_string_lossy().into_owned()),
            bounds: Bounds {
                x: f64::from(origin.dst_x),
                y: f64::from(origin.dst_y),
                width: f64::from(geometry.width),
                height: f64::from(geometry.height),
            },
        })
    }
    pub fn windows(&self) -> Result<Vec<Window>> {
        let mut ids =
            self.property_u32(self.root, self.atoms.stacking, xproto::AtomEnum::WINDOW)?;
        if ids.is_empty() {
            ids = self.property_u32(self.root, self.atoms.clients, xproto::AtomEnum::WINDOW)?;
        }
        if ids.is_empty() {
            ids = self
                .connection
                .query_tree(self.root)
                .map_err(xerror)?
                .reply()
                .map_err(xerror)?
                .children;
        }
        let mut windows = Vec::new();
        for id in ids.into_iter().rev() {
            if let Ok(window) = self.describe(id) {
                windows.push(window);
            }
        }
        Ok(windows)
    }
    pub fn window(&self, id: u32, pid: i32) -> Result<Window> {
        let window = self.describe(id)?;
        if pid <= 0 || window.pid != pid {
            return Err(Error::new("WINDOW_UNAVAILABLE", "目标窗口所属进程不匹配"));
        }
        Ok(window)
    }
    pub fn activate(&self, id: u32) -> Result<()> {
        self.describe(id)?;
        let event = xproto::ClientMessageEvent::new(32, id, self.atoms.active, [2, 0, 0, 0, 0]);
        self.connection
            .send_event(
                false,
                self.root,
                xproto::EventMask::SUBSTRUCTURE_REDIRECT | xproto::EventMask::SUBSTRUCTURE_NOTIFY,
                event,
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        self.connection.flush().map_err(xerror)?;
        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline {
            if self.focused(id)? {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Err(Error::new(
            "FOCUS_UNVERIFIED",
            "窗口管理器未确认目标窗口获得焦点",
        ))
    }
    pub fn focused(&self, id: u32) -> Result<bool> {
        let active = self.property_u32(self.root, self.atoms.active, xproto::AtomEnum::WINDOW)?;
        if active.first().is_some_and(|active| *active != id) {
            return Ok(false);
        }
        let mut focused = self
            .connection
            .get_input_focus()
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?
            .focus;
        for _ in 0..32 {
            if focused == id {
                return Ok(true);
            }
            if focused == 0 || focused == 1 || focused == self.root {
                return Ok(false);
            }
            focused = self
                .connection
                .query_tree(focused)
                .map_err(xerror)?
                .reply()
                .map_err(xerror)?
                .parent;
        }
        Ok(false)
    }
    /// A picker is trusted only through XRes identity, parent, GTK role, type
    /// and modal state together. A title or advertised _NET_WM_PID is insufficient.
    pub fn file_dialog(&self, parent: &Window) -> Result<Window> {
        self.window(parent.window_id, parent.pid)?;
        let mut candidates = Vec::new();
        for window in self.windows()? {
            if window.pid != parent.pid || window.window_id == parent.window_id {
                continue;
            }
            let transient = self.property_u32(
                window.window_id,
                xproto::AtomEnum::WM_TRANSIENT_FOR.into(),
                xproto::AtomEnum::WINDOW,
            )?;
            let types = self.property_u32(
                window.window_id,
                self.atoms.window_type,
                xproto::AtomEnum::ATOM,
            )?;
            let states =
                self.property_u32(window.window_id, self.atoms.state, xproto::AtomEnum::ATOM)?;
            let role = self
                .connection
                .get_property(
                    false,
                    window.window_id,
                    self.atoms.role,
                    xproto::AtomEnum::STRING,
                    0,
                    64,
                )
                .map_err(xerror)?
                .reply()
                .map_err(xerror)?
                .value;
            if transient == [parent.window_id]
                && types.contains(&self.atoms.dialog_type)
                && states.contains(&self.atoms.modal)
                && role == b"GtkFileChooserDialog"
            {
                candidates.push(window);
            }
        }
        if candidates.len() != 1 {
            return Err(Error::new(
                if candidates.is_empty() {
                    "FILE_DIALOG_NOT_FOUND"
                } else {
                    "FILE_DIALOG_UNVERIFIED"
                },
                "未找到唯一、身份可验证的 Firefox GTK 文件选择框",
            ));
        }
        Ok(candidates.remove(0))
    }
    pub fn target_or_file_dialog_focused(&self, id: u32, pid: i32) -> Result<bool> {
        if self.focused(id)? {
            return Ok(true);
        }
        let parent = self.window(id, pid)?;
        match self.file_dialog(&parent) {
            Ok(dialog) => self.focused(dialog.window_id),
            Err(e)
                if matches!(
                    e.code.as_str(),
                    "FILE_DIALOG_NOT_FOUND" | "FILE_DIALOG_UNVERIFIED"
                ) =>
            {
                Ok(false)
            }
            Err(e) => Err(e),
        }
    }
    /// Capture an identity-verified window, or a crop wholly inside that window.
    /// Pixels are never resized, including when encoding would exceed the budget.
    pub fn capture(&self, window: &Window, path: &Path) -> Result<(u32, u32)> {
        let current = self.window(window.window_id, window.pid)?;
        if current.bundle_id != window.bundle_id || !contains_bounds(current.bounds, window.bounds)
        {
            return Err(Error::new(
                "FRAME_GEOMETRY_CHANGED",
                "截图区域不属于当前窗口，请重新 observe",
            ));
        }
        let screen = self
            .connection
            .get_geometry(self.root)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let rect = capture_rect(window.bounds, (screen.width, screen.height))?;
        let image = self
            .connection
            .get_image(
                xproto::ImageFormat::Z_PIXMAP,
                self.root,
                rect.x,
                rect.y,
                rect.width,
                rect.height,
                u32::MAX,
            )
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let setup = self.connection.setup();
        let format = setup
            .pixmap_formats
            .iter()
            .find(|format| format.depth == image.depth)
            .ok_or_else(|| Error::new("CAPTURE_UNSUPPORTED", "X11 截图深度不受支持"))?;
        let visual = setup.roots[self.screen]
            .allowed_depths
            .iter()
            .flat_map(|depth| depth.visuals.iter())
            .find(|visual| visual.visual_id == image.visual)
            .ok_or_else(|| Error::new("CAPTURE_UNSUPPORTED", "X11 截图 visual 无法确认"))?;
        if visual.class != xproto::VisualClass::TRUE_COLOR {
            return Err(Error::new(
                "CAPTURE_UNSUPPORTED",
                "截图仅支持 TrueColor 显示",
            ));
        }
        let rgb = decode_pixels(
            &image.data,
            rect.width,
            rect.height,
            format.bits_per_pixel,
            format.scanline_pad,
            setup.image_byte_order == xproto::ImageOrder::LSB_FIRST,
            [visual.red_mask, visual.green_mask, visual.blue_mask],
        )?;
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85)
            .encode(
                &rgb,
                u32::from(rect.width),
                u32::from(rect.height),
                image::ExtendedColorType::Rgb8,
            )
            .map_err(|error| {
                Error::new("CAPTURE_FAILED", &format!("截图 JPEG 编码失败: {error}"))
            })?;
        if jpeg.len() > 1024 * 1024 {
            return Err(Error::new(
                "IMAGE_TOO_LARGE",
                "原像素 JPEG 超过 1MiB；请缩小窗口或截图区域",
            ));
        }
        // Verify after capture as well: movement/reparenting invalidates these pixels.
        let after = self.window(window.window_id, window.pid)?;
        if after.bounds != current.bounds || after.bundle_id != current.bundle_id {
            return Err(Error::new(
                "FRAME_GEOMETRY_CHANGED",
                "截图期间窗口几何已变化",
            ));
        }
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(path)
            .map_err(|error| Error::io("无法创建截图文件", error))?;
        use std::io::Write;
        if let Err(error) = file.write_all(&jpeg) {
            let _ = std::fs::remove_file(path);
            return Err(Error::io("无法写入截图", error));
        }
        Ok((u32::from(rect.width), u32::from(rect.height)))
    }
    pub fn draw_control(&self, status: &str) -> Result<()> {
        if self.control_status.borrow().as_str() == status {
            return Ok(());
        }
        self.control_status.replace(status.to_owned());
        self.paint_control(status)
    }
    fn paint_control(&self, status: &str) -> Result<()> {
        self.connection
            .configure_window(
                self.control,
                &xproto::ConfigureWindowAux::new().stack_mode(xproto::StackMode::ABOVE),
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        self.connection
            .clear_area(false, self.control, 0, 0, 0, 0)
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        self.connection
            .poly_rectangle(
                self.control,
                self.gc,
                &[
                    xproto::Rectangle {
                        x: 4,
                        y: 4,
                        width: 70,
                        height: 27,
                    },
                    xproto::Rectangle {
                        x: 80,
                        y: 4,
                        width: 78,
                        height: 27,
                    },
                    xproto::Rectangle {
                        x: 164,
                        y: 4,
                        width: 78,
                        height: 27,
                    },
                ],
            )
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        for (x, text) in [
            (12, b"Pause".as_slice()),
            (88, b"Resume".as_slice()),
            (172, b"Cancel".as_slice()),
        ] {
            self.connection
                .image_text8(self.control, self.gc, x, 22, text)
                .map_err(xerror)?
                .check()
                .map_err(xerror)?;
        }
        let text = status
            .chars()
            .map(|ch| {
                if ch.is_ascii_graphic() || ch == ' ' {
                    ch as u8
                } else {
                    b'?'
                }
            })
            .take(80)
            .collect::<Vec<_>>();
        self.connection
            .image_text8(self.control, self.gc, 254, 22, &text)
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        self.connection.flush().map_err(xerror)
    }
    fn collect_events(&mut self) -> Result<()> {
        for _ in 0..4096 {
            let Some(event) = self.connection.poll_for_event().map_err(xerror)? else {
                break;
            };
            let raw = match &event {
                Event::XinputRawKeyPress(e) => Some((
                    Injected {
                        sequence: e.sequence,
                        kind: 2,
                        detail: e.detail,
                    },
                    e.time,
                )),
                Event::XinputRawKeyRelease(e) => Some((
                    Injected {
                        sequence: e.sequence,
                        kind: 3,
                        detail: e.detail,
                    },
                    e.time,
                )),
                Event::XinputRawButtonPress(e) => Some((
                    Injected {
                        sequence: e.sequence,
                        kind: 4,
                        detail: e.detail,
                    },
                    e.time,
                )),
                Event::XinputRawButtonRelease(e) => Some((
                    Injected {
                        sequence: e.sequence,
                        kind: 5,
                        detail: e.detail,
                    },
                    e.time,
                )),
                Event::XinputRawMotion(e) => Some((
                    Injected {
                        sequence: e.sequence,
                        kind: 6,
                        detail: e.detail,
                    },
                    e.time,
                )),
                _ => None,
            };
            if let Some((raw, time)) = raw {
                if !consume_own(&mut self.own_events, raw, self.release_fence) {
                    if matches!(raw.kind, 2 | 3) {
                        self.queue_event(DesktopEvent::UserInteraction);
                    } else {
                        self.raw_pointer(PointerStamp {
                            kind: raw.kind,
                            detail: raw.detail,
                            time,
                        });
                    }
                }
                continue;
            }
            match event {
                Event::MotionNotify(e) if e.event == self.control => {
                    self.control_pointer_event(PointerStamp {
                        kind: 6,
                        detail: 0,
                        time: e.time,
                    });
                }
                Event::ButtonRelease(e) if e.event == self.control => {
                    self.control_pointer_event(PointerStamp {
                        kind: 5,
                        detail: u32::from(e.detail),
                        time: e.time,
                    });
                }
                Event::ButtonPress(e) if e.event == self.control => {
                    self.control_pointer_event(PointerStamp {
                        kind: 4,
                        detail: u32::from(e.detail),
                        time: e.time,
                    });
                    if e.detail != 1 {
                        continue;
                    }
                    let action = if (4..75).contains(&e.event_x) {
                        Some(DesktopEvent::Pause)
                    } else if (80..159).contains(&e.event_x) {
                        Some(DesktopEvent::Resume)
                    } else if (164..243).contains(&e.event_x) {
                        Some(DesktopEvent::Cancel)
                    } else {
                        None
                    };
                    if let Some(action) = action {
                        // Input records preceding an explicit control intent
                        // must be delivered before it, including pointer motion
                        // queued within this same polling interval.
                        if !self.pending_pointer.is_empty() {
                            self.pending_pointer.clear();
                            self.queue_event(DesktopEvent::UserInteraction);
                        }
                        self.queue_event(action);
                    }
                }
                Event::Expose(e) if e.window == self.control && e.count == 0 => {
                    let status = self.control_status.borrow().clone();
                    self.paint_control(&status)?;
                }
                Event::PropertyNotify(e)
                    if e.window == self.root && e.atom == self.atoms.active =>
                {
                    self.queue_event(DesktopEvent::FocusChanged)
                }
                Event::FocusIn(_) | Event::FocusOut(_) => {
                    self.queue_event(DesktopEvent::FocusChanged)
                }
                Event::DestroyNotify(e) => {
                    self.identities.borrow_mut().remove(&e.window);
                }
                // Keep the control strip above newly mapped/raised applications.
                Event::MapNotify(e) if e.window != self.control => {
                    self.connection
                        .configure_window(
                            self.control,
                            &xproto::ConfigureWindowAux::new().stack_mode(xproto::StackMode::ABOVE),
                        )
                        .map_err(xerror)?;
                }
                Event::ConfigureNotify(e) if e.window != self.control => {
                    self.connection
                        .configure_window(
                            self.control,
                            &xproto::ConfigureWindowAux::new().stack_mode(xproto::StackMode::ABOVE),
                        )
                        .map_err(xerror)?;
                }
                _ => {}
            }
        }
        let now = Instant::now();
        let mut human = false;
        self.pending_pointer.retain(|pointer| {
            if now.duration_since(pointer.received) >= Duration::from_millis(20) {
                human = true;
                false
            } else {
                true
            }
        });
        self.control_pointer
            .retain(|pointer| now.duration_since(pointer.received) < Duration::from_millis(100));
        if human {
            self.queue_event(DesktopEvent::UserInteraction);
        }
        self.connection.flush().map_err(xerror)
    }
    fn raw_pointer(&mut self, stamp: PointerStamp) {
        if let Some(index) = self
            .control_pointer
            .iter()
            .position(|event| event.stamp == stamp)
        {
            self.control_pointer.remove(index);
        } else {
            self.pending_pointer.push(PendingPointer {
                stamp,
                received: Instant::now(),
            });
        }
    }
    fn control_pointer_event(&mut self, stamp: PointerStamp) {
        if let Some(index) = self
            .pending_pointer
            .iter()
            .position(|event| event.stamp == stamp)
        {
            self.pending_pointer.remove(index);
        } else {
            self.control_pointer.push(PendingPointer {
                stamp,
                received: Instant::now(),
            });
        }
    }
    fn explicit_stop_pending(&self) -> bool {
        self.events
            .iter()
            .any(|event| matches!(event, DesktopEvent::Pause | DesktopEvent::Cancel))
    }
    fn queue_event(&mut self, event: DesktopEvent) {
        if self.events.back() != Some(&event) {
            self.events.push_back(event);
        }
    }
    pub fn poll_events(&mut self) -> Result<Vec<DesktopEvent>> {
        self.collect_events()?;
        Ok(self.events.drain(..).collect())
    }
    fn inject(&mut self, kind: u8, detail: u8, x: i16, y: i16) -> Result<()> {
        // Explicit control-strip stops interrupt presses/moves. Ordinary noVNC
        // activity does not block input in the dedicated container desktop.
        self.collect_events()?;
        if matches!(kind, 2 | 4 | 6) && self.explicit_stop_pending() {
            return Err(Error::new(
                "USER_PAUSED",
                "已收到明确暂停或取消，停止后续 X11 注入",
            ));
        }
        let result = (|| {
            let cookie = self
                .connection
                .xtest_fake_input(kind, detail, 0, self.root, x, y, 0)
                .map_err(xerror)?;
            // Register ownership only after this client's request was queued.
            // A refused down event must not make cleanup release a user's key.
            if kind == 2 && !self.held_keys.contains(&detail) {
                self.held_keys.push(detail);
            }
            if kind == 4 && !self.held_buttons.contains(&detail) {
                self.held_buttons.push(detail);
            }
            self.own_events.push(Injected {
                sequence: cookie.sequence_number() as u16,
                kind,
                detail: u32::from(detail),
            });
            cookie.check().map_err(xerror)?;
            let fence = self
                .connection
                .get_input_focus()
                .map_err(xerror)?
                .reply()
                .map_err(xerror)?
                .sequence;
            // Releasing an implicit grab can defer its raw release until the
            // sync request. Only releases of our already-owned key/button may
            // use this bounded sequence interval; presses/motion stay exact.
            self.release_fence = matches!(kind, 3 | 5).then_some(fence);
            self.collect_events()?;
            let deadline = Instant::now() + Duration::from_millis(20);
            while self.release_fence.is_some()
                && !self.own_events.is_empty()
                && Instant::now() < deadline
            {
                std::thread::sleep(Duration::from_millis(1));
                self.collect_events()?;
            }
            if kind == 3 {
                self.held_keys.retain(|key| *key != detail);
            }
            if kind == 5 {
                self.held_buttons.retain(|button| *button != detail);
            }
            Ok(())
        })();
        // No expectation survives this request or an error. A later noVNC
        // event cannot be discarded as an old injected event.
        self.own_events.clear();
        self.release_fence = None;
        result
    }
    fn before_input(&mut self, window: &Window) -> Result<()> {
        self.collect_events()?;
        if self.explicit_stop_pending() {
            return Err(Error::new(
                "USER_PAUSED",
                "已收到明确暂停或取消，请由 helper 重新确认许可",
            ));
        }
        let current = self.window(window.window_id, window.pid)?;
        if current.bounds != window.bounds || current.bundle_id != window.bundle_id {
            return Err(Error::new("FRAME_GEOMETRY_CHANGED", "窗口几何或身份已变化"));
        }
        if !self.focused(window.window_id)? {
            return Err(Error::new("FOCUS_LOST", "目标窗口已失去焦点"));
        }
        let pointer = self
            .connection
            .query_pointer(self.root)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let mut keys = self
            .connection
            .query_keymap()
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?
            .keys;
        let mut mask = u16::from(pointer.mask);
        for button in &self.held_buttons {
            if (1..=5).contains(button) {
                mask &= !(1 << (7 + button));
            }
        }
        for code in &self.held_keys {
            keys[usize::from(*code) / 8] &= !(1 << (code % 8));
        }
        let modifiers = self
            .connection
            .get_modifier_mapping()
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let per = modifiers.keycodes.len() / 8;
        if per > 0 {
            for (i, codes) in modifiers.keycodes.chunks(per).enumerate() {
                if codes.iter().any(|code| self.held_keys.contains(code)) {
                    mask &= !(1 << i);
                }
            }
        }
        if !input_state_clear(mask, &keys) {
            return Err(Error::new(
                "INPUT_BUSY",
                "桌面已有按键、鼠标按钮或修饰键状态；释放后可发送新操作，无需解除暂停",
            ));
        }
        Ok(())
    }
    fn keycode(&self, keysym: u32) -> Result<(u8, bool)> {
        let min = self.connection.setup().min_keycode;
        let max = self.connection.setup().max_keycode;
        let mapping = self
            .connection
            .get_keyboard_mapping(min, max - min + 1)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let width = usize::from(mapping.keysyms_per_keycode);
        if width > 0 {
            for (index, keysyms) in mapping.keysyms.chunks(width).enumerate() {
                for (column, symbol) in keysyms.iter().take(2).enumerate() {
                    if *symbol == keysym {
                        return Ok((min + index as u8, column == 1));
                    }
                }
            }
        }
        Err(Error::new(
            "ACTION_UNSUPPORTED",
            "当前 X11 键盘布局没有所需按键；未执行输入",
        ))
    }
    fn key_down(&mut self, key: u8) -> Result<()> {
        self.inject(2, key, 0, 0)
    }
    fn key_up(&mut self, key: u8) -> Result<()> {
        self.inject(3, key, 0, 0)
    }
    fn release_all(&mut self) -> Result<()> {
        while let Some(button) = self.held_buttons.last().copied() {
            self.inject(5, button, 0, 0)
                .map_err(|_| Error::new("RELEASE_UNCONFIRMED", "无法确认 X11 鼠标释放"))?;
        }
        while let Some(key) = self.held_keys.last().copied() {
            self.key_up(key)
                .map_err(|_| Error::new("RELEASE_UNCONFIRMED", "无法确认 X11 按键释放"))?;
        }
        self.logical_keys.clear();
        for code in self.remapped_keys.keys().copied().collect::<Vec<_>>() {
            self.restore_key(code)?;
        }
        self.connection.flush().map_err(xerror)?;
        Ok(())
    }
    pub fn screen_size(&self) -> (u32, u32) {
        let screen = &self.connection.setup().roots[self.screen];
        (
            u32::from(screen.width_in_pixels),
            u32::from(screen.height_in_pixels),
        )
    }
    pub fn pointer_position(&self) -> Result<(i64, i64)> {
        let p = self
            .connection
            .query_pointer(self.root)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        Ok((i64::from(p.root_x), i64::from(p.root_y)))
    }
    pub fn release_inputs(&mut self) -> Result<()> {
        self.release_all()
    }
    fn restore_key(&mut self, code: u8) -> Result<()> {
        if let Some(symbols) = self.remapped_keys.get(&code) {
            self.connection
                .change_keyboard_mapping(1, code, symbols.len() as u8, symbols)
                .map_err(xerror)?
                .check()
                .map_err(xerror)?;
            // Keep the original map available for cleanup if restoration fails.
            self.remapped_keys.remove(&code);
        }
        Ok(())
    }
    fn action_key(&mut self, value: &str, literal: bool) -> Result<(u8, bool)> {
        let ch = value
            .chars()
            .next()
            .filter(|_| value.chars().count() == 1)
            .ok_or_else(|| Error::invalid("系统动作按键无效"))?;
        let symbol = if literal {
            if (ch as u32) <= 0xff {
                ch as u32
            } else {
                0x01000000 | ch as u32
            }
        } else {
            match ch {
                '\u{e008}' => 0xffe1,
                '\u{e009}' => 0xffe3,
                '\u{e00a}' => 0xffe9,
                '\u{e03d}' => 0xffeb,
                '\u{e007}' => 0xff0d,
                '\u{e004}' => 0xff09,
                '\u{e00c}' => 0xff1b,
                '\u{e003}' => 0xff08,
                '\u{e017}' => 0xffff,
                '\u{e012}' => 0xff51,
                '\u{e013}' => 0xff52,
                '\u{e014}' => 0xff53,
                '\u{e015}' => 0xff54,
                '\u{e011}' => 0xff50,
                '\u{e010}' => 0xff57,
                '\u{e00e}' => 0xff55,
                '\u{e00f}' => 0xff56,
                c if (c as u32) <= 0xff => c as u32,
                c => 0x01000000 | c as u32,
            }
        };
        if let Ok(mapped) = self.keycode(symbol) {
            return Ok(mapped);
        }
        let min = self.connection.setup().min_keycode;
        let max = self.connection.setup().max_keycode;
        let map = self
            .connection
            .get_keyboard_mapping(min, max - min + 1)
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let width = usize::from(map.keysyms_per_keycode);
        if width == 0 {
            return Err(Error::new("ACTION_UNSUPPORTED", "X11 键盘映射为空"));
        }
        let modifiers = self
            .connection
            .get_modifier_mapping()
            .map_err(xerror)?
            .reply()
            .map_err(xerror)?;
        let free = map
            .keysyms
            .chunks(width)
            .enumerate()
            .rev()
            .find(|(i, syms)| {
                let code = min + *i as u8;
                syms.iter().all(|s| *s == 0)
                    && !modifiers.keycodes.contains(&code)
                    && !self.remapped_keys.contains_key(&code)
            })
            .map(|(i, syms)| (min + i as u8, syms.to_vec()))
            .ok_or_else(|| {
                Error::new(
                    "ACTION_UNSUPPORTED",
                    "没有可用于 Unicode 系统输入的空闲键码",
                )
            })?;
        let mut symbols = vec![0; width];
        symbols[0] = symbol;
        self.connection
            .change_keyboard_mapping(1, free.0, map.keysyms_per_keycode, &symbols)
            .map_err(xerror)?
            .check()
            .map_err(xerror)?;
        self.remapped_keys.insert(free.0, free.1);
        Ok((free.0, false))
    }
    /// Consume only the closed action vocabulary emitted by the existing
    /// compiler. These are XTEST events, with no browser protocol connection.
    pub fn perform(&mut self, window: &Window, plan: &Value, literal_text: bool) -> Result<()> {
        for source in plan["actions"]
            .as_array()
            .ok_or_else(|| Error::invalid("系统动作计划无效"))?
        {
            for action in source["actions"]
                .as_array()
                .ok_or_else(|| Error::invalid("系统动作步骤无效"))?
            {
                self.before_input(window)?;
                match action["type"].as_str().unwrap_or("") {
                    "pointerMove" => {
                        let x = action["x"]
                            .as_i64()
                            .ok_or_else(|| Error::invalid("系统坐标无效"))?;
                        let y = action["y"]
                            .as_i64()
                            .ok_or_else(|| Error::invalid("系统坐标无效"))?;
                        let (w, h) = self.screen_size();
                        if x < 0
                            || y < 0
                            || x >= w as i64
                            || y >= h as i64
                            || x > i16::MAX as i64
                            || y > i16::MAX as i64
                        {
                            return Err(Error::invalid("系统坐标超出显示范围"));
                        }
                        self.inject(6, 0, x as i16, y as i16)?;
                    }
                    "pointerDown" | "pointerUp" => {
                        let button = action["button"]
                            .as_u64()
                            .filter(|n| *n <= 2)
                            .ok_or_else(|| Error::invalid("系统按钮无效"))?
                            as u8
                            + 1;
                        if action["type"] == "pointerDown"
                            && !self.pointer_in_window(window.window_id)?
                        {
                            return Err(Error::new("FOCUS_UNVERIFIED", "目标点被其他窗口覆盖"));
                        }
                        self.inject(
                            if action["type"] == "pointerDown" {
                                4
                            } else {
                                5
                            },
                            button,
                            0,
                            0,
                        )?;
                    }
                    "keyDown" => {
                        let value = action["value"]
                            .as_str()
                            .ok_or_else(|| Error::invalid("系统按键无效"))?;
                        let (code, shift) = self.action_key(value, literal_text)?;
                        let shift = if shift {
                            Some(self.keycode(0xffe1)?.0)
                        } else {
                            None
                        };
                        if let Some(code) = shift {
                            if !self.held_keys.contains(&code) {
                                self.key_down(code)?;
                            }
                        }
                        if !self.held_keys.contains(&code) {
                            self.key_down(code)?;
                        }
                        self.logical_keys.insert(value.into(), (code, shift));
                        // Allow clients to consume the changed XKB map and the
                        // key event before restoring a temporary Unicode key.
                        if self.remapped_keys.contains_key(&code) {
                            std::thread::sleep(Duration::from_millis(20));
                        }
                    }
                    "keyUp" => {
                        let value = action["value"]
                            .as_str()
                            .ok_or_else(|| Error::invalid("系统按键无效"))?;
                        let (code, implicit) = self
                            .logical_keys
                            .remove(value)
                            .ok_or_else(|| Error::invalid("系统按键未按下"))?;
                        for key in [Some(code), implicit].into_iter().flatten() {
                            if !self
                                .logical_keys
                                .values()
                                .any(|(c, s)| *c == key || *s == Some(key))
                            {
                                self.key_up(key)?;
                            }
                        }
                        if self.remapped_keys.contains_key(&code) && !self.held_keys.contains(&code)
                        {
                            std::thread::sleep(Duration::from_millis(10));
                            self.restore_key(code)?;
                        }
                    }
                    "scroll" => {
                        let x = action["x"]
                            .as_i64()
                            .ok_or_else(|| Error::invalid("滚动坐标无效"))?;
                        let y = action["y"]
                            .as_i64()
                            .ok_or_else(|| Error::invalid("滚动坐标无效"))?;
                        let delta = action["deltaY"]
                            .as_i64()
                            .filter(|n| *n != 0 && (-1200..=1200).contains(n))
                            .ok_or_else(|| Error::invalid("滚动距离无效"))?;
                        self.inject(6, 0, x as i16, y as i16)?;
                        if !self.pointer_in_window(window.window_id)? {
                            return Err(Error::new("FOCUS_UNVERIFIED", "滚动目标被覆盖"));
                        }
                        for _ in 0..delta.unsigned_abs().div_ceil(120) {
                            self.before_input(window)?;
                            let button = if delta > 0 { 5 } else { 4 };
                            self.inject(4, button, 0, 0)?;
                            self.inject(5, button, 0, 0)?;
                        }
                    }
                    _ => return Err(Error::invalid("未知系统动作")),
                }
            }
        }
        Ok(())
    }
    pub fn native_input(&mut self, window: &Window, request: &Value) -> Result<()> {
        if request["action"] == "release-inputs" {
            validate_native(window, request)?;
            return self.release_all();
        }
        let current = self.window(window.window_id, window.pid)?;
        validate_native(&current, request)?;
        if current.bundle_id != window.bundle_id || current.bounds != window.bounds {
            return Err(Error::new("FRAME_GEOMETRY_CHANGED", "输入目标窗口已变化"));
        }
        // Preflight every key before issuing the first event; unsupported text
        // must never leave a partially typed prefix in a native dialog.
        let action = request["action"].as_str().unwrap();
        let mut keys = Vec::new();
        if action == "type" {
            let text = request["text"].as_str().unwrap();
            if text.len() > 16 {
                return Err(Error::new(
                    "ACTION_UNSUPPORTED",
                    "原生文本单段最多 16 个 ASCII 字符；helper 必须分段检查输入许可",
                ));
            }
            for ch in text.bytes() {
                let (code, shift) = self.keycode(u32::from(ch))?;
                keys.push((
                    code,
                    if shift {
                        Some(self.keycode(0xffe1)?.0)
                    } else {
                        None
                    },
                ));
            }
        } else if action == "press" {
            let (symbol, modifier) = key_spec(request["key"].as_str().unwrap()).unwrap();
            let (code, shift) = self.keycode(symbol)?;
            let modifier = if let Some(modifier) = modifier {
                Some(self.keycode(modifier)?.0)
            } else if shift {
                Some(self.keycode(0xffe1)?.0)
            } else {
                None
            };
            keys.push((code, modifier));
        }
        self.before_input(window)?;
        let result = (|| {
            match action {
                "click" | "scroll" => {
                    let x = request["screenX"].as_f64().unwrap().floor() as i16;
                    let y = request["screenY"].as_f64().unwrap().floor() as i16;
                    self.inject(6, 0, x, y)?;
                    self.before_input(window)?;
                    // QueryPointer resolves the child under the cursor; prevent a
                    // click from reaching a floating window over the selected one.
                    if !self.pointer_in_window(window.window_id)? {
                        return Err(Error::new("FOCUS_UNVERIFIED", "目标点被其他窗口覆盖"));
                    }
                    let (button, count) = if action == "click" {
                        (1, request["clickCount"].as_u64().unwrap() as usize)
                    } else {
                        let delta = request["deltaY"].as_i64().unwrap();
                        (
                            if delta > 0 { 5 } else { 4 },
                            delta.unsigned_abs().div_ceil(120) as usize,
                        )
                    };
                    for _ in 0..count {
                        self.before_input(window)?;
                        self.inject(4, button, 0, 0)?;
                        self.inject(5, button, 0, 0)?;
                    }
                }
                "type" | "press" => {
                    for (code, modifier) in keys {
                        self.before_input(window)?;
                        if let Some(modifier) = modifier {
                            self.key_down(modifier)?;
                        }
                        self.key_down(code)?;
                        self.key_up(code)?;
                        if let Some(modifier) = modifier {
                            self.key_up(modifier)?;
                        }
                    }
                }
                _ => return Err(Error::new("ACTION_UNSUPPORTED", "原生动作不受支持")),
            }
            Ok(())
        })();
        let release = self.release_all();
        release?;
        result
    }
    fn pointer_in_window(&self, id: u32) -> Result<bool> {
        let mut current = self.root;
        for _ in 0..32 {
            let pointer = self
                .connection
                .query_pointer(current)
                .map_err(xerror)?
                .reply()
                .map_err(xerror)?;
            if current == id {
                return Ok(true);
            }
            if pointer.child == 0 {
                return Ok(false);
            }
            current = pointer.child;
        }
        Ok(false)
    }
}
impl Drop for Desktop {
    fn drop(&mut self) {
        let _ = self.release_all();
        let _ = self.connection.destroy_window(self.control);
        let _ = self.connection.free_gc(self.gc);
        let _ = self.connection.flush();
    }
}
fn contains_bounds(outer: Bounds, inner: Bounds) -> bool {
    [inner.x, inner.y, inner.width, inner.height]
        .iter()
        .all(|v| v.is_finite())
        && inner.width > 0.
        && inner.height > 0.
        && inner.x >= outer.x
        && inner.y >= outer.y
        && inner.x + inner.width <= outer.x + outer.width
        && inner.y + inner.height <= outer.y + outer.height
}

fn input_state_clear(mask: u16, keys: &[u8; 32]) -> bool {
    mask == 0 && keys.iter().all(|byte| *byte == 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn window() -> Window {
        Window {
            window_id: 17,
            pid: 51,
            title: "Dialog".into(),
            bundle_id: Some("linux.51.9".into()),
            app_name: Some("test".into()),
            bounds: Bounds {
                x: 12.,
                y: 40.,
                width: 400.,
                height: 200.,
            },
        }
    }
    #[test]
    fn capture_keeps_original_pixels_and_rejects_clipping_or_scaling() {
        assert_eq!(
            capture_rect(window().bounds, (1280, 800)).unwrap(),
            CaptureRect {
                x: 12,
                y: 40,
                width: 400,
                height: 200
            }
        );
        for b in [
            Bounds {
                x: -1.,
                ..window().bounds
            },
            Bounds {
                x: 1800.,
                ..window().bounds
            },
            Bounds {
                width: 1601.,
                ..window().bounds
            },
            Bounds {
                x: 12.5,
                ..window().bounds
            },
            Bounds {
                width: f64::NAN,
                ..window().bounds
            },
        ] {
            assert!(capture_rect(b, (1920, 1080)).is_err());
        }
    }
    #[test]
    fn screenshot_decodes_x11_channel_masks_and_row_padding() {
        let rgb = decode_pixels(
            &[0, 0, 255, 0, 0, 255, 0, 0],
            1,
            2,
            32,
            32,
            true,
            [0xff0000, 0xff00, 0xff],
        )
        .unwrap();
        assert_eq!(rgb, [255, 0, 0, 0, 255, 0]);
        let rgb = decode_pixels(
            &[0xf8, 0x00, 0, 0],
            1,
            1,
            16,
            32,
            false,
            [0xf800, 0x7e0, 0x1f],
        )
        .unwrap();
        assert_eq!(rgb, [255, 0, 0]);
        assert!(decode_pixels(&[0], 1, 1, 32, 32, true, [0xff0000, 0xff00, 0xff]).is_err());
    }
    #[test]
    fn own_event_filter_consumes_one_exact_event_and_preserves_other_xtest_input() {
        let own = Injected {
            sequence: 42,
            kind: 4,
            detail: 1,
        };
        let mut pending = vec![own];
        assert!(!consume_own(
            &mut pending,
            Injected {
                sequence: 41,
                ..own
            },
            None
        ));
        assert!(!consume_own(
            &mut pending,
            Injected { detail: 3, ..own },
            None
        ));
        assert!(consume_own(&mut pending, own, None));
        assert!(!consume_own(&mut pending, own, None));
    }
    #[test]
    fn delayed_release_filter_is_bounded_and_never_matches_a_press_or_motion() {
        let release = Injected {
            sequence: 65535,
            kind: 5,
            detail: 1,
        };
        let mut pending = vec![release];
        for event in [
            Injected {
                sequence: 65534,
                ..release
            },
            Injected {
                sequence: 2,
                ..release
            },
            Injected {
                sequence: 0,
                kind: 4,
                ..release
            },
            Injected {
                sequence: 0,
                kind: 6,
                ..release
            },
            Injected {
                sequence: 0,
                detail: 3,
                ..release
            },
        ] {
            assert!(!consume_own(&mut pending, event, Some(1)));
        }
        assert!(consume_own(
            &mut pending,
            Injected {
                sequence: 0,
                ..release
            },
            Some(1)
        ));
        assert!(!consume_own(
            &mut pending,
            Injected {
                sequence: 0,
                ..release
            },
            Some(1)
        ));
    }
    #[test]
    fn native_input_requires_current_identity_geometry_and_in_window_point() {
        let w = window();
        let request = json!({"action":"click","windowId":17,"pid":51,"bundleId":"linux.51.9","expectedBounds":w.bounds,"screenX":12,"screenY":40,"clickCount":1});
        validate_native(&w, &request).unwrap();
        for (name, value) in [
            ("screenX", json!(412)),
            ("pid", json!(52)),
            ("clickCount", json!(3)),
            ("extra", json!(true)),
        ] {
            let mut bad = request.clone();
            bad[name] = value;
            assert!(validate_native(&w, &bad).is_err(), "{name}");
        }
        let mut stale = request.clone();
        stale["expectedBounds"]["x"] = json!(13);
        assert!(validate_native(&w, &stale).is_err());
    }
    #[test]
    fn native_input_rejects_unknown_actions_and_unicode_without_partial_input() {
        let w = window();
        let mut request = json!({"action":"type","windowId":17,"pid":51,"expectedBounds":w.bounds,"text":"safe ASCII!"});
        validate_native(&w, &request).unwrap();
        request["text"] = json!("中文");
        assert_eq!(
            validate_native(&w, &request).unwrap_err().code,
            "ACTION_UNSUPPORTED"
        );
        request["action"] = json!("execute-script");
        assert!(validate_native(&w, &request).is_err());
    }
    #[test]
    fn process_identity_rejects_foreign_uid_and_parses_parentheses_in_comm() {
        let stat = "51 (name with ) chars) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 12345 0";
        assert_eq!(
            process_identity("Name:\ttest\nUid:\t1000\t1000\t1000\t1000\n", stat, 1000).unwrap(),
            12345
        );
        assert!(process_identity("Uid:\t1001\t1001\t1001\t1001\n", stat, 1000).is_err());
        assert!(process_identity("Uid:\t1000\t0\t0\t1000\n", stat, 1000).is_err());
    }
    /// Run in the managed Xvfb/Openbox desktop, never the host display.
    #[test]
    #[ignore = "requires dedicated local Xvfb and EWMH window manager"]
    fn live_x11_identity_capture_native_input_and_foreign_xtest_takeover() {
        assert_eq!(
            std::env::var("MCC_X11_TEST").as_deref(),
            Ok("1"),
            "set MCC_X11_TEST=1 only on an isolated test display"
        );
        let mut desktop = Desktop::connect().unwrap();
        let (client, screen) = x11rb::connect(None).unwrap();
        let root = client.setup().roots[screen].root;
        let id = client.generate_id().unwrap();
        client
            .create_window(
                x11rb::COPY_DEPTH_FROM_PARENT,
                id,
                root,
                100,
                120,
                400,
                200,
                0,
                xproto::WindowClass::INPUT_OUTPUT,
                0,
                &xproto::CreateWindowAux::new()
                    .background_pixel(0x336699u32)
                    .event_mask(
                        xproto::EventMask::BUTTON_PRESS
                            | xproto::EventMask::BUTTON_RELEASE
                            | xproto::EventMask::KEY_PRESS
                            | xproto::EventMask::KEY_RELEASE,
                    ),
            )
            .unwrap()
            .check()
            .unwrap();
        // A malicious PID property must not affect XRes's actual client identity.
        let pid_atom = client
            .intern_atom(false, b"_NET_WM_PID")
            .unwrap()
            .reply()
            .unwrap()
            .atom;
        client
            .change_property32(
                xproto::PropMode::REPLACE,
                id,
                pid_atom,
                xproto::AtomEnum::CARDINAL,
                &[1],
            )
            .unwrap()
            .check()
            .unwrap();
        client
            .change_property8(
                xproto::PropMode::REPLACE,
                id,
                xproto::AtomEnum::WM_NAME,
                xproto::AtomEnum::STRING,
                b"MCC isolated X11 behavior test",
            )
            .unwrap()
            .check()
            .unwrap();
        client.map_window(id).unwrap().check().unwrap();
        client.flush().unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let window = loop {
            // EWMH publication, not mere map state, proves Openbox has finished
            // managing the client before the activation request is sent.
            if desktop
                .property_u32(root, desktop.atoms.clients, xproto::AtomEnum::WINDOW)
                .unwrap()
                .contains(&id)
            {
                break desktop.window(id, std::process::id() as i32).unwrap();
            }
            assert!(Instant::now() < deadline, "test window never managed");
            std::thread::sleep(Duration::from_millis(20));
        };
        assert_eq!(window.pid, std::process::id() as i32);
        assert!(desktop.window(id, window.pid + 1).is_err());
        desktop.activate(id).unwrap();
        assert!(desktop.focused(id).unwrap());
        let window = desktop.window(id, window.pid).unwrap();
        let crop = Window {
            bounds: Bounds {
                x: window.bounds.x + 20.,
                y: window.bounds.y + 20.,
                width: 80.,
                height: 60.,
            },
            ..window.clone()
        };
        let path = std::env::temp_dir().join(format!(
            "mcc-x11-{}-{}.jpg",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        assert_eq!(desktop.capture(&crop, &path).unwrap(), (80, 60));
        let jpeg = image::open(&path).unwrap().into_rgb8();
        assert_eq!(jpeg.dimensions(), (80, 60));
        for (actual, expected) in jpeg.get_pixel(30, 30).0.iter().zip([51i16, 102, 153]) {
            assert!((i16::from(*actual) - expected).abs() <= 3);
        }
        std::fs::remove_file(path).unwrap();
        desktop.poll_events().unwrap();
        while client.poll_for_event().unwrap().is_some() {}
        let request = json!({"action":"click","windowId":id,"pid":window.pid,"bundleId":window.bundle_id,"expectedBounds":window.bounds,"screenX":window.bounds.x+30.,"screenY":window.bounds.y+30.,"clickCount":1});
        desktop.native_input(&window, &request).unwrap();
        assert!(
            !desktop
                .poll_events()
                .unwrap()
                .contains(&DesktopEvent::UserInteraction),
            "own exact XTEST events caused user takeover"
        );
        client.get_input_focus().unwrap().reply().unwrap();
        let mut presses = 0;
        let mut releases = 0;
        let delivery_deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < delivery_deadline && (presses, releases) != (1, 1) {
            while let Some(event) = client.poll_for_event().unwrap() {
                match event {
                    Event::ButtonPress(e) if e.event == id => presses += 1,
                    Event::ButtonRelease(e) if e.event == id => releases += 1,
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            (presses, releases),
            (1, 1),
            "native click did not reach selected client"
        );
        let type_request = json!({"action":"type","windowId":id,"pid":window.pid,"expectedBounds":window.bounds,"text":"A"});
        desktop.native_input(&window, &type_request).unwrap();
        assert!(!desktop
            .poll_events()
            .unwrap()
            .contains(&DesktopEvent::UserInteraction));
        let mut key_presses = Vec::new();
        let mut key_releases = Vec::new();
        let key_deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < key_deadline && (key_presses.len(), key_releases.len()) != (2, 2) {
            while let Some(event) = client.poll_for_event().unwrap() {
                match event {
                    Event::KeyPress(e) if e.event == id => key_presses.push(e),
                    Event::KeyRelease(e) if e.event == id => key_releases.push(e),
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            (key_presses.len(), key_releases.len()),
            (2, 2),
            "ASCII uppercase input must deliver and release both shift and letter"
        );
        assert!(
            key_presses.iter().any(|event| {
                let mapping = client
                    .get_keyboard_mapping(event.detail, 1)
                    .unwrap()
                    .reply()
                    .unwrap();
                mapping.keysyms.contains(&u32::from(b'A'))
                    && event.state.contains(xproto::KeyButMask::SHIFT)
            }),
            "uppercase A never reached the client"
        );
        assert!(
            client
                .query_keymap()
                .unwrap()
                .reply()
                .unwrap()
                .keys
                .iter()
                .all(|byte| *byte == 0),
            "native typing left a key held"
        );
        // Managed Firefox shares this injector: Unicode remapping must be
        // reversible even when a sequence stops while its key is held.
        let min = client.setup().min_keycode;
        let count = client.setup().max_keycode - min + 1;
        let original = client
            .get_keyboard_mapping(min, count)
            .unwrap()
            .reply()
            .unwrap();
        let keyboard = |actions| json!({"actions":[{"actions":actions}]});
        desktop
            .perform(
                &window,
                &keyboard(json!([
                    {"type":"keyDown","value":"容"},
                    {"type":"keyUp","value":"容"},
                    {"type":"keyDown","value":"器"}
                ])),
                true,
            )
            .unwrap();
        assert!(!desktop.remapped_keys.is_empty());
        desktop.release_inputs().unwrap();
        let restored = client
            .get_keyboard_mapping(min, count)
            .unwrap()
            .reply()
            .unwrap();
        assert_eq!(restored.keysyms, original.keysyms);
        assert!(desktop.remapped_keys.is_empty());
        desktop
            .perform(
                &window,
                &keyboard(json!([
                    {"type":"keyDown","value":"\u{e008}"},
                    {"type":"keyDown","value":"A"},
                    {"type":"keyUp","value":"\u{e008}"}
                ])),
                false,
            )
            .unwrap();
        let shift = desktop.keycode(0xffe1).unwrap().0;
        assert!(
            desktop.held_keys.contains(&shift),
            "uppercase still owns implicit Shift"
        );
        desktop
            .perform(
                &window,
                &keyboard(json!([
                    {"type":"keyUp","value":"A"}
                ])),
                false,
            )
            .unwrap();
        assert!(desktop.held_keys.is_empty());
        assert!(desktop.logical_keys.is_empty());
        assert!(client
            .query_keymap()
            .unwrap()
            .reply()
            .unwrap()
            .keys
            .iter()
            .all(|n| *n == 0));
        // noVNC is another XTEST client on the same core devices. It must be
        // observed even while another client grabs the pointer during a drag.
        let grab = client
            .grab_pointer(
                false,
                id,
                xproto::EventMask::BUTTON_PRESS
                    | xproto::EventMask::BUTTON_RELEASE
                    | xproto::EventMask::POINTER_MOTION,
                xproto::GrabMode::ASYNC,
                xproto::GrabMode::ASYNC,
                x11rb::NONE,
                x11rb::NONE,
                x11rb::CURRENT_TIME,
            )
            .unwrap()
            .reply()
            .unwrap();
        assert_eq!(grab.status, xproto::GrabStatus::SUCCESS);
        client
            .xtest_fake_input(6, 0, 0, root, 200, 240, 0)
            .unwrap()
            .check()
            .unwrap();
        desktop
            .connection
            .get_input_focus()
            .unwrap()
            .reply()
            .unwrap();
        desktop
            .inject(6, 0, 200, 241)
            .expect("ordinary noVNC movement must not block Docker input");
        std::thread::sleep(Duration::from_millis(25));
        assert!(
            desktop
                .poll_events()
                .unwrap()
                .contains(&DesktopEvent::UserInteraction),
            "foreign XTEST/noVNC input was filtered"
        );
        client
            .ungrab_pointer(x11rb::CURRENT_TIME)
            .unwrap()
            .check()
            .unwrap();
        for (x, want) in [
            (20, DesktopEvent::Pause),
            (110, DesktopEvent::Resume),
            (190, DesktopEvent::Cancel),
        ] {
            client
                .xtest_fake_input(6, 0, 0, root, x, 18, 0)
                .unwrap()
                .check()
                .unwrap();
            client
                .xtest_fake_input(4, 1, 0, root, 0, 0, 0)
                .unwrap()
                .check()
                .unwrap();
            desktop
                .connection
                .get_input_focus()
                .unwrap()
                .reply()
                .unwrap();
            if matches!(want, DesktopEvent::Pause | DesktopEvent::Cancel) {
                assert_eq!(desktop.inject(6, 0, x, 18).unwrap_err().code, "USER_PAUSED");
            }
            let down_events = desktop.poll_events().unwrap();
            assert!(
                down_events.contains(&want),
                "visible toolbar action missing: {want:?}"
            );
            assert!(
                !down_events.contains(&DesktopEvent::UserInteraction),
                "toolbar press must express control intent, not trigger a second human-input pause"
            );
            // The release arrives in a later polling batch, matching a person
            // holding Resume briefly rather than an artificial atomic click.
            client
                .xtest_fake_input(5, 1, 0, root, 0, 0, 0)
                .unwrap()
                .check()
                .unwrap();
            desktop
                .connection
                .get_input_focus()
                .unwrap()
                .reply()
                .unwrap();
            assert!(
                !desktop
                    .poll_events()
                    .unwrap()
                    .contains(&DesktopEvent::UserInteraction),
                "toolbar release re-paused after control intent"
            );
            std::thread::sleep(Duration::from_millis(30));
            assert!(
                !desktop
                    .poll_events()
                    .unwrap()
                    .contains(&DesktopEvent::UserInteraction),
                "buffered toolbar events re-paused later"
            );
        }
        // A human moves across the application and clicks Resume within one
        // polling interval. Earlier activity must be delivered before Resume,
        // never as a delayed pause that defeats the explicit resume intent.
        client
            .xtest_fake_input(6, 0, 0, root, 200, 200, 0)
            .unwrap()
            .check()
            .unwrap();
        client
            .xtest_fake_input(6, 0, 0, root, 110, 18, 0)
            .unwrap()
            .check()
            .unwrap();
        client
            .xtest_fake_input(4, 1, 0, root, 0, 0, 0)
            .unwrap()
            .check()
            .unwrap();
        client
            .xtest_fake_input(5, 1, 0, root, 0, 0, 0)
            .unwrap()
            .check()
            .unwrap();
        desktop
            .connection
            .get_input_focus()
            .unwrap()
            .reply()
            .unwrap();
        let intent_events = desktop.poll_events().unwrap();
        assert_eq!(intent_events.last(), Some(&DesktopEvent::Resume));
        std::thread::sleep(Duration::from_millis(30));
        assert!(
            !desktop
                .poll_events()
                .unwrap()
                .contains(&DesktopEvent::UserInteraction),
            "pre-Resume motion was delivered after Resume"
        );
        client.destroy_window(id).unwrap().check().unwrap();
        assert!(desktop.window(id, window.pid).is_err());
    }
    #[test]
    fn native_input_requires_no_preexisting_held_key_button_or_modifier() {
        assert!(input_state_clear(0, &[0; 32]));
        assert!(!input_state_clear(1, &[0; 32]));
        assert!(!input_state_clear(1 << 8, &[0; 32]));
        let mut keys = [0; 32];
        keys[4] = 2;
        assert!(!input_state_clear(0, &keys));
    }
    #[test]
    fn native_cmd_shortcuts_never_change_to_control_semantics() {
        let w = window();
        for key in ["Cmd+L", "Cmd+A", "Cmd+R", "Cmd+T", "Cmd+W"] {
            let request = json!({"action":"press","windowId":17,"pid":51,"expectedBounds":w.bounds,"key":key});
            assert_eq!(
                validate_native(&w, &request).unwrap_err().code,
                "ACTION_UNSUPPORTED"
            );
        }
    }
}
