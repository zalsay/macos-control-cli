use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct TextResult {
    status: String,
    items: Vec<TextItem>,
    truncated: bool,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct TextItem {
    text: String,
    bbox: TextBox,
    center: TextPoint,
    confidence: f64,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct TextBox {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct TextPoint {
    x: u32,
    y: u32,
}

// OCR 是可选的截图附加信息；非法结果降级，不能污染坐标或阻止有效截图。
pub fn sanitize(value: &Value, width: u32, height: u32) -> Value {
    let Ok(result) = serde_json::from_value::<TextResult>(value.clone()) else {
        return unavailable();
    };
    let mut characters = 0;
    if !matches!(result.status.as_str(), "ok" | "unavailable")
        || result.items.len() > 128
        || (result.status == "unavailable" && (!result.items.is_empty() || result.truncated))
    {
        return unavailable();
    }
    for item in &result.items {
        let b = &item.bbox;
        let count = item.text.chars().count();
        characters += count;
        if count == 0
            || count > 256
            || characters > 8192
            || !item.confidence.is_finite()
            || !(0.0..=1.0).contains(&item.confidence)
            || b.width == 0
            || b.height == 0
            || b.x.checked_add(b.width).is_none_or(|right| right > width)
            || b.y
                .checked_add(b.height)
                .is_none_or(|bottom| bottom > height)
            || item.center.x != b.x.saturating_add(b.width / 2)
            || item.center.y != b.y.saturating_add(b.height / 2)
        {
            return unavailable();
        }
    }
    if serde_json::to_vec(&result).map_or(true, |bytes| bytes.len() > 48 * 1024) {
        return unavailable();
    }
    serde_json::to_value(result).unwrap_or_else(|_| unavailable())
}
fn unavailable() -> Value {
    json!({"status":"unavailable","items":[],"truncated":false})
}

#[cfg(test)]
mod tests {
    use super::*;
    fn valid() -> Value {
        json!({"status":"ok","items":[{"text":"上传视频","bbox":{"x":10,"y":20,"width":100,"height":40},"center":{"x":60,"y":40},"confidence":0.9}],"truncated":false})
    }
    #[test]
    fn given_text_when_validating_then_keep_same_frame_pixels_without_element_types() {
        assert_eq!(sanitize(&valid(), 800, 600), valid());
        assert!(sanitize(&valid(), 800, 600)["items"][0]
            .get("type")
            .is_none());
    }
    #[test]
    fn given_malformed_or_unbounded_ocr_when_validating_then_degrade_instead_of_failing_capture() {
        let mut cases = vec![
            Value::Null,
            json!({}),
            json!({"status":"ok","items":[],"truncated":"true"}),
        ];
        for (field, value) in [
            ("text", json!("")),
            ("text", json!("字".repeat(257))),
            ("confidence", json!(-1)),
            ("confidence", json!(2)),
            ("type", json!("button")),
        ] {
            let mut v = valid();
            v["items"][0][field] = value;
            cases.push(v);
        }
        for field in ["x", "y", "width", "height"] {
            let mut v = valid();
            v["items"][0]["bbox"][field] = json!(u32::MAX);
            cases.push(v);
        }
        let mut v = valid();
        v["items"][0]["center"]["x"] = json!(61);
        cases.push(v);
        let mut v = valid();
        v["status"] = json!("unavailable");
        cases.push(v);
        let mut v = valid();
        v["items"] = json!(vec![valid()["items"][0].clone(); 129]);
        cases.push(v);
        let mut item = valid()["items"][0].clone();
        item["text"] = json!("字".repeat(256));
        let mut v = valid();
        v["items"] = json!(vec![item; 33]);
        cases.push(v);
        for v in cases {
            assert_eq!(sanitize(&v, 800, 600), unavailable());
        }
    }
}
