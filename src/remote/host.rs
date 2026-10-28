//! Authenticated WSS host; desktop work is delegated to the existing daemon.
use super::{
    credentials, images,
    options::HostOptions,
    protocol::{self, Hello},
    session::{Begin, Effect, SessionManager, State},
    wire::{self, Admission, ClientControl, RequestBudget, ServerControl},
};
use crate::{
    daemon, execution,
    private_files::LockedStateDir,
    protocol::{Error, Result, Scope},
    runtime::Runtime,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    net::TcpListener,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tungstenite::Message;

static STOP: AtomicBool = AtomicBool::new(false);
struct SignalRegistrations(Vec<signal_hook::SigId>);
impl Drop for SignalRegistrations {
    fn drop(&mut self) {
        for id in self.0.drain(..) {
            signal_hook::low_level::unregister(id);
        }
    }
}
fn fail(code: &str) -> Error {
    Error::new(code, "远程 Host 操作失败")
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Journal {
    clean: bool,
    owner: String,
    daemon_pid: Option<u32>,
    helper_pid: Option<u32>,
    scope: Scope,
}
// The journal is written before claim with both PIDs absent, and the two PIDs
// are atomically persisted after claim and before any desktop operation dispatch.
// A partial pair is corrupt, not evidence that a claim is safe to discard.
#[derive(Clone, Copy, PartialEq, Eq)]
enum JournalPhase {
    PendingClaim,
    Owned,
}
impl Journal {
    fn phase(&self) -> Result<JournalPhase> {
        match (self.daemon_pid, self.helper_pid) {
            (None, None) => Ok(JournalPhase::PendingClaim),
            (Some(daemon), Some(helper)) if daemon > 0 && helper > 0 => Ok(JournalPhase::Owned),
            _ => Err(fail("RECOVERY_REQUIRED")),
        }
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum ClaimState {
    Pending,
    Rejected,
    Owned,
}
struct Owner {
    sid: String,
    capability: String,
    claim_state: ClaimState,
    initial_reservation: bool,
}
#[derive(Clone, Copy)]
struct PauseProof {
    lease: u64,
    epoch: u64,
}
impl PauseProof {
    fn from_receipt(v: &Value) -> Option<Self> {
        if v["paused"] != true {
            return None;
        }
        Some(Self {
            lease: v["lease"].as_u64()?,
            epoch: v["inputEpoch"].as_u64()?,
        })
    }
    fn matches(&self, v: &Value) -> bool {
        v["lease"].as_u64() == Some(self.lease)
            && v["inputEpoch"].as_u64().is_some_and(|n| n > self.epoch)
            && v["paused"] == false
            && v["recoveryRequired"] == false
            && matches!(v["phase"].as_str(), Some("countdown" | "running"))
    }
}
struct Core {
    manager: SessionManager,
    owner: Option<Owner>,
    journal: LockedStateDir,
    boot: String,
    scope: Scope,
    started: Instant,
    requests: RequestBudget,
    pause_proof: Option<PauseProof>,
    allowed_file_roots: Vec<PathBuf>,
    backend_running: bool,
    transitioning: bool,
    active_transports: usize,
}
impl Core {
    fn now(&self) -> u64 {
        self.started.elapsed().as_millis().min(u64::MAX as u128) as u64
    }
    fn write_journal(&self, entry: &Journal) -> Result<()> {
        let data = serde_json::to_vec(entry).map_err(|_| fail("RECOVERY_REQUIRED"))?;
        self.journal
            .write("host.json", &data)
            .map_err(|_| fail("RECOVERY_REQUIRED"))
    }
}
fn allowed_file(roots: &[PathBuf], path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        return Err(fail("FILE_NOT_ALLOWED"));
    }
    let path = path.canonicalize().map_err(|_| fail("FILE_NOT_ALLOWED"))?;
    if !path.is_file() || !roots.iter().any(|root| path.starts_with(root)) {
        return Err(fail("FILE_NOT_ALLOWED"));
    }
    Ok(path)
}
fn state_path(path: Option<PathBuf>, scope: Scope) -> Result<PathBuf> {
    let root = match path {
        Some(p) => p,
        None => match std::env::var_os("MCC_CONFIG_DIR") {
            Some(p) => PathBuf::from(p).join("remote-host").join(scope.name()),
            None => {
                PathBuf::from(std::env::var_os("HOME").ok_or_else(|| fail("RECOVERY_REQUIRED"))?)
                    .join(".config/mcc/remote-host")
                    .join(scope.name())
            }
        },
    };
    if !root.is_absolute() {
        return Err(fail("INVALID_ARGUMENT"));
    }
    Ok(root)
}
fn read_journal(store: &LockedStateDir) -> Result<Option<Journal>> {
    store
        .read("host.json", 64 * 1024)
        .map_err(|_| fail("RECOVERY_REQUIRED"))?
        .map(|v| serde_json::from_slice(&v).map_err(|_| fail("RECOVERY_REQUIRED")))
        .transpose()
}
fn pid_gone(pid: u32) -> bool {
    if pid == 0 || pid > i32::MAX as u32 {
        return false;
    }
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    rc != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}
/// Explicit local recovery only; never starts a daemon or replaces a helper.
pub fn recover(state_dir: Option<PathBuf>, scope: Scope) -> Result<Value> {
    let store = LockedStateDir::open(&state_path(state_dir, scope)?)
        .map_err(|_| fail("RECOVERY_REQUIRED"))?;
    let mut j = match read_journal(&store)? {
        None => return Ok(json!({"recovered":false,"clean":true})),
        Some(j) => j,
    };
    if j.scope != scope {
        return Err(fail("RECOVERY_REQUIRED"));
    }
    if j.clean {
        return Ok(json!({"recovered":false,"clean":true}));
    }
    let phase = j.phase()?;
    let runtime = Runtime::from_env_for_scope(scope)?;
    let status = daemon::status(&runtime)?;
    // Socket absence alone does not prove a daemon isn't starting or still
    // holding an unpublished listener. Keep its existing lock through commit.
    let _absent_daemon_lock = if status["running"] == false && runtime.root.exists() {
        Some(runtime.lock().map_err(|_| fail("RECOVERY_REQUIRED"))?)
    } else {
        None
    };
    if status["running"] == true {
        let result = match phase {
            JournalPhase::PendingClaim => daemon::remote_recover(&runtime, &j.owner),
            JournalPhase::Owned => daemon::remote_recover_checked(
                &runtime,
                &j.owner,
                j.daemon_pid.ok_or_else(|| fail("RECOVERY_REQUIRED"))?,
                j.helper_pid.ok_or_else(|| fail("RECOVERY_REQUIRED"))?,
            ),
        };
        match result {
            Ok(receipt) if receipt["recovered"] == true => {}
            // For a pending claim only, the daemon's owner check proves this
            // capability cannot have dispatched an operation. Do not affect its
            // current owner or helper. Transport/other failures remain locked.
            Err(error) if phase == JournalPhase::PendingClaim && error.code == "NOT_OWNER" => {}
            _ => return Err(fail("RECOVERY_REQUIRED")),
        }
    } else if status["running"] != false
        || (phase == JournalPhase::Owned
            && (!j.daemon_pid.is_some_and(pid_gone) || !j.helper_pid.is_some_and(pid_gone)))
    {
        return Err(fail("RECOVERY_REQUIRED"));
    }
    j.clean = true;
    store
        .write(
            "host.json",
            &serde_json::to_vec(&j).map_err(|_| fail("RECOVERY_REQUIRED"))?,
        )
        .map_err(|_| fail("RECOVERY_REQUIRED"))?;
    Ok(json!({"recovered":true,"clean":true}))
}
type Socket = tungstenite::WebSocket<
    wire::UpgradeStream<rustls::StreamOwned<rustls::ServerConnection, wire::DeadlineTcp>>,
>;
fn send<T: Serialize>(socket: &mut Socket, value: &T, deadline: Instant) -> Result<()> {
    let data = serde_json::to_string(value).map_err(|_| fail("PROTOCOL_ERROR"))?;
    if data.len() > crate::protocol::MAX_MESSAGE_BYTES {
        return Err(fail("MESSAGE_TOO_LARGE"));
    }
    socket.get_mut().inner_mut().sock.set_deadline(deadline);
    socket
        .send(Message::Text(data.into()))
        .map_err(|_| fail("REMOTE_DISCONNECTED"))
}
fn read_text(socket: &mut Socket, deadline: Instant) -> Result<Vec<u8>> {
    socket.get_mut().inner_mut().sock.set_deadline(deadline);
    loop {
        match socket.read().map_err(|_| fail("REMOTE_DISCONNECTED"))? {
            Message::Text(s) => return Ok(s.as_bytes().to_vec()),
            Message::Ping(_) | Message::Pong(_) => {
                socket.flush().map_err(|_| fail("REMOTE_DISCONNECTED"))?
            }
            _ => return Err(fail("PROTOCOL_ERROR")),
        }
    }
}
fn send_untracked_result(ws: &mut Socket, id: &str, sequence: u64, response: Value) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(5);
    send(
        ws,
        &ServerControl::Result {
            id: id.into(),
            sequence,
            response,
            image: None,
        },
        deadline,
    )?;
    let ack = wire::parse_client_control(&read_text(ws, deadline)?)?;
    if !matches!(ack, ClientControl::Ack { id: ref ack_id, sequence: ack_seq } if ack_id == id && ack_seq == sequence)
    {
        return Err(fail("PROTOCOL_ERROR"));
    }
    send(
        ws,
        &ServerControl::Acked {
            id: id.into(),
            sequence,
        },
        deadline,
    )?;
    ws.get_mut().inner_mut().sock.set_deadline(deadline);
    if matches!(ws.read(), Ok(Message::Close(_))) {
        let _ = ws.flush();
    }
    Ok(())
}
fn state_name(state: State) -> &'static str {
    match state {
        State::Ready => "ready",
        State::LostPaused => "lost_paused",
        State::CancellationUnconfirmed => "cancellation_unconfirmed",
        State::RecoveryRequired => "recovery_required",
    }
}
fn cached_frame_failure(cached: bool, scope: Scope, error: Error) -> Result<Value> {
    if cached
        && matches!(
            error.code.as_str(),
            "FRAME_NOT_FOUND" | "REMOTE_IMAGE_INVALID"
        )
    {
        Ok(crate::protocol::response_for(
            Err(fail("FRAME_NOT_FOUND")),
            scope,
        ))
    } else {
        Err(error)
    }
}
fn register_result_frame(
    manager: &mut SessionManager,
    sid: &str,
    connection: &str,
    frame: &str,
    cached: bool,
) -> Result<()> {
    if cached {
        manager.authorize_frame(sid, connection, frame)
    } else {
        manager.register_frame(sid, connection, frame)
    }
}
fn locked(core: &Arc<Mutex<Core>>) -> Result<std::sync::MutexGuard<'_, Core>> {
    core.lock().map_err(|_| fail("RECOVERY_REQUIRED"))
}
fn mark_lost(
    core: &Arc<Mutex<Core>>,
    sid: &str,
    seq: u64,
    id: &str,
    ticket: u64,
    cancel: &AtomicBool,
) {
    cancel.store(true, Ordering::Release);
    let owner = {
        let Ok(mut c) = core.lock() else { return };
        let now = c.now();
        let effect = c.manager.lost_rpc(sid, seq, id, ticket, now);
        if !matches!(effect, Ok(Effect::PauseOwnedOperation)) {
            return;
        }
        c.owner
            .as_ref()
            .filter(|o| o.sid == sid)
            .map(|o| o.capability.clone())
    };
    if let Some(owner) = owner {
        let scope = match core.lock() {
            Ok(c) => c.scope,
            Err(_) => return,
        };
        let result =
            Runtime::from_env_for_scope(scope).and_then(|r| daemon::remote_pause(&r, &owner, None));
        if let Ok(mut c) = core.lock() {
            if result.as_ref().is_ok_and(|v| v["paused"] == true) {
                c.pause_proof = result.as_ref().ok().and_then(PauseProof::from_receipt);
                let _ = c.manager.acknowledge_pause();
            }
        }
    }
}
struct ActiveGuard {
    core: Arc<Mutex<Core>>,
    sid: String,
    seq: u64,
    id: String,
    ticket: u64,
    cancel: Arc<AtomicBool>,
    permit: Option<u64>,
    finished: bool,
}
impl Drop for ActiveGuard {
    fn drop(&mut self) {
        struct TransportSlot(Arc<Mutex<Core>>);
        impl Drop for TransportSlot {
            fn drop(&mut self) {
                if let Ok(mut c) = self.0.lock() {
                    c.active_transports = c.active_transports.saturating_sub(1);
                }
            }
        }
        let _slot = TransportSlot(self.core.clone());
        if self.finished {
            return;
        }
        if let Some(permit) = self.permit {
            let owner = {
                let Ok(mut c) = self.core.lock() else { return };
                let now = c.now();
                let e = c
                    .manager
                    .abandon_acked_transport(&self.sid, self.seq, &self.id, permit, now);
                if !matches!(e, Ok(Effect::PauseOwnedOperation)) {
                    return;
                }
                c.owner
                    .as_ref()
                    .filter(|o| o.sid == self.sid)
                    .map(|o| o.capability.clone())
            };
            if let Some(cap) = owner {
                let scope = match self.core.lock() {
                    Ok(c) => c.scope,
                    Err(_) => return,
                };
                let r = Runtime::from_env_for_scope(scope)
                    .and_then(|r| daemon::remote_pause(&r, &cap, None));
                if let Ok(mut c) = self.core.lock() {
                    if r.as_ref().is_ok_and(|v| v["paused"] == true) {
                        c.pause_proof = r.as_ref().ok().and_then(PauseProof::from_receipt);
                        let _ = c.manager.acknowledge_pause();
                    }
                }
            }
        } else {
            mark_lost(
                &self.core,
                &self.sid,
                self.seq,
                &self.id,
                self.ticket,
                &self.cancel,
            );
        }
    }
}
fn execute(
    core: &Arc<Mutex<Core>>,
    sid: &str,
    mut request: Value,
    seq: u64,
    expected_owner: Option<&str>,
    cancel: &AtomicBool,
) -> Result<Value> {
    let action = request["action"]
        .as_str()
        .ok_or_else(|| fail("INVALID_ARGUMENT"))?
        .to_owned();
    let scope = locked(core)?.scope;
    if action == "select-file" {
        let input = request["path"]
            .as_str()
            .ok_or_else(|| fail("INVALID_ARGUMENT"))?;
        let path = allowed_file(&locked(core)?.allowed_file_roots, Path::new(input))?;
        request["path"] = json!(path);
    }
    if action == "frame" {
        let connection = request["connectionId"]
            .as_str()
            .ok_or_else(|| fail("INVALID_ARGUMENT"))?;
        let frame = request["frameId"]
            .as_str()
            .ok_or_else(|| fail("INVALID_ARGUMENT"))?;
        locked(core)?
            .manager
            .authorize_frame(sid, connection, frame)?;
        return Ok(json!({}));
    }
    if matches!(
        action.as_str(),
        "status" | "apps" | "windows" | "permissions"
    ) && locked(core)?.owner.is_none()
    {
        let (state, clean) = {
            let c = locked(core)?;
            (
                c.manager.state(),
                read_journal(&c.journal)?.is_none_or(|j| j.clean && j.scope == scope),
            )
        };
        let runtime = Runtime::from_env_for_scope(scope)?;
        if action == "status" {
            let mut status = daemon::status(&runtime)?;
            status["remoteHostState"] = json!(state_name(state));
            return Ok(status);
        }
        if state == State::Ready && clean {
            return execution::execute_request(request, None, scope);
        }
        if daemon::status(&runtime)?["running"] != true {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        return daemon::call(&runtime, request);
    }
    let owner = {
        let c = locked(core)?;
        c.owner
            .as_ref()
            .filter(|o| o.sid == sid && Some(o.capability.as_str()) == expected_owner)
            .map(|o| o.capability.clone())
            .ok_or_else(|| fail("NOT_OWNER"))?
    };
    let runtime = Runtime::from_env_for_scope(scope)?;
    if matches!(action.as_str(), "connect" | "chrome-start") {
        let needs_claim = {
            let c = locked(core)?;
            read_journal(&c.journal)?.is_none_or(|j| j.daemon_pid.is_none())
        };
        if needs_claim {
            if cancel.load(Ordering::Acquire) {
                return Err(fail("CANCEL_UNCONFIRMED"));
            }
            daemon::start(&runtime)?;
            let claim = match daemon::remote_claim(&runtime, &owner) {
                Ok(claim) => claim,
                Err(error) => {
                    // Only definite daemon-side claim rejections can establish
                    // that this capability was never installed; transport errors
                    // and pause/recovery failures remain pending and locked.
                    if matches!(
                        error.code.as_str(),
                        "BUSY" | "HELPER_UPGRADE_REQUIRED" | "DAEMON_UPGRADE_REQUIRED"
                    ) {
                        let mut c = locked(core)?;
                        if let Some(current) = c
                            .owner
                            .as_mut()
                            .filter(|o| o.sid == sid && o.capability == owner)
                        {
                            current.claim_state = ClaimState::Rejected;
                        }
                    }
                    return Err(error);
                }
            };
            if claim["owned"] != true {
                return Err(fail("RECOVERY_REQUIRED"));
            }
            let dp = claim["daemonPid"]
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .ok_or_else(|| fail("RECOVERY_REQUIRED"))?;
            let hp = claim["helperPid"]
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .ok_or_else(|| fail("RECOVERY_REQUIRED"))?;
            {
                let mut c = locked(core)?;
                c.write_journal(&Journal {
                    clean: false,
                    owner: owner.clone(),
                    daemon_pid: Some(dp),
                    helper_pid: Some(hp),
                    scope,
                })?;
                let current = c
                    .owner
                    .as_mut()
                    .filter(|o| o.sid == sid && o.capability == owner)
                    .ok_or_else(|| fail("RECOVERY_REQUIRED"))?;
                current.claim_state = ClaimState::Owned;
            }
            if cancel.load(Ordering::Acquire) {
                let paused = daemon::remote_pause(&runtime, &owner, None);
                if let Ok(mut c) = core.lock() {
                    if paused.as_ref().is_ok_and(|v| v["paused"] == true) {
                        c.pause_proof = paused.as_ref().ok().and_then(PauseProof::from_receipt);
                        let _ = c.manager.acknowledge_pause();
                    } else {
                        c.manager.require_recovery();
                    }
                }
                return Err(fail("CANCEL_UNCONFIRMED"));
            }
        }
    }
    if cancel.load(Ordering::Acquire) || STOP.load(Ordering::Acquire) {
        return Err(fail("CANCEL_UNCONFIRMED"));
    }
    let result = execution::execute_remote_request(request, scope, &owner, &seq.to_string());
    if result.as_ref().err().is_some_and(|e| {
        matches!(
            e.code.as_str(),
            "HELPER_EOF"
                | "HELPER_TIMEOUT"
                | "HELPER_PROTOCOL"
                | "DAEMON_UNAVAILABLE"
                | "NOT_OWNER"
                | "IO_ERROR"
        )
    }) {
        if let Ok(mut c) = core.lock() {
            c.manager.require_recovery();
        }
    }
    result
}
type BackendThreads = Arc<Mutex<Vec<std::thread::JoinHandle<()>>>>;
fn serve_connection(
    mut ws: Socket,
    core: Arc<Mutex<Core>>,
    backends: BackendThreads,
) -> Result<()> {
    let (boot, scope, allow_files) = {
        let c = locked(&core)?;
        (c.boot.clone(), c.scope, !c.allowed_file_roots.is_empty())
    };
    send(
        &mut ws,
        &Hello {
            remote_protocol: protocol::REMOTE_PROTOCOL,
            version: env!("CARGO_PKG_VERSION").into(),
            scope,
            boot_id: boot.clone(),
            capabilities: vec!["remote-v1".into()],
        },
        Instant::now() + Duration::from_secs(5),
    )?;
    let req = wire::parse_client_control(&read_text(
        &mut ws,
        Instant::now() + Duration::from_secs(5),
    )?)?;
    let (requested, requested_boot) = match req {
        ClientControl::Session {
            scope: s,
            session,
            boot_id,
            ..
        } if s == scope => (session, boot_id),
        _ => return Err(fail("PROTOCOL_ERROR")),
    };
    let sid = {
        let mut c = locked(&core)?;
        if let Some(s) = requested {
            c.manager
                .authorize(&s, requested_boot.as_deref().unwrap_or(""), scope)?;
            s
        } else {
            let s = crate::protocol::random_id()?;
            let now = c.now();
            c.manager.issue(&s, scope, now)?;
            s
        }
    };
    // A network message cannot resume control. Only observe a locally resumed
    // native lease and reconcile it while no Host flight or backend worker exists.
    let resume = {
        let c = locked(&core)?;
        if c.manager.state() == State::LostPaused && c.active_transports == 0 && !c.backend_running
        {
            c.owner
                .as_ref()
                .filter(|o| o.sid == sid)
                .and_then(|o| c.pause_proof.map(|p| (o.capability.clone(), p)))
        } else {
            None
        }
    };
    if let Some((owner, proof)) = resume {
        if let Ok(state) = Runtime::from_env_for_scope(scope)
            .and_then(|r| daemon::remote_control_state(&r, &owner))
        {
            if proof.matches(&state) {
                let mut c = locked(&core)?;
                if c.manager.state() == State::LostPaused
                    && c.active_transports == 0
                    && !c.backend_running
                    && c.owner
                        .as_ref()
                        .is_some_and(|o| o.sid == sid && o.capability == owner)
                {
                    let now = c.now();
                    if c.manager.acknowledge_local_resume(&sid, now).is_ok() {
                        c.pause_proof = None;
                    }
                }
            }
        }
    }
    let state = {
        let c = locked(&core)?;
        state_name(c.manager.state()).to_owned()
    };
    send(
        &mut ws,
        &ServerControl::Session {
            session: sid.clone(),
            boot_id: boot,
            state,
        },
        Instant::now() + Duration::from_secs(5),
    )?;
    let bytes = read_text(&mut ws, Instant::now() + Duration::from_secs(5))?;
    if let Ok(ClientControl::Query {
        session,
        sequence,
        id,
        request,
    }) = wire::parse_client_control(&bytes)
    {
        if session != sid {
            return Err(fail("NOT_OWNER"));
        }
        protocol::validate_action_with_files(scope, &request, allow_files)?;
        let req = serde_json::to_vec(&request).map_err(|_| fail("PROTOCOL_ERROR"))?;
        let value = {
            let mut c = locked(&core)?;
            let now = c.now();
            c.requests.consume(&sid, now)?;
            serde_json::from_slice::<Value>(&c.manager.query_cached(&sid, sequence, &id, &req)?)
                .map_err(|_| fail("PROTOCOL_ERROR"))?
        };
        return send(
            &mut ws,
            &ServerControl::Result {
                id,
                sequence,
                response: value,
                image: None,
            },
            Instant::now() + Duration::from_secs(5),
        );
    }
    let env = match protocol::parse_envelope_with_files(&bytes, allow_files) {
        Ok(env) => env,
        Err(error) if !allow_files => {
            // Parse only to return an explicit policy rejection, never to dispatch.
            let candidate = protocol::parse_envelope_with_files(&bytes, true)?;
            if candidate.scope != scope
                || candidate.session != sid
                || candidate.request["action"] != "select-file"
            {
                return Err(error);
            }
            {
                let mut c = locked(&core)?;
                let now = c.now();
                c.requests.consume(&sid, now)?;
            }
            return send_untracked_result(
                &mut ws,
                &candidate.id,
                candidate.sequence,
                crate::protocol::response_for(Err(fail("FILE_NOT_ALLOWED")), scope),
            );
        }
        Err(error) => return Err(error),
    };
    if env.scope != scope || env.session != sid {
        return Err(fail("NOT_OWNER"));
    }
    {
        let mut c = locked(&core)?;
        let now = c.now();
        c.requests.consume(&sid, now)?;
    }
    let action = env.request["action"]
        .as_str()
        .ok_or_else(|| fail("INVALID_ARGUMENT"))?
        .to_string();
    if matches!(
        action.as_str(),
        "status" | "apps" | "windows" | "permissions"
    ) {
        let state = locked(&core)?.manager.state();
        if matches!(
            state,
            State::RecoveryRequired | State::CancellationUnconfirmed
        ) {
            let runtime = Runtime::from_env_for_scope(scope)?;
            let response = if action == "status" {
                daemon::status(&runtime).map(|mut status| {
                    status["remoteHostState"] = json!(state_name(state));
                    status
                })
            } else {
                match daemon::status(&runtime) {
                    Ok(status) if status["running"] == true => {
                        daemon::call(&runtime, env.request.clone())
                    }
                    _ => Err(fail("RECOVERY_REQUIRED")),
                }
            };
            return send_untracked_result(
                &mut ws,
                &env.id,
                env.sequence,
                crate::protocol::response_for(response, scope),
            );
        }
    }
    let request_bytes = serde_json::to_vec(&env.request).map_err(|_| fail("PROTOCOL_ERROR"))?;
    let started: Result<(Begin, u64, Option<String>)> = (|| {
        let mut c = locked(&core)?;
        if STOP.load(Ordering::Acquire) {
            return Err(fail("REMOTE_STOPPING"));
        }
        let now = c.now();
        if c.backend_running || c.transitioning {
            return Err(fail("BUSY"));
        }
        if matches!(action.as_str(), "connect" | "chrome-start") && c.owner.is_none() {
            c.manager.reserve_control(&sid, now)?;
            let owner = crate::protocol::random_id()?;
            c.write_journal(&Journal {
                clean: false,
                owner: owner.clone(),
                daemon_pid: None,
                helper_pid: None,
                scope,
            })?;
            c.owner = Some(Owner {
                sid: sid.clone(),
                capability: owner,
                claim_state: ClaimState::Pending,
                initial_reservation: true,
            });
        }
        let (begin, ticket) =
            c.manager
                .begin_rpc(&sid, env.sequence, &env.id, &request_bytes, now)?;
        if matches!(begin, Begin::Execute) {
            c.backend_running = true;
        }
        c.active_transports += 1;
        let expected_owner = c
            .owner
            .as_ref()
            .filter(|o| o.sid == sid)
            .map(|o| o.capability.clone());
        Ok((begin, ticket, expected_owner))
    })();
    let (begin, ticket, expected_owner) = match started {
        Ok(started) => started,
        Err(error) => {
            return send_untracked_result(
                &mut ws,
                &env.id,
                env.sequence,
                crate::protocol::response_for(Err(error), scope),
            );
        }
    };
    let cancel = Arc::new(AtomicBool::new(false));
    let mut guard = ActiveGuard {
        core: core.clone(),
        sid: sid.clone(),
        seq: env.sequence,
        id: env.id.clone(),
        ticket,
        cancel: cancel.clone(),
        permit: None,
        finished: false,
    };
    let deadline = Instant::now() + Duration::from_secs(55);
    let mut ping = Instant::now() + Duration::from_secs(5);
    let mut pong = Instant::now();
    let (tx, rx) = mpsc::sync_channel(1);
    let c = core.clone();
    let s = sid.clone();
    let request = env.request.clone();
    let seq = env.sequence;
    match &begin {
        Begin::Execute => {
            let handle = std::thread::spawn(move || {
                struct BackendSlot(Arc<Mutex<Core>>);
                impl Drop for BackendSlot {
                    fn drop(&mut self) {
                        if let Ok(mut core) = self.0.lock() {
                            core.backend_running = false;
                        }
                    }
                }
                let slot = BackendSlot(c.clone());
                let result = execute(&c, &s, request, seq, expected_owner.as_deref(), &cancel);
                drop(slot);
                let _ = tx.send(result);
            });
            backends
                .lock()
                .map_err(|_| fail("RECOVERY_REQUIRED"))?
                .push(handle);
        }
        Begin::Cached(value) => {
            let v = serde_json::from_slice::<Value>(value).map_err(|_| fail("PROTOCOL_ERROR"))?;
            tx.send(Ok(v)).map_err(|_| fail("REMOTE_DISCONNECTED"))?;
        }
    }
    let outcome = loop {
        if let Ok(result) = rx.try_recv() {
            break result;
        }
        let now = Instant::now();
        if STOP.load(Ordering::Acquire)
            || now >= deadline
            || now.duration_since(pong) >= Duration::from_secs(15)
        {
            return Err(fail("REMOTE_DISCONNECTED"));
        }
        if now >= ping {
            ws.get_mut()
                .inner_mut()
                .sock
                .set_deadline(deadline.min(now + Duration::from_secs(2)));
            ws.send(Message::Ping(Vec::new().into()))
                .map_err(|_| fail("REMOTE_DISCONNECTED"))?;
            ping = now + Duration::from_secs(5);
        }
        ws.get_mut().inner_mut().sock.set_deadline(
            deadline
                .min(ping)
                .min(pong + Duration::from_secs(15))
                .min(now + Duration::from_millis(100)),
        );
        match ws.read() {
            Ok(Message::Pong(_)) => {
                pong = Instant::now();
                let mut c = locked(&core)?;
                let now = c.now();
                c.manager.heartbeat_rpc(&sid, ticket, now)?;
            }
            Ok(Message::Ping(_)) => {
                ws.flush().map_err(|_| fail("REMOTE_DISCONNECTED"))?;
            }
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) => {}
            _ => return Err(fail("REMOTE_DISCONNECTED")),
        }
    };
    let mut response = match begin {
        Begin::Cached(_) => outcome?,
        Begin::Execute => crate::protocol::response_for(outcome, scope),
    };
    if action == "status" && response["ok"] == true {
        response["remoteHostState"] = json!(state_name(locked(&core)?.manager.state()));
    }
    let mut image = None;
    let mut image_bytes = None;
    if response["ok"] == true && matches!(action.as_str(), "connect" | "chrome-start") {
        let connection = response["connectionId"]
            .as_str()
            .ok_or_else(|| fail("PROTOCOL_ERROR"))?;
        let mut c = locked(&core)?;
        let now = c.now();
        c.manager.claim_control(&sid, connection, now)?;
        let owner = c
            .owner
            .as_mut()
            .filter(|o| o.sid == sid)
            .ok_or_else(|| fail("NOT_OWNER"))?;
        owner.initial_reservation = false;
    }
    let cached = matches!(begin, Begin::Cached(_));
    if response["ok"] == true && action == "click-target" {
        let connection = response["connectionId"]
            .as_str()
            .ok_or_else(|| fail("PROTOCOL_ERROR"))?;
        let frame = response["frameId"]
            .as_str()
            .ok_or_else(|| fail("PROTOCOL_ERROR"))?;
        let registration = {
            let mut c = locked(&core)?;
            register_result_frame(&mut c.manager, &sid, connection, frame, cached)
        };
        if let Err(error) = registration {
            response = cached_frame_failure(cached, scope, error)?;
        }
    }
    if response["ok"] == true && matches!(action.as_str(), "observe" | "frame") {
        let source = if action == "frame" {
            &env.request
        } else {
            &response
        };
        let connection = source["connectionId"]
            .as_str()
            .ok_or_else(|| fail("PROTOCOL_ERROR"))?;
        let frame = source["frameId"]
            .as_str()
            .ok_or_else(|| fail("PROTOCOL_ERROR"))?;
        let loaded = (|| -> Result<_> {
            {
                let mut c = locked(&core)?;
                if action == "observe" {
                    register_result_frame(&mut c.manager, &sid, connection, frame, cached)?;
                }
                c.manager.authorize_frame(&sid, connection, frame)?;
            }
            let runtime = Runtime::from_env_for_scope(scope)?;
            images::load_frame(&runtime.frames, &env.id, frame)
        })();
        match loaded {
            Ok((manifest, data)) => {
                image = Some(manifest);
                image_bytes = Some(data);
            }
            Err(error) => response = cached_frame_failure(cached, scope, error)?,
        }
    }
    if let Some(map) = response.as_object_mut() {
        map.remove("imagePath");
    }
    if matches!(begin, Begin::Execute) {
        let serialized = serde_json::to_vec(&response).map_err(|_| fail("PROTOCOL_ERROR"))?;
        let mut c = locked(&core)?;
        let now = c.now();
        c.manager
            .complete(&sid, env.sequence, &env.id, &serialized, now)?;
    }
    send(
        &mut ws,
        &ServerControl::Result {
            id: env.id.clone(),
            sequence: env.sequence,
            response: response.clone(),
            image,
        },
        deadline,
    )?;
    if let Some(data) = image_bytes {
        for part in data.chunks(crate::protocol::MAX_MESSAGE_BYTES) {
            ws.get_mut().inner_mut().sock.set_deadline(deadline);
            ws.send(Message::Binary(part.to_vec().into()))
                .map_err(|_| fail("REMOTE_DISCONNECTED"))?;
        }
    }
    let ack = wire::parse_client_control(&read_text(
        &mut ws,
        deadline.min(Instant::now() + Duration::from_secs(15)),
    )?)?;
    if !matches!(ack,ClientControl::Ack{id,sequence} if id==env.id && sequence==env.sequence) {
        return Err(fail("PROTOCOL_ERROR"));
    }
    let (permit, rollback) = {
        let mut c = locked(&core)?;
        let now = c.now();
        let permit = c
            .manager
            .ack_rpc(&sid, env.sequence, &env.id, ticket, now)?;
        let safe_failure = matches!(action.as_str(), "connect" | "chrome-start")
            && response["ok"] == false
            && matches!(
                response["error"]["code"].as_str(),
                Some(
                    "WINDOW_UNAVAILABLE"
                        | "CHROME_WINDOW_UNAVAILABLE"
                        | "INVALID_ARGUMENT"
                        | "SCREEN_PERMISSION_REQUIRED"
                        | "ACCESSIBILITY_PERMISSION_REQUIRED"
                        | "HELPER_UPGRADE_REQUIRED"
                        | "DAEMON_UPGRADE_REQUIRED"
                        | "BUSY"
                )
            );
        let rollback = if safe_failure && c.manager.state() == State::Ready && !c.transitioning {
            c.owner
                .as_ref()
                .filter(|o| {
                    o.sid == sid && o.initial_reservation && o.claim_state != ClaimState::Pending
                })
                .map(|o| (o.capability.clone(), o.claim_state))
        } else {
            None
        };
        if rollback.is_some() {
            c.transitioning = true;
        }
        (permit, rollback)
    };
    guard.permit = Some(permit);
    if let Some((cap, claim_state)) = rollback {
        // Gate new input while the backend independently proves a claimed lease
        // has no connection, native lease, or recovery lock. Do not hold the
        // Manager mutex while waiting for that daemon acknowledgement.
        let released = match claim_state {
            ClaimState::Rejected => true,
            ClaimState::Owned => Runtime::from_env_for_scope(scope)
                .and_then(|runtime| daemon::remote_release(&runtime, &cap))
                .is_ok_and(|v| v["released"] == true),
            ClaimState::Pending => false,
        };
        let mut c = locked(&core)?;
        let same_owner = c
            .owner
            .as_ref()
            .is_some_and(|o| o.sid == sid && o.capability == cap && o.claim_state == claim_state);
        if released
            && same_owner
            && c.manager
                .rollback_reservation(&sid, Some((env.sequence, &env.id)))
                .is_ok()
        {
            if c.write_journal(&Journal {
                clean: true,
                owner: cap,
                daemon_pid: None,
                helper_pid: None,
                scope,
            })
            .is_ok()
            {
                c.owner = None;
            } else {
                c.manager.require_recovery();
            }
        } else {
            c.manager.require_recovery();
        }
        c.transitioning = false;
    }
    if action == "disconnect" && response["ok"] == true {
        let cap = {
            let c = locked(&core)?;
            c.owner
                .as_ref()
                .filter(|o| o.sid == sid)
                .map(|o| o.capability.clone())
                .ok_or_else(|| fail("NOT_OWNER"))?
        };
        let runtime = Runtime::from_env_for_scope(scope)?;
        let released = daemon::remote_release(&runtime, &cap)?;
        if released["released"] != true {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        let mut c = locked(&core)?;
        c.manager
            .release_disconnected(&sid, env.sequence, &env.id)?;
        c.write_journal(&Journal {
            clean: true,
            owner: cap,
            daemon_pid: None,
            helper_pid: None,
            scope,
        })?;
        c.owner = None;
    }
    send(
        &mut ws,
        &ServerControl::Acked {
            id: env.id.clone(),
            sequence: env.sequence,
        },
        deadline,
    )?;
    ws.get_mut()
        .inner_mut()
        .sock
        .set_deadline(deadline.min(Instant::now() + Duration::from_secs(5)));
    match ws.read() {
        Ok(Message::Close(_)) => {
            let _ = ws.flush();
            let mut c = locked(&core)?;
            c.manager
                .normal_close(&sid, env.sequence, &env.id, permit)?;
            guard.finished = true;
            Ok(())
        }
        _ => Err(fail("REMOTE_DISCONNECTED")),
    }
}
/// Foreground Host. SIGINT/SIGTERM pause owned work before return.
pub fn run(options: HostOptions, scope: Scope) -> Result<Value> {
    let roots: Result<Vec<PathBuf>> = options
        .allowed_file_roots
        .iter()
        .map(|root| {
            if !root.is_absolute() {
                return Err(fail("INVALID_ARGUMENT"));
            }
            let root = root.canonicalize().map_err(|_| fail("INVALID_ARGUMENT"))?;
            if !root.is_dir() {
                return Err(fail("INVALID_ARGUMENT"));
            }
            Ok(root)
        })
        .collect();
    let roots = roots?;
    let tls = credentials::server_config(&options.tls_cert, &options.tls_key)?;
    let token = Arc::new(credentials::read_token(&options.token_file)?);
    let store = LockedStateDir::open(&state_path(options.state_dir.clone(), scope)?)
        .map_err(|_| fail("RECOVERY_REQUIRED"))?;
    let previous = read_journal(&store)?;
    let recovery = previous
        .as_ref()
        .is_some_and(|j| !j.clean || j.scope != scope);
    let boot = crate::protocol::random_id()?;
    let mut manager = SessionManager::new(&boot, recovery)?;
    manager.set_allow_files(!roots.is_empty())?;
    let core = Arc::new(Mutex::new(Core {
        manager,
        owner: None,
        journal: store,
        boot,
        scope,
        started: Instant::now(),
        requests: RequestBudget::new(),
        pause_proof: None,
        allowed_file_roots: roots,
        backend_running: false,
        transitioning: false,
        active_transports: 0,
    }));
    let listener = TcpListener::bind(options.listen).map_err(|_| fail("REMOTE_LISTEN_FAILED"))?;
    listener
        .set_nonblocking(true)
        .map_err(|_| fail("REMOTE_LISTEN_FAILED"))?;
    STOP.store(false, Ordering::Release);
    let mut signals = SignalRegistrations(Vec::new());
    for signal in [libc::SIGINT, libc::SIGTERM] {
        let id = unsafe {
            signal_hook::low_level::register(signal, || {
                STOP.store(true, Ordering::Release);
            })
        }
        .map_err(|_| fail("REMOTE_SIGNAL_FAILED"))?;
        signals.0.push(id);
    }
    let admission = Admission::new();
    let backends: BackendThreads = Arc::new(Mutex::new(Vec::new()));
    let mut workers = Vec::new();
    let mut listen_error = false;
    while !STOP.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((tcp, addr)) => {
                let now = locked(&core)?.now();
                let Ok(mut lease) = admission.enter(addr.ip(), now) else {
                    continue;
                };
                let tls = tls.clone();
                let token = token.clone();
                let core = core.clone();
                let backends = backends.clone();
                workers.push(std::thread::spawn(
                    move || match wire::accept_tls_authenticated(
                        tcp,
                        tls,
                        &token,
                        Duration::from_secs(5),
                    ) {
                        Ok(ws) => {
                            if lease.authenticate().is_ok() {
                                let _ = serve_connection(ws, core, backends);
                            }
                        }
                        Err(_) => {
                            let now = core.lock().map(|c| c.now()).unwrap_or(now);
                            let _ = lease.reject(now);
                        }
                    },
                ));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(20))
            }
            Err(_) => {
                listen_error = true;
                STOP.store(true, Ordering::Release);
                break;
            }
        }
        workers.retain(|w| !w.is_finished());
        if let Ok(mut threads) = backends.lock() {
            let mut index = 0;
            while index < threads.len() {
                if threads[index].is_finished() {
                    let _ = threads.swap_remove(index).join();
                } else {
                    index += 1;
                }
            }
        }
        let mut c = locked(&core)?;
        let now = c.now();
        if c.manager
            .expire(now)
            .is_ok_and(|e| e == Effect::PauseOwnedOperation)
        {
            let owner = c.owner.as_ref().map(|o| o.capability.clone());
            drop(c);
            if let Some(owner) = owner {
                if let Ok(runtime) = Runtime::from_env_for_scope(scope) {
                    let result = daemon::remote_pause(&runtime, &owner, None);
                    if let Ok(mut c) = core.lock() {
                        if result.as_ref().is_ok_and(|v| v["paused"] == true) {
                            c.pause_proof = result.as_ref().ok().and_then(PauseProof::from_receipt);
                            let _ = c.manager.acknowledge_pause();
                        }
                    }
                }
            }
        }
    }
    let owner = {
        let c = locked(&core)?;
        c.owner.as_ref().map(|o| o.capability.clone())
    };
    let pause_result = if let Some(owner) = owner {
        Runtime::from_env_for_scope(scope).and_then(|runtime| {
            let receipt = daemon::remote_pause(&runtime, &owner, None)?;
            if receipt["paused"] != true {
                return Err(fail("CANCEL_UNCONFIRMED"));
            }
            Ok(())
        })
    } else {
        Ok(())
    };
    for worker in workers {
        let _ = worker.join();
    }
    let until = Instant::now() + Duration::from_secs(60);
    loop {
        let mut threads = backends.lock().map_err(|_| fail("CANCEL_UNCONFIRMED"))?;
        let mut index = 0;
        while index < threads.len() {
            if threads[index].is_finished() {
                let _ = threads.swap_remove(index).join();
            } else {
                index += 1;
            }
        }
        if threads.is_empty() {
            break;
        }
        drop(threads);
        if Instant::now() >= until {
            return Err(fail("CANCEL_UNCONFIRMED"));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    pause_result?;
    if listen_error {
        return Err(fail("REMOTE_LISTEN_FAILED"));
    }
    Ok(json!({"stopped":true}))
}

#[cfg(test)]
mod host_tests {
    use super::*;
    #[cfg(target_os = "macos")]
    #[test]
    fn recovery_fixture_daemon() {
        if std::env::var_os("MCC_HOST_TEST_DAEMON").is_none() {
            return;
        }
        let runtime = Runtime::from_env_for_scope(Scope::Desktop).unwrap();
        daemon::run(&runtime).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn recovery_pending_claim_preserves_unrelated_owner() {
        use std::{
            os::unix::fs::DirBuilderExt,
            process::{Command, Stdio},
        };
        if std::env::var_os("MCC_HOST_TEST_CASE").is_none() {
            let result = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "remote::host::host_tests::recovery_pending_claim_preserves_unrelated_owner",
                    "--nocapture",
                ])
                .env("MCC_HOST_TEST_CASE", "1")
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
            return;
        }
        let root = PathBuf::from("/tmp")
            .join(format!("mcc-rec-{}", crate::protocol::random_id().unwrap()));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let runtime_path = root.join("run");
        std::env::set_var("COPIS_DESKTOP_RUNTIME_DIR", &runtime_path);
        std::env::set_var(
            "COPIS_DESKTOP_HELPER",
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-helper.sh"),
        );
        let runtime = Runtime::from_env_for_scope(Scope::Desktop).unwrap();
        let state = root.join("state");
        let pending = |owner: &str, pids: (Option<u32>, Option<u32>)| {
            let store = LockedStateDir::open(&state).unwrap();
            store
                .write(
                    "host.json",
                    &serde_json::to_vec(&Journal {
                        clean: false,
                        owner: owner.into(),
                        daemon_pid: pids.0,
                        helper_pid: pids.1,
                        scope: Scope::Desktop,
                    })
                    .unwrap(),
                )
                .unwrap();
        };
        let read = || {
            let store = LockedStateDir::open(&state).unwrap();
            read_journal(&store).unwrap().unwrap()
        };
        // Crash before claim: no daemon or helper is started by recover.
        pending("before-claim", (None, None));
        assert_eq!(
            recover(Some(state.clone()), Scope::Desktop).unwrap()["clean"],
            true
        );
        assert!(read().clean);
        assert!(!runtime_path.exists());
        // An unpublished but live daemon lock cannot be mistaken for absence.
        runtime.prepare().unwrap();
        let daemon_lock = runtime.lock().unwrap();
        pending("before-claim-locked", (None, None));
        assert!(recover(Some(state.clone()), Scope::Desktop).is_err());
        assert!(!read().clean);
        drop(daemon_lock);
        assert_eq!(
            recover(Some(state.clone()), Scope::Desktop).unwrap()["clean"],
            true
        );
        pending("malformed", (Some(123), None));
        assert!(recover(Some(state.clone()), Scope::Desktop).is_err());
        assert!(!read().clean);
        // A possibly dispatched owned record cannot be cleared while either
        // recorded process may still be alive, even with no daemon socket.
        pending(
            "owned-live-helper",
            (Some(i32::MAX as u32), Some(std::process::id())),
        );
        assert!(recover(Some(state.clone()), Scope::Desktop).is_err());
        assert!(!read().clean);

        struct DaemonChild(std::process::Child);
        impl Drop for DaemonChild {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut child = DaemonChild(
            Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "remote::host::host_tests::recovery_fixture_daemon",
                    "--nocapture",
                ])
                .env("MCC_HOST_TEST_DAEMON", "1")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let until = Instant::now() + Duration::from_secs(8);
        while !daemon::status(&runtime).is_ok_and(|s| s["running"] == true) {
            assert!(
                Instant::now() < until && child.0.try_wait().unwrap().is_none(),
                "fixture daemon did not start"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        // Claim reached daemon but crash preceded durable PID record.
        let owned = "pending-owned-capability";
        assert_eq!(
            daemon::remote_claim(&runtime, owned).unwrap()["owned"],
            true
        );
        pending(owned, (None, None));
        assert_eq!(
            recover(Some(state.clone()), Scope::Desktop).unwrap()["clean"],
            true
        );
        assert_eq!(
            daemon::remote_control_state(&runtime, owned)
                .unwrap_err()
                .code,
            "NOT_OWNER"
        );
        // A distinct owner must survive another pending record's local cleanup.
        let other = "unrelated-owner-capability";
        let claim = daemon::remote_claim(&runtime, other).unwrap();
        let before = daemon::remote_control_state(&runtime, other).unwrap();
        pending("not-the-owner", (None, None));
        assert_eq!(
            recover(Some(state.clone()), Scope::Desktop).unwrap()["clean"],
            true
        );
        assert_eq!(
            daemon::remote_control_state(&runtime, other).unwrap(),
            before
        );
        // An owned-stage record must never be cleared on NOT_OWNER.
        pending(
            "not-the-owner",
            (
                claim["daemonPid"].as_u64().map(|v| v as u32),
                claim["helperPid"].as_u64().map(|v| v as u32),
            ),
        );
        assert!(recover(Some(state.clone()), Scope::Desktop).is_err());
        assert!(!read().clean);
        assert_eq!(
            daemon::remote_control_state(&runtime, other).unwrap(),
            before
        );
        let daemon_pid = claim["daemonPid"].as_u64().unwrap() as u32;
        let helper_pid = claim["helperPid"].as_u64().unwrap() as u32;
        pending(other, (Some(daemon_pid), Some(helper_pid.wrapping_add(1))));
        assert!(recover(Some(state.clone()), Scope::Desktop).is_err());
        assert!(!read().clean);
        assert_eq!(
            daemon::remote_control_state(&runtime, other).unwrap(),
            before
        );
        pending(other, (Some(daemon_pid.wrapping_add(1)), Some(helper_pid)));
        assert!(recover(Some(state.clone()), Scope::Desktop).is_err());
        assert!(!read().clean);
        assert_eq!(
            daemon::remote_control_state(&runtime, other).unwrap(),
            before
        );
        pending(other, (Some(daemon_pid), Some(helper_pid)));
        assert_eq!(
            recover(Some(state.clone()), Scope::Desktop).unwrap()["clean"],
            true
        );
        assert_eq!(
            daemon::remote_control_state(&runtime, other)
                .unwrap_err()
                .code,
            "NOT_OWNER"
        );
        daemon::stop(&runtime).unwrap();
        let _ = child.0.wait();
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn expired_cached_frame_is_ackable_but_other_errors_are_not_masked() {
        for code in ["FRAME_NOT_FOUND", "REMOTE_IMAGE_INVALID"] {
            let response = cached_frame_failure(true, Scope::Desktop, fail(code)).unwrap();
            assert_eq!(response["ok"], false);
            assert_eq!(response["error"]["code"], "FRAME_NOT_FOUND");
            assert!(cached_frame_failure(false, Scope::Desktop, fail(code)).is_err());
        }
        assert_eq!(
            cached_frame_failure(true, Scope::Desktop, fail("NOT_OWNER"))
                .unwrap_err()
                .code,
            "NOT_OWNER"
        );
    }
    #[test]
    fn returned_frame_registration_is_owned_and_cached_replay_is_idempotent() {
        let mut manager = SessionManager::new("boot", false).unwrap();
        manager.issue("owner", Scope::Desktop, 0).unwrap();
        manager.issue("other", Scope::Desktop, 0).unwrap();
        manager.reserve_control("owner", 1).unwrap();
        manager.claim_control("owner", "conn", 2).unwrap();
        register_result_frame(&mut manager, "owner", "conn", "frame", false).unwrap();
        register_result_frame(&mut manager, "owner", "conn", "frame", true).unwrap();
        assert!(register_result_frame(&mut manager, "owner", "conn", "frame", false).is_err());
        assert!(register_result_frame(&mut manager, "other", "conn", "frame", true).is_err());
        assert!(register_result_frame(&mut manager, "owner", "conn", "missing", true).is_err());
    }
    #[test]
    fn file_policy_rejects_symlink_escape_and_accepts_contained_file() {
        use std::os::unix::fs::symlink;
        let base = std::env::temp_dir().join(format!(
            "mcc-host-policy-{}",
            crate::protocol::random_id().unwrap()
        ));
        std::fs::create_dir(&base).unwrap();
        let root = base.join("root");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("inside"), b"x").unwrap();
        std::fs::write(base.join("outside"), b"x").unwrap();
        symlink(base.join("outside"), root.join("escape")).unwrap();
        let roots = vec![root.canonicalize().unwrap()];
        assert!(allowed_file(&roots, &root.join("inside")).is_ok());
        assert!(allowed_file(&roots, &root.join("escape")).is_err());
        assert!(allowed_file(&[], &root.join("inside")).is_err());
        std::fs::remove_dir_all(base).unwrap();
    }
    #[test]
    fn resume_requires_same_non_null_lease_new_epoch_and_active_phase() {
        let proof = PauseProof {
            lease: 42,
            epoch: 7,
        };
        assert!(proof.matches(&json!({"lease":42,"inputEpoch":8,"paused":false,"recoveryRequired":false,"phase":"countdown"})));
        for state in [
            json!({"lease":43,"inputEpoch":8,"paused":false,"recoveryRequired":false,"phase":"running"}),
            json!({"lease":42,"inputEpoch":7,"paused":false,"recoveryRequired":false,"phase":"running"}),
            json!({"lease":42,"inputEpoch":8,"paused":false,"recoveryRequired":false,"phase":"awaitingCountdown"}),
            json!({"lease":42,"inputEpoch":8,"paused":false,"recoveryRequired":true,"phase":"running"}),
        ] {
            assert!(!proof.matches(&state));
        }
    }
}
