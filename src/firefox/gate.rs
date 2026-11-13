use crate::protocol::{Error, Result};
use serde_json::{json, Value};

pub struct Gate {
    pub lease: u64,
    pub epoch: u64,
    pub paused: bool,
    pub recovery: bool,
    transport_locked: bool,
    pub reason: &'static str,
    pub active: bool,
    pub target: Option<(u32, i32)>,
    pub input_started: bool,
}
impl Default for Gate {
    fn default() -> Self {
        Self::new()
    }
}
impl Gate {
    pub fn new() -> Self {
        Self {
            lease: 0,
            epoch: 0,
            paused: false,
            recovery: false,
            transport_locked: false,
            reason: "",
            active: false,
            target: None,
            input_started: false,
        }
    }
    pub fn bind(&mut self, id: u32, pid: i32) {
        self.lease += 1;
        self.target = Some((id, pid));
        self.input_started = false;
    }
    pub fn check(&self, expected: Option<u64>) -> Result<()> {
        if self.recovery {
            return Err(Error::new(
                "RECOVERY_REQUIRED",
                "输入状态未确认；请断开 owned 会话并显式恢复",
            ));
        }
        if self.paused || expected.is_some_and(|e| e != self.epoch) {
            return Err(Error::new(
                "USER_PAUSED",
                crate::protocol::USER_PAUSED_PUBLIC_MESSAGE,
            ));
        }
        Ok(())
    }
    /// Preserve the recovery latch during Service's window refresh. Returning
    /// WINDOW_UNAVAILABLE here would trigger its automatic disconnect cleanup.
    pub fn check_request(&self, action: &str) -> Result<()> {
        if self.recovery
            && !matches!(
                action,
                "permissions"
                    | "apps"
                    | "windows"
                    | "cancel"
                    | "transport-disconnect"
                    | "transport-recover"
            )
        {
            return Err(Error::new(
                "RECOVERY_REQUIRED",
                "输入状态未确认；请显式断开 owned 会话后重新连接",
            ));
        }
        Ok(())
    }
    pub fn pause(&mut self, reason: &'static str, recovery: bool) {
        // This gate belongs to the dedicated Docker desktop. Passive noVNC
        // activity does not revoke a permit; explicit stops and faults still do.
        if !recovery && matches!(reason, "userInteraction" | "focusLoss") {
            return;
        }
        self.paused = true;
        self.reason = reason;
        self.recovery |= recovery;
        self.epoch += 1;
        self.input_started = false;
    }
    pub fn resume(&mut self) -> Result<()> {
        if self.recovery {
            return Err(Error::new("RECOVERY_REQUIRED", "必须先恢复未知输入状态"));
        }
        if self.active {
            return Err(Error::new("BUSY", "仍在结束当前输入和释放按键，请稍后继续"));
        }
        self.paused = false;
        self.transport_locked = false;
        self.reason = "";
        self.epoch += 1;
        // Host recognizes a locally resumed lease in the running phase.
        // No countdown is needed on the dedicated container desktop.
        self.input_started = self.target.is_some();
        Ok(())
    }
    pub fn auto_resume(&mut self, lease: u64, epoch: u64) -> Result<()> {
        if !self.paused
            || self.recovery
            || self.transport_locked
            || self.active
            || self.lease != lease
            || self.epoch != epoch
            || !matches!(self.reason, "userInteraction" | "focusLoss")
        {
            return Err(Error::new(
                "USER_PAUSED",
                crate::protocol::USER_PAUSED_PUBLIC_MESSAGE,
            ));
        }
        self.resume()?;
        Ok(())
    }
    pub fn transport_pause(&mut self) -> Value {
        self.transport_locked = true;
        self.pause("transport", false);
        let mut state = self.state();
        state["recovered"] = json!(false);
        state
    }
    pub fn reset(&mut self) {
        self.lease = 0;
        self.epoch += 1;
        self.paused = false;
        self.recovery = false;
        self.transport_locked = false;
        self.reason = "";
        self.target = None;
        self.active = false;
        self.input_started = false;
    }
    pub fn state(&self) -> Value {
        let phase = if self.paused {
            "paused"
        } else if self.input_started {
            "running"
        } else {
            // Preserve the shared transport's ready-before-first-input phase.
            // The Docker helper starts immediately and never runs a countdown.
            "awaitingCountdown"
        };
        json!({"transportPauseVersion":1,"hostAutoTakeoverVersion":1,"paused":self.paused,"phase":phase,"pauseReason":if self.reason.is_empty(){"none"}else{self.reason},"lease":self.target.map(|_|self.lease),"inputEpoch":self.epoch,"recoveryRequired":self.recovery||self.transport_locked,"active":self.active,"inputState":if self.active||self.recovery{"unknown"}else{"released"}})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn passive_container_activity_does_not_pause_or_revoke_input() {
        let mut gate = Gate::new();
        gate.bind(7, 42);
        let epoch = gate.epoch;
        for reason in ["userInteraction", "focusLoss"] {
            gate.pause(reason, false);
            assert!(
                gate.check(Some(epoch)).is_ok(),
                "{reason} blocked Docker input"
            );
            assert!(!gate.paused);
            assert_eq!(gate.epoch, epoch);
        }
        gate.pause("explicitPause", false);
        assert!(gate.check(Some(epoch)).is_err());
    }
    #[test]
    fn container_resume_does_not_schedule_a_human_countdown() {
        let mut gate = Gate::new();
        gate.bind(7, 42);
        gate.pause("explicitPause", false);
        gate.resume().unwrap();
        assert_eq!(gate.state()["phase"], "running");
        assert!(gate.check(Some(gate.epoch)).is_ok());
    }
    #[test]
    fn state_preserves_host_transport_phases_without_passive_pause() {
        let mut gate = Gate::new();
        assert!(gate.state()["lease"].is_null());
        assert_eq!(gate.state()["phase"], "awaitingCountdown");
        assert_eq!(gate.state()["pauseReason"], "none");
        gate.bind(7, 42);
        gate.input_started = true;
        assert_eq!(gate.state()["phase"], "running");
        gate.pause("explicitPause", false);
        gate.resume().unwrap();
        assert_eq!(gate.state()["phase"], "running");
        assert_eq!(gate.state()["pauseReason"], "none");
        gate.reset();
        assert!(gate.state()["lease"].is_null());
    }
    #[test]
    fn transport_pause_requires_explicit_resume_and_never_unlocks_unknown_input() {
        let mut gate = Gate::new();
        gate.bind(7, 42);
        let paused = gate.transport_pause();
        assert_eq!(paused["phase"], "paused");
        assert_eq!(paused["recovered"], false);
        assert_eq!(paused["recoveryRequired"], true);
        assert!(gate.auto_resume(gate.lease, gate.epoch).is_err());
        gate.resume().unwrap();
        assert_eq!(gate.state()["phase"], "running");
        assert_eq!(gate.state()["recoveryRequired"], false);
        gate.pause("unknownInput", true);
        gate.transport_pause();
        assert!(gate.resume().is_err());
        assert_eq!(gate.state()["inputState"], "unknown");
    }
    #[test]
    fn pause_revokes_old_permits_and_soft_activity_cannot_remove_explicit_pause() {
        let mut gate = Gate::new();
        gate.bind(7, 42);
        let epoch = gate.epoch;
        assert!(gate.check(Some(epoch)).is_ok());
        gate.pause("explicitPause", false);
        gate.pause("userInteraction", false);
        assert!(gate.check(Some(epoch)).is_err());
        assert!(gate.auto_resume(gate.lease, gate.epoch).is_err());
        gate.resume().unwrap();
        assert!(gate.check(Some(epoch)).is_err());
        assert!(gate.check(Some(gate.epoch)).is_ok());
    }
    #[test]
    fn unknown_input_requires_recovery_instead_of_resume_or_auto_takeover() {
        let mut gate = Gate::new();
        gate.bind(7, 42);
        gate.pause("unknownInput", true);
        assert!(gate.resume().is_err());
        assert!(gate.auto_resume(gate.lease, gate.epoch).is_err());
        assert_eq!(gate.state()["recoveryRequired"], true);
        for action in ["window", "observe", "click", "firefox-start"] {
            assert_eq!(
                gate.check_request(action).unwrap_err().code,
                "RECOVERY_REQUIRED"
            );
        }
        for action in [
            "permissions",
            "apps",
            "windows",
            "cancel",
            "transport-disconnect",
            "transport-recover",
        ] {
            assert!(gate.check_request(action).is_ok());
        }
    }
}
