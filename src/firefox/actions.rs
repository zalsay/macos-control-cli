use super::motion;
use crate::protocol::{Error, Result};
use ring::rand::{SecureRandom, SystemRandom};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Debug)]
pub struct Segment {
    pub wire: Option<Value>,
    pub wait_ms: u64,
    pub completes_step: bool,
    pub pointer: Option<(i64, i64)>,
    pub motion: Option<MotionTiming>,
}

#[derive(Debug, Clone, Copy)]
pub struct MotionTiming {
    pub at_ms: u64,
    pub next_ms: Option<u64>,
}

impl Segment {
    /// Drop overdue intermediate samples instead of bursting through an old
    /// trajectory. Always keep the final point and adjust its remaining time.
    pub fn wire_at(&self, elapsed_ms: u64) -> Option<Value> {
        let mut wire = self.wire.clone()?;
        if let Some(timing) = self.motion {
            if timing.next_ms.is_some_and(|next| next <= elapsed_ms) {
                return None;
            }
            wire["actions"][0]["actions"][0]["duration"] =
                json!(timing.at_ms.saturating_sub(elapsed_ms).min(50));
        }
        Some(wire)
    }
}

#[derive(Clone, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
enum Step {
    #[serde(rename = "move")]
    Move {
        x: i64,
        y: i64,
        #[serde(
            rename = "durationMs",
            default,
            deserialize_with = "specified_duration"
        )]
        duration: Option<u64>,
    },
    #[serde(rename = "pause")]
    Pause {
        #[serde(rename = "durationMs")]
        duration: u64,
    },
    #[serde(rename = "pointerDown")]
    Down { button: Button },
    #[serde(rename = "pointerUp")]
    Up { button: Button },
    #[serde(rename = "keyDown")]
    KeyDown { key: String },
    #[serde(rename = "keyUp")]
    KeyUp { key: String },
    #[serde(rename = "scroll")]
    Scroll {
        x: i64,
        y: i64,
        #[serde(rename = "deltaY")]
        delta: i64,
    },
}
#[derive(Clone, Copy, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
enum Button {
    Left,
    Middle,
    Right,
}

