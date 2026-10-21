use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fmt;
use std::io::{BufRead, Read};

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    #[default]
    Chrome,
    Desktop,
}
impl Scope {
    pub fn name(self) -> &'static str {
        match self {
            Self::Chrome => "chrome",
            Self::Desktop => "desktop",
        }
    }
}
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub(crate) const USER_PAUSED_PUBLIC_MESSAGE: &str =
    "桌面输入已暂停，请点击屏幕上方控制条的继续按钮并等待 3 秒倒计时；暂停不会自动恢复，也不会重放旧输入";
pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Error {
    pub code: String,
    pub message: String,
}
impl Error {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
    pub fn invalid(message: &str) -> Self {
        Self::new("INVALID_ARGUMENT", message)
    }
    pub fn io(context: &str, error: std::io::Error) -> Self {
        Self::new("IO_ERROR", &format!("{context}: {error}"))
    }
}
impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for Error {}

pub fn response(result: Result<Value>) -> Value {
    response_for(result, Scope::Chrome)
}

pub fn response_for(result: Result<Value>, scope: Scope) -> Value {
    let mut value = match result {
        Ok(Value::Object(mut data)) => {
            data.insert("protocolVersion".into(), json!(PROTOCOL_VERSION));
            data.insert("ok".into(), json!(true));
            Value::Object(data)
        }
        Ok(_) => response(Err(Error::new("PROTOCOL_ERROR", "响应必须是 JSON 对象"))),
        Err(error) if error.code == "USER_PAUSED" => json!({
            "protocolVersion":PROTOCOL_VERSION,
            "ok":false,
            "error":{
                "code":"FOCUS_LOST",
                "reason":"USER_PAUSED",
                "message":USER_PAUSED_PUBLIC_MESSAGE
            }
        }),
        Err(error) => json!({"protocolVersion":PROTOCOL_VERSION,"ok":false,"error":error}),
    };
    if scope == Scope::Desktop {
        value["scope"] = json!(scope.name());
    }
    value
}

pub fn random_id() -> Result<String> {
    let mut bytes = [0_u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| Error::io("无法读取系统随机源", error))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// 协议行有限长，不能先无界 read_line 再检查长度。
pub fn read_message(reader: &mut impl BufRead) -> Result<Option<Value>> {
    let mut line = Vec::new();
    loop {
        let buffer = reader
            .fill_buf()
            .map_err(|e| Error::io("读取协议失败", e))?;
        if buffer.is_empty() {
            return if line.is_empty() {
                Ok(None)
            } else {
                Err(Error::new("PROTOCOL_ERROR", "协议行缺少换行符"))
            };
        }
        let end = buffer.iter().position(|byte| *byte == b'\n');
        let count = end.map_or(buffer.len(), |index| index + 1);
        if line.len() + count > MAX_MESSAGE_BYTES {
            return Err(Error::new("MESSAGE_TOO_LARGE", "协议消息超过 64KiB"));
        }
        line.extend_from_slice(&buffer[..count]);
        reader.consume(count);
        if end.is_some() {
            return serde_json::from_slice(&line)
                .map(Some)
                .map_err(|_| Error::new("PROTOCOL_ERROR", "协议消息不是有效 JSON"));
        }
    }
}

pub fn string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::invalid(&format!("缺少有效的 {key}")))
}
pub fn integer(value: &Value, key: &str) -> Result<i64> {
    value
        .get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| Error::invalid(&format!("{key} 必须为整数")))
}
pub fn fields(value: &Value, allowed: &[&str]) -> Result<()> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::invalid("请求必须为对象"))?;
    if object.keys().any(|name| !allowed.contains(&name.as_str())) {
        return Err(Error::invalid("请求包含未支持的字段"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_user_paused_copy_semantics(message: &str) {
        assert!(message.contains("已暂停"), "应明确显示暂停状态");
        assert!(message.contains("继续按钮"), "应指导用户点击继续");
        assert!(message.contains("3 秒倒计时"), "应说明恢复前等待三秒");
        assert!(message.contains("不会自动恢复"), "暂停不能自动恢复");
        assert!(message.contains("不会重放旧输入"), "不能重放旧输入");
    }

    #[test]
    fn given_user_paused_when_serialized_then_emit_legacy_focus_code_and_reason() {
        let value = response(Err(Error::new("USER_PAUSED", "raw helper detail")));

        assert_eq!(value["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "FOCUS_LOST");
        assert_eq!(value["error"]["reason"], "USER_PAUSED");
        let message = value["error"]["message"].as_str().unwrap();
        assert_user_paused_copy_semantics(message);
        assert!(!value.to_string().contains("raw helper detail"));
    }

    #[test]
    fn given_plain_focus_lost_with_paused_copy_when_serialized_then_do_not_infer_reason_from_message(
    ) {
        let value = response(Err(Error::new("FOCUS_LOST", USER_PAUSED_PUBLIC_MESSAGE)));
        assert_eq!(value["error"]["code"], "FOCUS_LOST");
        assert!(value["error"].get("reason").is_none());
    }

    #[test]
    fn given_chrome_response_when_serialized_then_keep_legacy_envelope_without_scope() {
        let value = response_for(Ok(json!({"running":true})), Scope::Chrome);
        assert!(value.get("scope").is_none());
        let desktop = response_for(Ok(json!({"running":true})), Scope::Desktop);
        assert_eq!(desktop["scope"], "desktop");
    }

    #[test]
    fn given_other_error_when_serialized_then_keep_code_without_reason() {
        let value = response(Err(Error::new("INVALID_ARGUMENT", "bad argument")));
        assert_eq!(value["error"]["code"], "INVALID_ARGUMENT");
        assert!(value["error"].get("reason").is_none());
    }

    #[test]
    fn oversized_or_unterminated_protocol_is_rejected() {
        assert_eq!(
            read_message(&mut std::io::Cursor::new(vec![b' '; MAX_MESSAGE_BYTES + 1]))
                .unwrap_err()
                .code,
            "MESSAGE_TOO_LARGE"
        );
        assert!(read_message(&mut std::io::Cursor::new(b"{}")).is_err());
        assert_eq!(
            read_message(&mut std::io::Cursor::new(b"{}\n")).unwrap(),
            Some(json!({}))
        );
    }
}
