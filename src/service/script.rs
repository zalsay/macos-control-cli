use super::*;
use std::time::{Duration, Instant};

impl<N: Native> Service<N> {
    pub(super) fn execute_script(&mut self, request: &Value) -> Result<Value> {
        let plan = crate::script::Plan::parse(
            &request["script"],
            self.scope,
            request.get("frameId").is_some(),
        )?;
        let connection = string(request, "connectionId")?;
        let connected = self.require_connection(connection)?;
        if connected.release_pending {
            return Err(Error::new("USER_PAUSED", USER_PAUSED_PUBLIC_MESSAGE));
        }
        if let Some(frame) = request.get("frameId") {
            if !connected
                .frames
                .iter()
                .any(|f| Some(f.id.as_str()) == frame.as_str())
            {
                return Err(Error::new("FRAME_UNKNOWN", "脚本初始帧不属于本连接"));
            }
        }
        // Reject statically unsupported backend choices before earlier steps run.
        for (i, step) in plan.steps.iter().enumerate() {
            let unsupported_ble =
                step["eb"] == true && (cfg!(target_os = "linux") || connected.firefox);
            let extended = matches!(
                step["action"].as_str(),
                Some("move" | "hover" | "drag" | "actions")
            ) || step.get("button").is_some()
                || step.get("modifiers").is_some();
            if unsupported_ble || (extended && !connected.firefox) {
                return Err(Error::new(if unsupported_ble {"BLE_UNSUPPORTED"} else {"ACTION_UNSUPPORTED"},"当前连接不支持此脚本步骤")
                    .with_receipt(json!({"connectionId":connection,"completedSteps":0,"totalSteps":plan.steps.len(),"failedStep":i+1,"steps":[]})));
            }
            if step["action"] == "press" && connected.firefox {
                crate::firefox::actions::compile(step, 1600, 1600, (0, 0)).map_err(|error| error.with_receipt(json!({"connectionId":connection,"completedSteps":0,"totalSteps":plan.steps.len(),"failedStep":i+1,"steps":[]})))?;
            }
            // Preserve the backend's original key contract for all steps, even
            // when a bad key occurs after otherwise valid inputs.
            if step["action"] == "press"
                && !connected.firefox
                && !KEYS.contains(&string(step, "key")?)
            {
                return Err(Error::invalid("按键不在当前后端允许范围内").with_receipt(json!({"connectionId":connection,"completedSteps":0,"totalSteps":plan.steps.len(),"failedStep":i+1,"steps":[]})));
            }
        }
        let deadline = Instant::now() + plan.timeout();
        self.native.set_request_deadline(Some(deadline));
        let result = self.run_script(request, &plan, deadline);
        self.native.set_request_deadline(None);
        if self.operation_owner.is_none() {
            self.native.set_input_epoch(None);
        }
        result
    }

    fn script_guard(&mut self, deadline: Instant, epoch: &mut Option<u64>) -> Result<()> {
        self.check_operation_cancelled()?;
        if Instant::now() >= deadline {
            return Err(Error::new(
                "SCRIPT_TIMEOUT",
                "脚本已达到执行时限，后续步骤未执行",
            ));
        }
        let state = self.native.request(json!({"action":"transport-state"}))?;
        let current = state["inputEpoch"].as_u64().ok_or_else(|| {
            Error::new(
                "HELPER_UPGRADE_REQUIRED",
                "脚本需要支持暂停状态的原生 helper",
            )
        })?;
        if !state["paused"].is_boolean() || !state["recoveryRequired"].is_boolean() {
            return Err(Error::new("HELPER_PROTOCOL", "脚本暂停状态回执无效"));
        }
        if state["paused"] == true
            || state["recoveryRequired"] == true
            || epoch.is_some_and(|old| old != current)
        {
            return Err(Error::new("USER_PAUSED", USER_PAUSED_PUBLIC_MESSAGE));
        }
        // Local scripts need the same atomic epoch check as remote operations:
        // a pause/resume between this guard and dispatch must reject old input.
        // Keep a remote operation's original expected epoch unchanged.
        if epoch.is_none() && self.operation_owner.is_none() {
            self.native.set_input_epoch(Some(current));
        }
        *epoch = Some(current);
        Ok(())
    }