fn specified_duration<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<u64>, D::Error> {
    u64::deserialize(deserializer).map(Some)
}
impl Button {
    fn number(self) -> u8 {
        match self {
            Self::Left => 0,
            Self::Middle => 1,
            Self::Right => 2,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Sequence {
    version: u32,
    steps: Vec<Step>,
}

fn number(value: &Value, key: &str) -> Result<i64> {
    value
        .get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| Error::invalid(&format!("{key} 必须为整数")))
}
fn coordinate(value: &Value, key: &str) -> Result<i64> {
    let n = value
        .get(key)
        .and_then(Value::as_f64)
        .ok_or_else(|| Error::invalid("缺少有效坐标"))?;
    if !n.is_finite() || n < 0.0 || n > i16::MAX as f64 {
        return Err(Error::invalid("坐标无效"));
    }
    Ok(n.round() as i64)
}
fn duration(value: &Value, default: u64) -> Result<u64> {
    let n = match value.get("durationMs") {
        None => default,
        Some(n) => n
            .as_u64()
            .ok_or_else(|| Error::invalid("durationMs 必须为非负整数"))?,
    };
    if n > 2000 {
        return Err(Error::invalid("durationMs 不能超过 2000"));
    }
    Ok(n)
}
pub fn key(value: &str) -> Result<String> {
    let key = match value {
        "Shift" | "shift" => "\u{e008}",
        "Control" | "control" | "ctrl" => "\u{e009}",
        "Alt" | "alt" => "\u{e00a}",
        "Meta" | "meta" | "super" => "\u{e03d}",
        "Enter" | "return" | "enter" => "\u{e007}",
        "Tab" | "tab" => "\u{e004}",
        "Escape" | "escape" | "esc" => "\u{e00c}",
        "Backspace" | "backspace" => "\u{e003}",
        "Delete" | "delete" => "\u{e017}",
        "ArrowLeft" | "left" => "\u{e012}",
        "ArrowUp" | "up" => "\u{e013}",
        "ArrowRight" | "right" => "\u{e014}",
        "ArrowDown" | "down" => "\u{e015}",
        "Home" | "home" => "\u{e011}",
        "End" | "end" => "\u{e010}",
        "PageUp" | "pageup" => "\u{e00e}",
        "PageDown" | "pagedown" => "\u{e00f}",
        "Space" | "space" => " ",
        _ if value.chars().count() == 1 && !value.chars().any(char::is_control) => value,
        _ => return Err(Error::invalid("按键不在受支持枚举或单字符范围内")),
    };
    Ok(key.into())
}
fn pointer(actions: Vec<Value>) -> Value {
    json!({"actions":[{"type":"pointer","id":"mcc-pointer","parameters":{"pointerType":"mouse"},"actions":actions}]})
}
fn keyboard(actions: Vec<Value>) -> Value {
    json!({"actions":[{"type":"key","id":"mcc-keyboard","actions":actions}]})
}
fn modifiers(value: &Value) -> Result<Vec<String>> {
    let Some(raw) = value.get("modifiers") else {
        return Ok(vec![]);
    };
    let raw = raw
        .as_str()
        .ok_or_else(|| Error::invalid("modifiers 必须为逗号分隔的修饰键"))?;
    let mut seen = HashSet::new();
    let mut out = vec![];
    for item in raw.split(',') {
        if !["shift", "control", "ctrl", "alt", "meta", "super"].contains(&item) {
            return Err(Error::invalid("修饰键无效"));
        }
        let k = key(item)?;
        if !seen.insert(k.clone()) {
            return Err(Error::invalid("修饰键重复"));
        }
        out.push(k);
    }
    Ok(out)
}

/// Validate the complete request before any protocol command can be sent.
pub fn compile(
    request: &Value,
    width: u32,
    height: u32,
    position: (i64, i64),
) -> Result<Vec<Segment>> {
    let mut bytes = [0; 16];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| Error::new("INPUT_FAILED", "无法生成鼠标轨迹变化参数"))?;
    let variation = |bytes: &[u8]| {
        let n = u64::from_le_bytes(bytes.try_into().unwrap()) >> 11;
        n as f64 / ((1_u64 << 53) - 1) as f64 * 2.0 - 1.0
    };
    compile_with_variation(
        request,
        width,
        height,
        position,
        variation(&bytes[..8]),
        variation(&bytes[8..]),
    )
}

fn compile_with_variation(
    request: &Value,
    width: u32,
    height: u32,
    mut position: (i64, i64),
    bend: f64,
    timing: f64,
) -> Result<Vec<Segment>> {
    let optional_duration = || {
        request
            .get("durationMs")
            .map(|_| duration(request, 0))
            .transpose()
    };
    let action = request["action"].as_str().unwrap_or("");
    let mut steps = vec![];
    match action {
        "actions" => {
            let seq: Sequence = serde_json::from_value(request["actions"].clone())
                .map_err(|_| Error::invalid("actions schema 无效或含未知字段"))?;
            if seq.version != 1 || seq.steps.is_empty() || seq.steps.len() > 256 {
                return Err(Error::invalid("actions 需要 version 1 与 1–256 个步骤"));
            }
            steps = seq.steps;
        }
        "move" | "hover" => {
            steps.push(Step::Move {
                x: number(request, "x")?,
                y: number(request, "y")?,
                duration: if action == "move" {
                    optional_duration()?
                } else {
                    None
                },
            });
            if action == "hover" {
                steps.push(Step::Pause {
                    duration: duration(request, 500)?,
                });
            }
        }
        "drag" => {
            steps.extend([
                Step::Move {
                    x: number(request, "fromX")?,
                    y: number(request, "fromY")?,
                    duration: None,
                },
                Step::Down {
                    button: Button::Left,
                },
                Step::Move {
                    x: number(request, "toX")?,
                    y: number(request, "toY")?,
                    duration: optional_duration()?,
                },
                Step::Up {
                    button: Button::Left,
                },
            ]);
        }
        "click" => {
            let mods = modifiers(request)?;
            for k in &mods {
                steps.push(Step::KeyDown { key: k.clone() });
            }
            steps.push(Step::Move {
                x: coordinate(request, "screenX")?,
                y: coordinate(request, "screenY")?,
                duration: None,
            });
            let button =
                serde_json::from_value(request.get("button").cloned().unwrap_or(json!("left")))
                    .map_err(|_| Error::invalid("button 必须为 left/middle/right"))?;
            let count = request
                .get("clickCount")
                .map_or(Ok(1), |_| number(request, "clickCount"))?;
            if ![1, 2].contains(&count) {
                return Err(Error::invalid("clickCount 只能为 1 或 2"));
            }
            for _ in 0..count {
                steps.push(Step::Down { button });
                steps.push(Step::Up { button });
            }
            for k in mods.iter().rev() {
                steps.push(Step::KeyUp { key: k.clone() });
            }
        }
        "scroll" => steps.push(Step::Scroll {
            x: coordinate(request, "screenX")?,
            y: coordinate(request, "screenY")?,
            delta: number(request, "deltaY")?,
        }),
        "press" => {
            let raw = request["key"]
                .as_str()
                .ok_or_else(|| Error::invalid("缺少 key"))?;
            let parts = raw.split('+').map(key).collect::<Result<Vec<_>>>()?;
            for k in &parts {
                steps.push(Step::KeyDown { key: k.clone() });
            }
            for k in parts.iter().rev() {
                steps.push(Step::KeyUp { key: k.clone() });
            }
        }
        "type" => {
            let text = request["text"]
                .as_str()
                .filter(|s| {
                    !s.is_empty() && s.chars().count() <= 4096 && !s.chars().any(char::is_control)
                })
                .ok_or_else(|| Error::invalid("text 必须为 1–4096 个非控制字符"))?;
            return Ok(text
                .chars()
                .map(|c| Segment {
                    wire: Some(keyboard(vec![
                        json!({"type":"keyDown","value":c.to_string()}),
                        json!({"type":"keyUp","value":c.to_string()}),
                    ])),
                    wait_ms: 0,
                    completes_step: true,
                    pointer: None,
                    motion: None,
                })
                .collect());
        }
        _ => return Err(Error::new("ACTION_UNSUPPORTED", "此 Firefox 动作尚未支持")),
    }
    let mut buttons = HashSet::new();
    let mut keys = HashSet::new();
    let mut total = 0_u64;
    for step in &steps {
        match step {
            Step::Move { x, y, duration } => {
                if *x < 0
                    || *y < 0
                    || *x >= width as i64
                    || *y >= height as i64
                    || duration.is_some_and(|d| d > 2000)
                {
                    return Err(Error::invalid("移动坐标或时长越界"));
                }
                total += duration.unwrap_or(0);
            }
            Step::Pause { duration } => {
                if *duration > 2000 {
                    return Err(Error::invalid("等待时长越界"));
                }
                total += duration;
            }
            Step::Down { button } => {
                if !buttons.insert(*button) {
                    return Err(Error::invalid("按钮重复按下"));
                }
            }
            Step::Up { button } => {
                if !buttons.remove(button) {
                    return Err(Error::invalid("按钮未按下"));
                }
            }
            Step::KeyDown { key: k } => {
                if !keys.insert(key(k)?) {
                    return Err(Error::invalid("按键重复按下"));
                }
            }
            Step::KeyUp { key: k } => {
                if !keys.remove(&key(k)?) {
                    return Err(Error::invalid("按键未按下"));
                }
            }
            Step::Scroll { x, y, delta } => {
                if *x < 0
                    || *y < 0
                    || *x >= width as i64
                    || *y >= height as i64
                    || *delta == 0
                    || !(-1200..=1200).contains(delta)
                {
                    return Err(Error::invalid("滚动坐标或距离越界"));
                }
            }
        }
        if total > 10_000 {
            return Err(Error::invalid("动作计划总时长不能超过 10 秒"));
        }
    }
    if !buttons.is_empty() || !keys.is_empty() {
        return Err(Error::invalid("动作结束时必须释放所有按键和按钮"));
    }
    let mut result = vec![];
    // DELETE /actions clears protocol input sources. A sequence may start
    // with a button rather than a move, so seed its last known position too.
    if steps
        .iter()
        .find(|step| {
            matches!(
                step,
                Step::Move { .. } | Step::Down { .. } | Step::Up { .. }
            )
        })
        .is_some_and(|step| !matches!(step, Step::Move { .. }))
    {
        if position.0 < 0
            || position.1 < 0
            || position.0 >= width as i64
            || position.1 >= height as i64
        {
            return Err(Error::new(
                "INPUT_FAILED",
                "已记录的浏览器指针位置不在视口内",
            ));
        }
        result.push(Segment {
            wire: Some(pointer(vec![
                json!({"type":"pointerMove","origin":"viewport",
                "x":position.0,"y":position.1,"duration":0}),
            ])),
            wait_ms: 0,
            completes_step: false,
            pointer: Some(position),
            motion: None,
        });
    }
    let mut planned_ms = 0;
    for step in steps {
        match step {
            Step::Move { x, y, duration } => {
                let samples = motion::plan(position, (x, y), width, height, duration, bend, timing)?;
                planned_ms += samples.last().unwrap().at_ms;
                let mut previous = 0;
                for (i, sample) in samples.iter().enumerate() {
                    result.push(Segment {
                        wire: Some(pointer(vec![json!({"type":"pointerMove","origin":"viewport",
                            "x":sample.point.0,"y":sample.point.1,"duration":sample.at_ms-previous})])),
                        wait_ms: 0,
                        completes_step: i + 1 == samples.len(),
                        pointer: Some(sample.point),
                        motion: Some(MotionTiming { at_ms: sample.at_ms,
                            next_ms: samples.get(i+1).map(|s| s.at_ms) }),
                    });
                    previous = sample.at_ms;
                }
                position = (x, y);
            }
            Step::Pause { duration } => {
                planned_ms += duration;
                let mut left = duration;
                loop {
                    let wait = left.min(50);
                    left -= wait;
                    result.push(Segment { wire: None, wait_ms: wait, completes_step: left == 0,
                        pointer: None, motion: None });
                    if left == 0 { break; }
                }
            }
            Step::Down { button } | Step::Up { button } => result.push(Segment {
                wire: Some(pointer(vec![json!({"type":if matches!(step,Step::Down{..}){"pointerDown"}else{"pointerUp"},"button":button.number()})])),
                wait_ms: 0, completes_step: true, pointer: None, motion: None,
            }),
            Step::KeyDown { ref key } | Step::KeyUp { ref key } => result.push(Segment {
                wire: Some(keyboard(vec![json!({"type":if matches!(step,Step::KeyDown{..}){"keyDown"}else{"keyUp"},"value":self::key(key)?})])),
                wait_ms: 0, completes_step: true, pointer: None, motion: None,
            }),
            Step::Scroll { x, y, delta } => result.push(Segment {
                wire: Some(json!({"actions":[{"type":"wheel","id":"mcc-wheel","actions":[{"type":"scroll","origin":"viewport","x":x,"y":y,"deltaX":0,"deltaY":delta,"duration":0}]}]})),
                wait_ms: 0, completes_step: true, pointer: None, motion: None,
            }),
        }
        if planned_ms > 10_000 {
            return Err(Error::invalid("动作计划总时长（含自动移动）不能超过 10 秒"));
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn validates_entire_sequence_before_compiling_and_rejects_unbalanced_input() {
        for steps in [
            json!([{"type":"pointerDown","button":"left"}]),
            json!([{"type":"keyUp","key":"Shift"}]),
            json!([{"type":"move","x":800,"y":0,"durationMs":200}]),
            json!([{"type":"move","x":1,"y":2,"durationMs":200,"script":"bad"}]),
        ] {
            assert!(compile(
                &json!({"action":"actions","actions":{"version":1,"steps":steps}}),
                800,
                600,
                (0, 0)
            )
            .is_err());
        }
    }

    #[test]
    fn continuous_drag_is_split_into_bounded_fragments_with_balanced_buttons() {
        let segments = compile(
            &json!({"action":"drag","fromX":10,"fromY":20,"toX":110,"toY":120,"durationMs":120}),
            800,
            600,
            (0, 0),
        )
        .unwrap();
        let wire: Vec<_> = segments.iter().filter_map(|s| s.wire.as_ref()).collect();
        let moves: Vec<_> = wire
            .iter()
            .flat_map(|w| w["actions"][0]["actions"].as_array().unwrap())
            .filter(|a| a["type"] == "pointerMove")
            .collect();
        assert!(moves.iter().all(|a| a["duration"].as_u64().unwrap() <= 50));
        assert_eq!(moves.last().unwrap()["x"], 110);
        assert_eq!(moves.last().unwrap()["y"], 120);
        let all = serde_json::to_string(&wire).unwrap();
        assert!(all.contains("pointerDown"));
        assert!(all.contains("pointerUp"));
        assert!(!all.contains("script"));
    }

    fn moves(segments: &[Segment]) -> Vec<Value> {
        segments
            .iter()
            .filter_map(|s| s.wire.as_ref())
            .flat_map(|w| w["actions"][0]["actions"].as_array().unwrap().clone())
            .filter(|a| a["type"] == "pointerMove")
            .collect()
    }

    #[test]
    fn click_travels_from_known_pointer_before_pressing_and_double_click_moves_once() {
        let request = json!({"action":"click","screenX":1000,"screenY":600,"clickCount":2});
        let segments = compile(&request, 1200, 800, (100, 100)).unwrap();
        let points = moves(&segments);
        assert!(
            points.len() > 8,
            "click must travel through intermediate points"
        );
        assert_eq!(
            (points[0]["x"].as_i64(), points[0]["y"].as_i64()),
            (Some(100), Some(100)),
            "seed the pointer source after Release Actions resets protocol input state"
        );
        assert_eq!(points.last().unwrap()["x"], 1000);
        assert_eq!(points.last().unwrap()["y"], 600);
        let travel: u64 = points.iter().map(|a| a["duration"].as_u64().unwrap()).sum();
        assert!((150..=700).contains(&travel));
        let first_down = segments
            .iter()
            .position(|s| {
                s.wire
                    .as_ref()
                    .is_some_and(|w| w["actions"][0]["actions"][0]["type"] == "pointerDown")
            })
            .unwrap();
        assert_eq!(moves(&segments[..first_down]).len(), points.len());
        assert_eq!(
            segments.iter().filter(|s| s.completes_step).count(),
            5,
            "one travel plus two down/up pairs"
        );
    }

    #[test]
    fn move_eases_in_and_out_and_honors_explicit_duration() {
        let segments = compile(
            &json!({"action":"move","x":1000,"y":100,"durationMs":600}),
            1200,
            800,
            (100, 100),
        )
        .unwrap();
        let points = moves(&segments);
        assert_eq!(points[0]["x"], 100, "include the actual motion start");
        assert!(points.len() >= 30, "sample near 60Hz");
        let deltas: Vec<i64> = points
            .windows(2)
            .map(|p| p[1]["x"].as_i64().unwrap() - p[0]["x"].as_i64().unwrap())
            .collect();
        assert!(
            deltas[0] < deltas[deltas.len() / 2]
                && deltas[deltas.len() - 1] < deltas[deltas.len() / 2]
        );
        assert_eq!(
            points
                .iter()
                .map(|a| a["duration"].as_u64().unwrap())
                .sum::<u64>(),
            600
        );
        assert!(points.iter().all(|a| a["duration"].as_u64().unwrap() <= 50));
    }

    #[test]
    fn hover_approaches_before_dwell_and_drag_approaches_before_holding() {
        let hover = compile(
            &json!({"action":"hover","x":1000,"y":600,"durationMs":100}),
            1200,
            800,
            (100, 100),
        )
        .unwrap();
        assert!(moves(&hover).len() > 8);
        assert_eq!(
            hover.iter().map(|s| s.wait_ms).sum::<u64>(),
            100,
            "hover duration remains dwell time"
        );
        let drag = compile(
            &json!({"action":"drag","fromX":500,"fromY":300,"toX":1000,"toY":600,"durationMs":600}),
            1200,
            800,
            (100, 100),
        )
        .unwrap();
        let down = drag
            .iter()
            .position(|s| {
                s.wire
                    .as_ref()
                    .is_some_and(|w| w["actions"][0]["actions"][0]["type"] == "pointerDown")
            })
            .unwrap();
        assert!(
            moves(&drag[..down]).len() > 8,
            "approach with the button released"
        );
        assert_eq!(moves(&drag[..down]).last().unwrap()["x"], 500);
        assert_eq!(
            moves(&drag[down..])
                .iter()
                .map(|a| a["duration"].as_u64().unwrap())
                .sum::<u64>(),
            600
        );
    }

    #[test]
    fn actions_restore_pointer_before_a_leading_button_without_counting_a_fake_step() {
        let segments = compile(
            &json!({"action":"actions","actions":{"version":1,"steps":[
                {"type":"pointerDown","button":"left"},
                {"type":"move","x":1000,"y":600,"durationMs":600},
                {"type":"pointerUp","button":"left"}
            ]}}),
            1200,
            800,
            (100, 100),
        )
        .unwrap();
        assert_eq!(segments[0].pointer, Some((100, 100)));
        assert!(!segments[0].completes_step);
        assert_eq!(segments.iter().filter(|s| s.completes_step).count(), 3);
    }

    #[test]
    fn explicit_null_duration_is_rejected_and_automatic_travel_counts_toward_budget() {
        assert!(compile(
            &json!({"action":"actions","actions":{"version":1,"steps":[
                {"type":"move","x":100,"y":100,"durationMs":null}
            ]}}),
            1200,
            800,
            (0, 0)
        )
        .is_err());
        let steps: Vec<_> = (0..30)
            .map(|i| {
                json!({"type":"move",
            "x":if i%2==0 {1100} else {100}, "y":if i%2==0 {600} else {100}})
            })
            .collect();
        assert!(compile(
            &json!({"action":"actions","actions":{"version":1,"steps":steps}}),
            1200,
            800,
            (100, 100)
        )
        .is_err());
    }

    #[test]
    fn late_samples_are_skipped_but_endpoint_is_always_emitted_without_replay() {
        let segments = compile_with_variation(
            &json!({"action":"move","x":1000,"y":600,"durationMs":600}),
            1200,
            800,
            (100, 100),
            0.7,
            0.0,
        )
        .unwrap();
        assert!(segments[1].wire_at(100).is_none());
        let last = segments.last().unwrap();
        let wire = last.wire_at(900).unwrap();
        assert_eq!(wire["actions"][0]["actions"][0]["x"], 1000);
        assert_eq!(wire["actions"][0]["actions"][0]["duration"], 0);
        assert_eq!(
            segments[1].wire_at(10).unwrap()["actions"][0]["actions"][0]["duration"],
            6
        );
        let mut elapsed = 0;
        let emitted: Vec<_> = segments
            .iter()
            .filter_map(|s| {
                let wire = s.wire_at(elapsed)?;
                elapsed += 80;
                Some(wire)
            })
            .collect();
        assert!(emitted.len() < segments.len());
        assert_eq!(
            emitted.last().unwrap()["actions"][0]["actions"][0]["x"],
            1000
        );
    }

    #[test]
    fn right_click_with_shift_uses_keyboard_and_pointer_actions() {
        let segments = compile(&json!({"action":"click","screenX":12,"screenY":34,"button":"right","modifiers":"shift","clickCount":1}),800,600,(0,0)).unwrap();
        let encoded = serde_json::to_string(
            &segments
                .iter()
                .filter_map(|s| s.wire.as_ref())
                .collect::<Vec<_>>(),
        )
        .unwrap();
        assert!(encoded.contains("keyDown"));
        assert!(encoded.contains("keyUp"));
        assert!(encoded.contains("\"button\":2"));
    }
}
