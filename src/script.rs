//! Bounded JSON scripts composed of existing MCC operations. Never invokes a shell.
mod receipt;
use crate::protocol::{fields, integer, string, Error, Result, Scope};
pub use receipt::project_progress;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::Read, path::Path, time::Duration};

pub const MAX_BYTES: usize = 32 * 1024;
pub const MAX_STEPS: usize = 64;
pub const CAPABILITY: &str = "remote.script.v1";
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Plan {
    version: u32,
    pub steps: Vec<Value>,
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,
}
fn default_timeout() -> u64 {
    40000
}
impl Plan {
    pub fn parse(value: &Value, scope: Scope, initial_frame: bool) -> Result<Self> {
        if serde_json::to_vec(value)
            .map_err(|_| Error::invalid("脚本不是有效 JSON"))?
            .len()
            > MAX_BYTES
        {
            return Err(Error::new("MESSAGE_TOO_LARGE", "脚本最多 32KiB"));
        }
        let plan: Self = serde_json::from_value(value.clone())
            .map_err(|_| Error::invalid("脚本需要 version、steps 和可选 timeoutMs"))?;
        if plan.version != 1
            || plan.steps.is_empty()
            || plan.steps.len() > MAX_STEPS
            || !(1..=40000).contains(&plan.timeout_ms)
        {
            return Err(Error::invalid(
                "脚本 version 必须为 1，1–64 步，timeoutMs 为 1–40000",
            ));
        }
        let mut has_frame = initial_frame;
        let mut wait_ms = 0;
        for (i, step) in plan.steps.iter().enumerate() {
            let checked = (|| {
                let action = string(step, "action")?;
                if action == "wait" {
                    fields(step, &["action", "ms"])?;
                    let ms = integer(step, "ms")?;
                    if !(0..=10000).contains(&ms) {
                        return Err(Error::invalid("wait ms 必须为 0–10000"));
                    }
                    wait_ms += ms;
                    if wait_ms > 10000 {
                        return Err(Error::invalid("脚本等待总时长不能超过 10000ms"));
                    }
                    return Ok(());
                }
                if !matches!(
                    action,
                    "observe"
                        | "click"
                        | "click-target"
                        | "type"
                        | "press"
                        | "scroll"
                        | "move"
                        | "hover"
                        | "drag"
                        | "actions"
                ) || step.get("connectionId").is_some()
                    || step.get("frameId").is_some()
                {
                    return Err(Error::invalid(
                        "脚本只支持观察和输入步骤；连接和帧由外层继承",
                    ));
                }
                let mut request = step.clone();
                request["connectionId"] = json!("script-connection");
                if !matches!(action, "observe" | "click-target") {
                    if !has_frame {
                        return Err(Error::invalid("输入前需要 observe 或外层 --frame"));
                    }
                    request["frameId"] = json!("script-frame");
                }
                crate::remote::protocol::validate_action(scope, &request)?;
                validate_input(&request)?;
                if matches!(action, "observe" | "click-target") {
                    has_frame = true;
                }
                Ok(())
            })();
            checked.map_err(|error: Error| {
                error.with_receipt(
                    json!({"completedSteps":0,"totalSteps":plan.steps.len(),"failedStep":i+1}),
                )
            })?;
        }
        Ok(plan)
    }
    pub fn timeout(&self) -> Duration {
        Duration::from_millis(self.timeout_ms)
    }
    pub fn needs_model(&self) -> bool {
        self.steps.iter().any(|s| s["action"] == "click-target")
    }
}

// Static input preflight supplements the existing wire validator; live bounds,
// backend-specific keys, focus and BLE packet preflight still use existing executors.
fn validate_input(request: &Value) -> Result<()> {
    for name in ["x", "y", "fromX", "fromY", "toX", "toY"] {
        if request
            .get(name)
            .is_some_and(|v| v.as_i64().is_none_or(|n| n < 0))
        {
            return Err(Error::invalid("脚本坐标必须为非负整数"));
        }
    }
    match request["action"].as_str() {
        Some("click") => {
            let count = request.get("clickCount").map_or(Some(1), Value::as_i64);
            if !matches!(count, Some(1 | 2)) || (request["eb"] == true && count != Some(1)) {
                return Err(Error::invalid("clickCount 必须为 1/2；ESP 只支持单击"));
            }
        }
        Some("scroll") => {
            let delta = integer(request, "deltaY")?;
            if delta == 0 || !(-1200..=1200).contains(&delta) {
                return Err(Error::invalid("deltaY 必须为 [-1200,1200] 内的非零整数"));
            }
        }
        Some("type") => {
            let text = string(request, "text")?;
            if text.chars().count() > 4096
                || text.chars().any(char::is_control)
                || (request["eb"] == true && !text.is_ascii())
            {
                return Err(Error::invalid(
                    "脚本文本须为 1–4096 个非控制字符；ESP 仅支持 ASCII",
                ));
            }
        }
        Some("press") if !crate::service::KEYS.contains(&string(request, "key")?) => {
            crate::firefox::actions::compile(request, 1600, 1600, (0, 0))?;
        }
        Some("click-target") => crate::target::validate_target(string(request, "target")?)?,
        _ => {}
    }
    Ok(())
}
pub fn validate_request(scope: Scope, request: &Value) -> Result<Plan> {
    fields(request, &["action", "connectionId", "frameId", "script"])?;
    for name in ["connectionId", "frameId"] {
        if name == "connectionId" || request.get(name).is_some() {
            if !crate::remote::protocol::valid_id(string(request, name)?) {
                return Err(Error::invalid("脚本连接或帧标识无效"));
            }
        }
    }
    Plan::parse(&request["script"], scope, request.get("frameId").is_some())
}
pub fn load(path: &Path) -> Result<Value> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(|e| Error::io("无法读取脚本文件", e))?
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| Error::io("无法读取脚本文件", e))?;
    if bytes.len() > MAX_BYTES {
        return Err(Error::new("MESSAGE_TOO_LARGE", "脚本最多 32KiB"));
    }
    serde_json::from_slice(&bytes).map_err(|_| Error::invalid("脚本文件必须为 JSON 对象"))
}
