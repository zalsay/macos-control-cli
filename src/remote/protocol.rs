//! Pure remote message validation. Authentication and TLS are the Host's responsibility.
use crate::protocol::{fields, Error, Result, Scope, MAX_MESSAGE_BYTES};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

pub const REMOTE_PROTOCOL: u32 = 1;
pub const SUBPROTOCOL: &str = "mcc.remote.v1";
pub const PATH: &str = "/mcc/v1";
const MAX_ID: usize = 128;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteEnvelope {
    pub remote_protocol: u32,
    pub id: String,
    pub session: String,
    pub sequence: u64,
    pub scope: Scope,
    pub request: Value,
}
impl fmt::Debug for RemoteEnvelope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteEnvelope")
            .field("remote_protocol", &self.remote_protocol)
            .field("id", &self.id)
            .field("session", &"[REDACTED]")
            .field("sequence", &self.sequence)
            .field("scope", &self.scope)
            .field("request", &"[REDACTED]")
            .finish()
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Hello {
    pub remote_protocol: u32,
    pub version: String,
    pub scope: Scope,
    pub boot_id: String,
    pub capabilities: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageManifest {
    pub request_id: String,
    pub frame_id: String,
    pub mime: String,
    pub bytes: u64,
    pub sha256: String,
}
impl ImageManifest {
    pub fn validate(&self) -> Result<()> {
        if !valid_id(&self.request_id)
            || !valid_id(&self.frame_id)
            || self.mime != "image/jpeg"
            || self.bytes == 0
            || self.bytes >= 1024 * 1024
            || self.sha256.len() != 64
            || !self.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(Error::invalid("图片 manifest 无效"));
        }
        Ok(())
    }
}
/// Host must call after TLS and token authentication, and independently enforce handshake limits.
pub fn validate_handshake(path: &str, subprotocol: &str, origin: Option<&str>) -> Result<()> {
    if path != PATH || subprotocol != SUBPROTOCOL || origin.is_some() {
        return Err(Error::new("PROTOCOL_ERROR", "不支持的远程握手"));
    }
    Ok(())
}
pub(crate) fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
}
pub fn parse_envelope(bytes: &[u8]) -> Result<RemoteEnvelope> {
    parse_envelope_with_files(bytes, false)
}
/// Host passes `allow_files` from its local roots configuration, never from the peer.
pub fn parse_envelope_with_files(bytes: &[u8], allow_files: bool) -> Result<RemoteEnvelope> {
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(Error::new("MESSAGE_TOO_LARGE", "远程消息超过 64KiB"));
    }
    let envelope: RemoteEnvelope =
        serde_json::from_slice(bytes).map_err(|_| Error::new("PROTOCOL_ERROR", "远程消息无效"))?;
    if envelope.remote_protocol != REMOTE_PROTOCOL
        || envelope.sequence == 0
        || !valid_id(&envelope.id)
        || !valid_id(&envelope.session)
    {
        return Err(Error::invalid("远程信封字段无效"));
    }
    validate_action_with_files(envelope.scope, &envelope.request, allow_files)?;
    Ok(envelope)
}
/// Only user-supplied fields are accepted. Service retains its own validation.
pub fn validate_action(scope: Scope, request: &Value) -> Result<()> {
    validate_action_with_files(scope, request, false)
}
/// `allow_files` checks syntax only; Host must separately enforce its local allowed roots.
pub fn validate_action_with_files(scope: Scope, request: &Value, allow_files: bool) -> Result<()> {
    let action = request
        .get("action")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::invalid("缺少命令"))?;
    let allowed: &[&str] = match action {
        "status" | "apps" | "session" => &["action"],
        "windows" => &["action", "bundleId"],
        "permissions" => &["action", "request"],
        "chrome-start" => &["action", "url", "profile"],
        "connect" => &["action", "windowId"],
        "observe" | "disconnect" => &["action", "connectionId"],
        "click" => &["action", "connectionId", "frameId", "x", "y", "clickCount"],
        "click-target" => &["action", "connectionId", "target"],
        "scroll" => &["action", "connectionId", "frameId", "x", "y", "deltaY"],
        "type" => &["action", "connectionId", "frameId", "text"],
        "press" => &["action", "connectionId", "frameId", "key"],
        "frame" => &["action", "connectionId", "frameId"],
        "select-file" if allow_files => &["action", "connectionId", "path"],
        _ => return Err(Error::invalid("不支持的远程命令")),
    };
    fields(request, allowed)?;
    if (action == "apps" && scope != Scope::Desktop)
        || (action == "windows" && scope != Scope::Desktop && request.get("bundleId").is_some())
    {
        return Err(Error::invalid("scope 不允许此命令"));
    }
    if action == "permissions"
        && request
            .get("request")
            .is_some_and(|v| v != &Value::Bool(false))
    {
        return Err(Error::invalid("远程权限申请不允许"));
    }
    for name in ["connectionId", "frameId"] {
        if let Some(value) = request.get(name) {
            if !value.as_str().is_some_and(valid_id) {
                return Err(Error::invalid("标识符无效"));
            }
        }
    }
    let required: &[&str] = match action {
        "connect" => &["windowId"],
        "observe" | "disconnect" => &["connectionId"],
        "click-target" => &["connectionId", "target"],
        "select-file" => &["connectionId", "path"],
        "click" => &["connectionId", "frameId", "x", "y"],
        "scroll" => &["connectionId", "frameId", "x", "y", "deltaY"],
        "type" => &["connectionId", "frameId", "text"],
        "press" => &["connectionId", "frameId", "key"],
        "frame" => &["connectionId", "frameId"],
        _ => &[],
    };
    for key in required {
        if request.get(*key).is_none() {
            return Err(Error::invalid("缺少必要字段"));
        }
    }
    for key in ["windowId", "x", "y", "clickCount", "deltaY"] {
        if request.get(key).is_some_and(|v| !v.is_i64()) {
            return Err(Error::invalid("数字字段无效"));
        }
    }
    for key in ["target", "text", "key", "bundleId", "url", "profile"] {
        if request
            .get(key)
            .is_some_and(|v| !v.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 8192))
        {
            return Err(Error::invalid("字符串字段无效"));
        }
    }
    if action == "select-file" {
        let path = request
            .get("path")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::invalid("文件路径无效"))?;
        if path.len() > 4096
            || path.is_empty()
            || path.chars().any(char::is_control)
            || !std::path::Path::new(path).is_absolute()
        {
            return Err(Error::invalid("文件路径必须为有效绝对路径"));
        }
    }
    Ok(())
}