    fn run_script(
        &mut self,
        request: &Value,
        plan: &crate::script::Plan,
        deadline: Instant,
    ) -> Result<Value> {
        let mut progress = json!({"connectionId":request["connectionId"],"completedSteps":0,"totalSteps":plan.steps.len(),"steps":[]});
        if let Some(frame) = request.get("frameId") {
            progress["frameId"] = frame.clone();
        }
        let mut epoch = None;
        for (i, step) in plan.steps.iter().enumerate() {
            let result = (|| {
                self.script_guard(deadline, &mut epoch)?;
                if step["action"] == "wait" {
                    let until = Instant::now()
                        + Duration::from_millis(step["ms"].as_u64().expect("预校验等待"));
                    while Instant::now() < until {
                        std::thread::sleep(
                            until
                                .saturating_duration_since(Instant::now())
                                .min(Duration::from_millis(25)),
                        );
                        self.script_guard(deadline, &mut epoch)?;
                    }
                    return Ok(json!({}));
                }
                let mut input = step.clone();
                input["connectionId"] = request["connectionId"].clone();
                if !matches!(step["action"].as_str(), Some("observe" | "click-target")) {
                    input["frameId"] = progress
                        .get("frameId")
                        .cloned()
                        .ok_or_else(|| Error::invalid("脚本缺少有效帧"))?;
                }
                if step["action"] == "click-target" {
                    for key in ["jevKey", "jevUrl", "jevModel", "jevProtocol"] {
                        if let Some(value) = request.get(key) {
                            input[key] = value.clone();
                        }
                    }
                }
                self.execute(input)
            })();
            match result {
                Ok(receipt) => {
                    if let Some(frame) = receipt.get("frameId") {
                        progress["frameId"] = frame.clone();
                    }
                    let mut summary = json!({"index":i+1,"action":step["action"]});
                    for key in ["frameId", "sent", "eb"] {
                        if let Some(value) = receipt.get(key) {
                            summary[key] = value.clone();
                        }
                    }
                    progress["steps"].as_array_mut().unwrap().push(summary);
                    progress["completedSteps"] = json!(i + 1);
                    // Preserve completion if pause arrives after an accepted step;
                    // the next step fails at its guard and is never replayed.
                }
                Err(mut error) => {
                    progress["failedStep"] = json!(i + 1);
                    if let Some(native) = error.receipt.take() {
                        progress["nativeReceipt"] = native;
                    }
                    return Err(error.with_receipt(progress));
                }
            }
        }
        Ok(progress)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct LastStepNative {
        cancelled: Arc<AtomicBool>,
        sent: usize,
    }
    impl Native for LastStepNative {
        fn request(&mut self, request: Value) -> Result<Value> {
            let bounds = json!({"x":0.0,"y":0.0,"width":800.0,"height":600.0});
            match request["action"].as_str().unwrap() {
                "permissions" => Ok(json!({"screenRecording":true,"accessibility":true})),
                "windows" => Ok(
                    json!({"windows":[{"windowId":42,"pid":123,"title":"test","bounds":bounds}]}),
                ),
                "window" => {
                    Ok(json!({"window":{"windowId":42,"pid":123,"title":"test","bounds":bounds}}))
                }
                "observe" => {
                    std::fs::write(
                        request["imagePath"].as_str().unwrap(),
                        [0xff, 0xd8, 0xff, 0xd9],
                    )
                    .unwrap();
                    Ok(
                        json!({"imagePath":request["imagePath"],"width":800,"height":600,"bounds":bounds,"capturedAtMs":1}),
                    )
                }
                "transport-state" => {
                    Ok(json!({"inputEpoch":0,"paused":false,"recoveryRequired":false}))
                }
                "type" => {
                    self.sent += 1;
                    self.cancelled.store(true, Ordering::Release);
                    Ok(json!({"sent":true}))
                }
                _ => Ok(json!({"sent":true})),
            }
        }
    }
    #[test]
    fn script_last_step_delivery_keeps_progress_if_cancel_arrives_at_completion() {
        let root = std::env::temp_dir().join(format!("mcc-script-cancel-{}", random_id().unwrap()));
        std::fs::create_dir(&root).unwrap();
        let cancelled = Arc::new(AtomicBool::new(false));
        let mut service = Service::new(
            LastStepNative {
                cancelled: cancelled.clone(),
                sent: 0,
            },
            root.clone(),
        );
        let connected = service
            .execute(json!({"action":"connect","windowId":42}))
            .unwrap();
        let error=service.execute_remote(json!({"action":"script","connectionId":connected["connectionId"],"script":{"version":1,"steps":[{"action":"observe"},{"action":"type","text":"hello"}]}}),0,cancelled,Arc::new(AtomicBool::new(false)),Arc::new(||true)).unwrap_err();
        assert_eq!(error.code, "USER_PAUSED");
        assert_eq!(error.receipt.unwrap()["completedSteps"], 2);
        assert_eq!(service.native.sent, 1);
        std::fs::remove_dir_all(root).unwrap();
    }
}
