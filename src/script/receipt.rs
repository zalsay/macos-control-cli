//! Typed, bounded progress cache. Input text, OCR, file paths and model keys are never retained.
use crate::protocol::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
fn invalid() -> Error {
    Error::invalid("脚本进度回执无效")
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Progress {
    #[serde(skip_serializing_if = "Option::is_none")]
    connection_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    frame_id: Option<String>,
    total_steps: usize,
    completed_steps: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    failed_step: Option<usize>,
    #[serde(default)]
    steps: Vec<Step>,
    #[serde(skip_serializing_if = "Option::is_none")]
    native_receipt: Option<NativeReceipt>,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Step {
    index: usize,
    action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    frame_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sent: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    eb: Option<bool>,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeReceipt {
    backend: String,
    dispatch_state: String,
    completed_steps: u64,
    input_state: String,
    effect_verified: bool,
}
/// Unknown payload fields are deliberately dropped; known fields must be well typed.
pub fn project_progress(value: &Value) -> Result<Value> {
    let p: Progress = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
    if !(1..=super::MAX_STEPS).contains(&p.total_steps)
        || p.completed_steps > p.total_steps
        || p.steps.len() != p.completed_steps
        || p.failed_step.is_some_and(|n| {
            n == 0 || n > p.total_steps || (p.completed_steps > 0 && n != p.completed_steps + 1)
        })
        || p.connection_id
            .as_ref()
            .is_some_and(|s| !crate::remote::protocol::valid_id(s))
        || p.frame_id
            .as_ref()
            .is_some_and(|s| !crate::remote::protocol::valid_id(s))
    {
        return Err(invalid());
    }
    for (i, s) in p.steps.iter().enumerate() {
        if s.index != i + 1
            || !matches!(
                s.action.as_str(),
                "observe"
                    | "click"
                    | "click-target"
                    | "scroll"
                    | "type"
                    | "press"
                    | "wait"
                    | "move"
                    | "hover"
                    | "drag"
                    | "actions"
            )
            || s.frame_id
                .as_ref()
                .is_some_and(|s| !crate::remote::protocol::valid_id(s))
        {
            return Err(invalid());
        }
    }
    if let Some(n) = &p.native_receipt {
        if !matches!(n.backend.as_str(), "x11" | "firefox-x11")
            || !matches!(
                n.dispatch_state.as_str(),
                "notSent" | "completed" | "partial" | "unknown"
            )
            || !matches!(n.input_state.as_str(), "released" | "held" | "unknown")
            || n.completed_steps > 8192
        {
            return Err(invalid());
        }
    }
    serde_json::to_value(p).map_err(|_| invalid())
}
