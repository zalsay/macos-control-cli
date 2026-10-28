//! In-memory fail-closed coordination only; effects must be enacted and acknowledged by the Host.
use crate::protocol::{Error, Result, Scope};
use crate::remote::protocol::valid_id;
use ring::digest::{digest, SHA256};
use std::collections::{HashMap, VecDeque};
use std::fmt;

const MAX_SESSIONS: usize = 64;
const MAX_CACHE: usize = 64;
const MAX_CACHE_BYTES: usize = 256 * 1024;
const MAX_RECEIPT: usize = crate::protocol::MAX_MESSAGE_BYTES;
const HEARTBEAT_MS: u64 = 15_000;
const IDLE_MS: u64 = 300_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Ready,
    LostPaused,
    CancellationUnconfirmed,
    RecoveryRequired,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Effect {
    None,
    PauseOwnedOperation,
}
#[derive(Clone, PartialEq, Eq)]
pub enum Begin {
    Execute,
    Cached(Vec<u8>),
}
impl fmt::Debug for Begin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Execute => f.write_str("Execute"),
            Self::Cached(_) => f.write_str("Cached([REDACTED])"),
        }
    }
}
struct Receipt {
    seq: u64,
    id: String,
    request_digest: [u8; 32],
    action: String,
    result: Vec<u8>,
    acknowledged: bool,
    lease_epoch: u64,
}
struct Session {
    scope: Scope,
    high: u64,
    cache: VecDeque<Receipt>,
    bytes: usize,
    last_activity: u64,
}
struct Flight {
    session: String,
    seq: u64,
    id: String,
    request_digest: [u8; 32],
    action: String,
    completed: bool,
    last_seen: u64,
    may_deliver: bool,
    lease_epoch: u64,
    ticket: u64,
}
/// Credentials and all request/receipt data are intentionally absent from Debug output.
pub struct SessionManager {
    boot: String,
    allow_files: bool,
    clock: Option<u64>,
    state: State,
    sessions: HashMap<String, Session>,
    owner: Option<String>,
    reservation_high: Option<u64>,
    lease_epoch: u64,
    connection: Option<String>,
    frames: VecDeque<String>,
    flight: Option<Flight>,
    next_rpc: u64,
    next_close: u64,
    closes: HashMap<u64, (String, u64, String)>,
}
impl fmt::Debug for SessionManager {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionManager")
            .field("state", &self.state)
            .field("sessions", &self.sessions.len())
            .field("owner", &self.owner.as_ref().map(|_| "[REDACTED]"))
            .field("flight", &self.flight.as_ref().map(|_| "[REDACTED]"))
            .finish()
    }
}
fn fail(code: &str) -> Error {
    Error::new(code, "远程会话操作被拒绝")
}
impl SessionManager {
    /// `recovery_required` comes from the Host's durable local recovery record.
    pub fn new(boot: &str, recovery_required: bool) -> Result<Self> {
        if !valid_id(boot) {
            return Err(fail("INVALID_ARGUMENT"));
        }
        Ok(Self {
            boot: boot.into(),
            allow_files: false,
            clock: None,
            state: if recovery_required {
                State::RecoveryRequired
            } else {
                State::Ready
            },
            sessions: HashMap::new(),
            owner: None,
            reservation_high: None,
            lease_epoch: 0,
            connection: None,
            frames: VecDeque::new(),
            flight: None,
            next_rpc: 1,
            next_close: 1,
            closes: HashMap::new(),
        })
    }
    fn check_time(&mut self, now: u64) -> Result<()> {
        if self.clock.is_some_and(|previous| now < previous) {
            return Err(fail("INVALID_TIME"));
        }
        self.clock = Some(now);
        Ok(())
    }
    /// Immutable once any session exists; only trusted Host initialization sets it.
    pub fn set_allow_files(&mut self, allow: bool) -> Result<()> {
        if !self.sessions.is_empty() || self.owner.is_some() || self.flight.is_some() {
            return Err(fail("INVALID_STATE"));
        }
        self.allow_files = allow;
        Ok(())
    }
    pub fn state(&self) -> State {
        self.state
    }
    /// Host generates a unique cryptographically random credential after authentication.
    pub fn issue(&mut self, credential: &str, scope: Scope, now: u64) -> Result<()> {
        self.check_time(now)?;
        if !valid_id(credential)
            || self.sessions.len() >= MAX_SESSIONS
            || self.sessions.contains_key(credential)
        {
            return Err(fail("INVALID_ARGUMENT"));
        }
        self.sessions.insert(
            credential.into(),
            Session {
                scope,
                high: 0,
                cache: VecDeque::new(),
                bytes: 0,
                last_activity: now,
            },
        );
        Ok(())
    }
    pub fn authorize(&self, credential: &str, boot: &str, scope: Scope) -> Result<()> {
        let s = self
            .sessions
            .get(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        if boot != self.boot || s.scope != scope {
            return Err(fail("SESSION_INVALID"));
        }
        Ok(())
    }
    /// Reserve the sole control owner before dispatching connect or chrome-start.
    pub fn reserve_control(&mut self, credential: &str, now: u64) -> Result<()> {
        self.check_time(now)?;
        if self.state != State::Ready {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        if self
            .owner
            .as_deref()
            .is_some_and(|owner| owner != credential)
        {
            return Err(fail("BUSY"));
        }
        let session = self
            .sessions
            .get_mut(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        if now < session.last_activity {
            return Err(fail("INVALID_TIME"));
        }
        session.last_activity = now;
        if self.owner.is_none() {
            self.reservation_high = Some(session.high);
            self.lease_epoch = self
                .lease_epoch
                .checked_add(1)
                .ok_or_else(|| fail("RECOVERY_REQUIRED"))?;
        }
        self.owner = Some(credential.into());
        Ok(())
    }
    pub fn claim_control(&mut self, credential: &str, connection: &str, now: u64) -> Result<()> {
        self.check_time(now)?;
        if self.state != State::Ready || !valid_id(connection) {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        if self
            .owner
            .as_deref()
            .is_some_and(|owner| owner != credential)
            || self
                .connection
                .as_deref()
                .is_some_and(|id| id != connection)
        {
            return Err(fail("BUSY"));
        }
        let s = self
            .sessions
            .get_mut(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        s.last_activity = now;
        if self.owner.is_none() {
            self.lease_epoch = self
                .lease_epoch
                .checked_add(1)
                .ok_or_else(|| fail("RECOVERY_REQUIRED"))?;
        }
        self.owner = Some(credential.into());
        self.connection = Some(connection.into());
        self.reservation_high = None;
        Ok(())
    }
    /// Host confirms reservation was rejected before dispatch or a matching connect failed.
    pub fn rollback_reservation(
        &mut self,
        credential: &str,
        failure: Option<(u64, &str)>,
    ) -> Result<()> {
        if self.state != State::Ready
            || self.owner.as_deref() != Some(credential)
            || self.connection.is_some()
            || self.flight.is_some()
        {
            return Err(fail("INVALID_STATE"));
        }
        let s = self
            .sessions
            .get(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        let base = self.reservation_high.ok_or_else(|| fail("INVALID_STATE"))?;
        match failure {
            None if s.high == base => (),
            Some((seq, id))
                if seq == s.high
                    && seq > base
                    && s.cache.iter().any(|r| {
                        r.seq == seq
                            && r.id == id
                            && r.lease_epoch == self.lease_epoch
                            && r.acknowledged
                            && matches!(r.action.as_str(), "connect" | "chrome-start")
                            && serde_json::from_slice::<serde_json::Value>(&r.result)
                                .ok()
                                .is_some_and(|v| v["ok"] == false)
                    }) => {}
            _ => return Err(fail("INVALID_STATE")),
        }
        self.owner = None;
        self.reservation_high = None;
        Ok(())
    }
    /// Host calls only after the original disconnect has succeeded and its receipt was ACKed.
    pub fn release_disconnected(&mut self, credential: &str, seq: u64, id: &str) -> Result<()> {
        if self.state != State::Ready
            || self.owner.as_deref() != Some(credential)
            || self.flight.is_some()
        {
            return Err(fail("INVALID_STATE"));
        }
        let s = self
            .sessions
            .get(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        if !s.cache.iter().any(|r| {
            r.seq == seq
                && r.id == id
                && r.action == "disconnect"
                && r.lease_epoch == self.lease_epoch
                && r.acknowledged
                && serde_json::from_slice::<serde_json::Value>(&r.result)
                    .ok()
                    .is_some_and(|v| v["ok"] == true && v["connected"] == false)
        }) {
            return Err(fail("INVALID_STATE"));
        }
        self.owner = None;
        self.connection = None;
        self.frames.clear();
        self.reservation_high = None;
        Ok(())
    }
    pub fn authorize_connection(&self, credential: &str, connection: &str) -> Result<()> {
        if self.owner.as_deref() != Some(credential)
            || self.connection.as_deref() != Some(connection)
            || !self.sessions.contains_key(credential)
        {
            return Err(fail("NOT_OWNER"));
        }
        Ok(())
    }
    pub fn register_frame(
        &mut self,
        credential: &str,
        connection: &str,
        frame: &str,
    ) -> Result<()> {
        self.authorize_connection(credential, connection)?;
        if !valid_id(frame) {
            return Err(fail("INVALID_ARGUMENT"));
        }
        if self.frames.iter().any(|x| x == frame) {
            return Err(fail("INVALID_ARGUMENT"));
        }
        if self.frames.len() == 32 {
            self.frames.pop_front();
        }
        self.frames.push_back(frame.into());
        Ok(())
    }
    pub fn authorize_frame(&self, credential: &str, connection: &str, frame: &str) -> Result<()> {
        self.authorize_connection(credential, connection)?;
        if !self.frames.iter().any(|x| x == frame) {
            return Err(fail("FRAME_NOT_FOUND"));
        }
        Ok(())
    }
    /// Allocate a per-WS ticket; Host retains it on that socket, never accepts it from a peer.
    pub fn begin_rpc(
        &mut self,
        credential: &str,
        seq: u64,
        id: &str,
        request: &[u8],
        now: u64,
    ) -> Result<(Begin, u64)> {
        let ticket = self.next_rpc;
        let next = ticket
            .checked_add(1)
            .ok_or_else(|| fail("RECOVERY_REQUIRED"))?;
        let result = self.begin_inner(credential, seq, id, request, now)?;
        self.flight.as_mut().expect("begin installs flight").ticket = ticket;
        self.next_rpc = next;
        Ok((result, ticket))
    }
    fn begin_inner(
        &mut self,
        credential: &str,
        seq: u64,
        id: &str,
        request: &[u8],
        now: u64,
    ) -> Result<Begin> {
        self.check_time(now)?;
        if !matches!(self.state, State::Ready | State::LostPaused) {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        if self.flight.is_some() {
            return Err(fail("BUSY"));
        }
        if seq == 0 || !valid_id(id) || request.len() > crate::protocol::MAX_MESSAGE_BYTES {
            return Err(fail("INVALID_ARGUMENT"));
        }
        let scope = self
            .sessions
            .get(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?
            .scope;
        let parsed: serde_json::Value =
            serde_json::from_slice(request).map_err(|_| fail("INVALID_ARGUMENT"))?;
        crate::remote::protocol::validate_action_with_files(scope, &parsed, self.allow_files)?;
        let action = parsed["action"]
            .as_str()
            .ok_or_else(|| fail("INVALID_ARGUMENT"))?;
        let may_deliver = !matches!(
            action,
            "status" | "apps" | "windows" | "permissions" | "session" | "frame" | "observe"
        );
        if self.state == State::LostPaused
            && (may_deliver || self.owner.as_deref() != Some(credential))
        {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        if may_deliver && self.owner.as_deref() != Some(credential) {
            return Err(fail("NOT_OWNER"));
        }
        if let Some(connection) = parsed
            .get("connectionId")
            .and_then(serde_json::Value::as_str)
        {
            self.authorize_connection(credential, connection)?;
            if let Some(frame) = parsed.get("frameId").and_then(serde_json::Value::as_str) {
                self.authorize_frame(credential, connection, frame)?;
            }
        }
        let s = self
            .sessions
            .get_mut(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        if now < s.last_activity {
            return Err(fail("INVALID_TIME"));
        }
        if seq <= s.high {
            let r = s
                .cache
                .iter()
                .find(|r| r.seq == seq)
                .ok_or_else(|| fail("STALE_SEQUENCE"))?;
            if r.id != id || r.request_digest != request_digest(request) {
                return Err(fail("REPLAY_MISMATCH"));
            }
            let result = r.result.clone();
            self.flight = Some(Flight {
                session: credential.into(),
                seq,
                id: id.into(),
                request_digest: request_digest(request),
                action: action.into(),
                completed: true,
                last_seen: now,
                may_deliver,
                lease_epoch: self.lease_epoch,
                ticket: 0,
            });
            return Ok(Begin::Cached(result));
        }
        if s.cache.iter().any(|r| r.id == id) {
            return Err(fail("REPLAY_MISMATCH"));
        }
        s.high = seq;
        s.last_activity = now;
        self.flight = Some(Flight {
            session: credential.into(),
            seq,
            id: id.into(),
            request_digest: request_digest(request),
            action: action.into(),
            completed: false,
            last_seen: now,
            may_deliver,
            lease_epoch: self.lease_epoch,
            ticket: 0,
        });
        Ok(Begin::Execute)
    }
    /// Read a retained receipt without executing, changing the sequence, or taking a flight.
    pub fn query_cached(
        &self,
        credential: &str,
        seq: u64,
        id: &str,
        request: &[u8],
    ) -> Result<Vec<u8>> {
        if request.len() > crate::protocol::MAX_MESSAGE_BYTES {
            return Err(fail("MESSAGE_TOO_LARGE"));
        }
        let s = self
            .sessions
            .get(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        let receipt = s
            .cache
            .iter()
            .find(|r| r.seq == seq && r.id == id && r.request_digest == request_digest(request))
            .ok_or_else(|| fail("STALE_SEQUENCE"))?;
        Ok(receipt.result.clone())
    }
    pub fn complete(
        &mut self,
        credential: &str,
        seq: u64,
        id: &str,
        result: &[u8],
        now: u64,
    ) -> Result<()> {
        self.check_time(now)?;
        let allow_paused = self.state == State::LostPaused
            && self.owner.as_deref() == Some(credential)
            && self
                .flight
                .as_ref()
                .is_some_and(|f| !f.may_deliver && f.session == credential);
        if self.state != State::Ready && !allow_paused {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        let f = self.flight.as_mut().ok_or_else(|| fail("NO_REQUEST"))?;
        if f.session != credential || f.seq != seq || f.id != id || f.completed || now < f.last_seen
        {
            return Err(fail("NO_REQUEST"));
        }
        if result.len() >= MAX_RECEIPT {
            return Err(fail("MESSAGE_TOO_LARGE"));
        }
        let value: serde_json::Value =
            serde_json::from_slice(result).map_err(|_| fail("INVALID_ARGUMENT"))?;
        let projected = project_receipt(&f.action, &value)?;
        let projected = serde_json::to_vec(&projected).map_err(|_| fail("INVALID_ARGUMENT"))?;
        let s = self
            .sessions
            .get_mut(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        let size = 32 + projected.len();
        while s.cache.len() >= MAX_CACHE || s.bytes + size > MAX_CACHE_BYTES {
            if let Some(old) = s.cache.pop_front() {
                s.bytes -= 32 + old.result.len();
            } else {
                break;
            }
        }
        s.cache.push_back(Receipt {
            seq,
            id: id.into(),
            request_digest: f.request_digest,
            action: f.action.clone(),
            result: projected,
            acknowledged: false,
            lease_epoch: f.lease_epoch,
        });
        s.bytes += size;
        s.last_activity = now;
        f.completed = true;
        f.last_seen = now;
        Ok(())
    }
    /// ACK belongs to one exact Host-tracked WebSocket invocation, including cache retries.
    pub fn ack_rpc(
        &mut self,
        credential: &str,
        seq: u64,
        id: &str,
        ticket: u64,
        now: u64,
    ) -> Result<u64> {
        self.check_time(now)?;
        if self.flight.as_ref().is_none_or(|f| {
            f.ticket != ticket || f.session != credential || f.seq != seq || f.id != id
        }) {
            return Err(fail("NO_REQUEST"));
        }
        self.ack_inner(credential, seq, id, now)
    }
    /// A stale WS loss must not pause or cancel a newer flight.
    pub fn lost_rpc(
        &mut self,
        credential: &str,
        seq: u64,
        id: &str,
        ticket: u64,
        now: u64,
    ) -> Result<Effect> {
        self.check_time(now)?;
        if self.flight.as_ref().is_none_or(|f| {
            f.ticket != ticket || f.session != credential || f.seq != seq || f.id != id
        }) {
            return Err(fail("NO_REQUEST"));
        }
        self.lost(credential, now)
    }
    fn ack_inner(&mut self, credential: &str, seq: u64, id: &str, now: u64) -> Result<u64> {
        self.check_time(now)?;
        let allow_paused = self.state == State::LostPaused
            && self.owner.as_deref() == Some(credential)
            && self
                .flight
                .as_ref()
                .is_some_and(|f| !f.may_deliver && f.session == credential);
        if self.state != State::Ready && !allow_paused {
            return Err(fail("RECOVERY_REQUIRED"));
        }
        let f = self.flight.as_ref().ok_or_else(|| fail("NO_REQUEST"))?;
        if f.session != credential
            || f.seq != seq
            || f.id != id
            || !f.completed
            || now < f.last_seen
        {
            return Err(fail("NO_REQUEST"));
        }
        self.sessions
            .get_mut(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?
            .last_activity = now;
        if self.closes.len() >= MAX_CACHE {
            return Err(fail("BUSY"));
        }
        let permit = self.next_close;
        self.next_close = self
            .next_close
            .checked_add(1)
            .ok_or_else(|| fail("RECOVERY_REQUIRED"))?;
        self.sessions
            .get_mut(credential)
            .and_then(|s| s.cache.iter_mut().find(|r| r.seq == seq && r.id == id))
            .ok_or_else(|| fail("NO_REQUEST"))?
            .acknowledged = true;
        self.closes
            .insert(permit, (credential.into(), seq, id.into()));
        self.flight = None;
        Ok(permit)
    }
    /// Host supplies the per-socket ticket; a stale heartbeat cannot prolong another RPC.
    pub fn heartbeat_rpc(&mut self, credential: &str, ticket: u64, now: u64) -> Result<()> {
        self.check_time(now)?;
        let f = self.flight.as_mut().ok_or_else(|| fail("NO_REQUEST"))?;
        if f.session != credential || f.ticket != ticket || now < f.last_seen {
            return Err(fail("NO_REQUEST"));
        }
        f.last_seen = now;
        Ok(())
    }
    /// Only a normal close after matching completion ACK may preserve the lease.
    pub fn normal_close(
        &mut self,
        credential: &str,
        seq: u64,
        id: &str,
        permit: u64,
    ) -> Result<()> {
        if self
            .closes
            .get(&permit)
            .is_none_or(|entry| entry.0 != credential || entry.1 != seq || entry.2 != id)
        {
            return Err(fail("ACK_REQUIRED"));
        }
        self.closes.remove(&permit);
        Ok(())
    }
    /// Consume an ACKed socket's close permit on abnormal termination. An old socket
    /// must never cancel or release a newer in-flight invocation.
    pub fn abandon_acked_transport(
        &mut self,
        credential: &str,
        seq: u64,
        id: &str,
        permit: u64,
        now: u64,
    ) -> Result<Effect> {
        self.check_time(now)?;
        if self
            .closes
            .get(&permit)
            .is_none_or(|entry| entry.0 != credential || entry.1 != seq || entry.2 != id)
        {
            return Err(fail("ACK_REQUIRED"));
        }
        self.closes.remove(&permit);
        if self.state != State::Ready
            || self.flight.is_some()
            || self.owner.as_deref() != Some(credential)
        {
            return Ok(Effect::None);
        }
        self.lost(credential, now)
    }
    pub fn lost(&mut self, credential: &str, now: u64) -> Result<Effect> {
        self.check_time(now)?;
        let s = self
            .sessions
            .get(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        if now < s.last_activity {
            return Err(fail("INVALID_TIME"));
        }
        if self.state == State::LostPaused
            && self.owner.as_deref() == Some(credential)
            && self
                .flight
                .as_ref()
                .is_some_and(|f| f.session == credential && !f.may_deliver)
        {
            self.flight = None;
            return Ok(Effect::None);
        }
        let active = self
            .flight
            .as_ref()
            .is_some_and(|f| f.session == credential && f.may_deliver);
        if self.owner.as_deref() == Some(credential) || active {
            self.state = State::CancellationUnconfirmed;
            Ok(Effect::PauseOwnedOperation)
        } else {
            if self
                .flight
                .as_ref()
                .is_some_and(|f| f.session == credential)
            {
                self.flight = None;
            }
            self.sessions.remove(credential);
            Ok(Effect::None)
        }
    }
    pub fn expire(&mut self, now: u64) -> Result<Effect> {
        self.check_time(now)?;
        let owner = self.owner.as_deref();
        let active = self.flight.as_ref().map(|f| f.session.as_str());
        self.sessions.retain(|id, s| {
            Some(id.as_str()) == owner
                || Some(id.as_str()) == active
                || now - s.last_activity < IDLE_MS
        });
        self.closes
            .retain(|_, (id, _, _)| self.sessions.contains_key(id));
        if self.state != State::Ready {
            return Ok(Effect::None);
        }
        if let Some(f) = &self.flight {
            if now < f.last_seen {
                return Err(fail("INVALID_TIME"));
            }
            if now - f.last_seen >= HEARTBEAT_MS {
                let id = f.session.clone();
                return self.lost(&id, now);
            }
        }
        if let Some(owner) = &self.owner {
            let id = owner.clone();
            let last = self
                .sessions
                .get(&id)
                .ok_or_else(|| fail("SESSION_INVALID"))?
                .last_activity;
            if now < last {
                return Err(fail("INVALID_TIME"));
            }
            if now - last >= IDLE_MS {
                return self.lost(&id, now);
            }
        }
        Ok(Effect::None)
    }
    /// Host invokes only after native cancellation and pause ACK; not a network action.
    pub fn acknowledge_pause(&mut self) -> Result<()> {
        if self.state != State::CancellationUnconfirmed {
            return Err(fail("INVALID_STATE"));
        }
        self.flight = None;
        self.state = State::LostPaused;
        Ok(())
    }
    /// Only the local Host recovery path may call this after independently verifying safety.
    pub fn acknowledge_local_resume(&mut self, credential: &str, now: u64) -> Result<()> {
        self.check_time(now)?;
        if self.state != State::LostPaused || self.owner.as_deref() != Some(credential) {
            return Err(fail("INVALID_STATE"));
        }
        let session = self
            .sessions
            .get_mut(credential)
            .ok_or_else(|| fail("SESSION_INVALID"))?;
        if now < session.last_activity {
            return Err(fail("INVALID_TIME"));
        }
        session.last_activity = now;
        self.flight = None;
        self.state = State::Ready;
        Ok(())
    }
    /// Explicit Host-local cleanup only after restart recovery is externally verified.
    pub fn acknowledge_local_recovery_cleanup(&mut self) -> Result<()> {
        if self.state != State::RecoveryRequired {
            return Err(fail("INVALID_STATE"));
        }
        self.sessions.clear();
        self.owner = None;
        self.reservation_high = None;
        self.connection = None;
        self.frames.clear();
        self.flight = None;
        self.closes.clear();
        self.state = State::Ready;
        Ok(())
    }
    pub fn require_recovery(&mut self) {
        self.state = State::RecoveryRequired;
    }
}
fn request_digest(request: &[u8]) -> [u8; 32] {
    digest(&SHA256, request)
        .as_ref()
        .try_into()
        .expect("SHA256 length")
}
// Only explicitly documented scalar fields are cached. Selection text is page data and
// may itself be sensitive; no claim is made that page text is secret-free.
fn project_receipt(action: &str, value: &serde_json::Value) -> Result<serde_json::Value> {
    use serde_json::{Map, Value};
    fn valid(name: &str, v: &Value) -> bool {
        match name {
            "ok" | "running" | "connected" | "sent" | "effectVerified" | "untrusted"
            | "truncated" | "created" | "selected" | "dialogClosed" | "screenRecording"
            | "accessibility" | "requested" | "granted" | "dynamicEndpoint" => v.is_boolean(),
            "protocolVersion" | "width" | "height" | "capturedAtMs" | "confidence"
            | "probability" | "x" | "y" | "windowId" | "pid" | "widthPx" | "heightPx" | "scale"
            | "maxWidthPx" | "availableWidthPx" | "availableHeightPx" | "osStatus" | "observe"
            | "decision" | "click" | "total" => v.is_number(),
            "connectionId" | "frameId" | "candidateId" | "code" | "reason" => {
                v.as_str().is_some_and(valid_id)
            }
            "scope" => matches!(v.as_str(), Some("chrome" | "desktop")),
            "status" => matches!(
                v.as_str(),
                Some(
                    "click_sent"
                        | "ok"
                        | "unavailable"
                        | "granted"
                        | "requires_consent"
                        | "denied"
                        | "target_not_running"
                        | "unverified"
                )
            ),
            "coordinateSpace" => v.as_str() == Some("frame-pixels"),
            "imageTransform" => v.as_str() == Some("crop-only"),
            "captureBackend" => matches!(v.as_str(), Some("screencapture" | "screen-capture-kit")),
            "target" => v.as_str() == Some("com.google.Chrome"),
            "title" | "appName" | "name" | "bundleId" | "model" | "requestedModel" | "protocol" => {
                v.as_str().is_some_and(|s| s.len() < MAX_RECEIPT)
            }
            "directory" | "path" => v.as_str().is_some_and(|s| {
                !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control)
            }),
            "version" => v.as_str().is_some_and(|s| {
                !s.is_empty()
                    && s.len() <= 32
                    && s.bytes().all(|b| b.is_ascii_digit() || b".-+".contains(&b))
            }),
            "text" => v.as_str().is_some_and(|s| s.len() <= 4096),
            _ => false,
        }
    }
    fn fields(
        src: &Map<String, Value>,
        names: &[&str],
        required: &[&str],
    ) -> Result<Map<String, Value>> {
        let mut out = Map::new();
        for name in required {
            if !src.contains_key(*name) {
                return Err(fail("INVALID_ARGUMENT"));
            }
        }
        for name in names {
            if let Some(value) = src.get(*name) {
                if !valid(name, value) {
                    return Err(fail("INVALID_ARGUMENT"));
                }
                out.insert((*name).into(), value.clone());
            }
        }
        Ok(out)
    }
    fn obj(
        src: &Map<String, Value>,
        key: &str,
        names: &[&str],
        required: &[&str],
    ) -> Result<Option<Value>> {
        match src.get(key) {
            None => Ok(None),
            Some(v) => Ok(Some(Value::Object(fields(
                v.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?,
                names,
                required,
            )?))),
        }
    }
    fn bounds(src: &Map<String, Value>, key: &str) -> Result<Option<Value>> {
        obj(
            src,
            key,
            &["x", "y", "width", "height"],
            &["x", "y", "width", "height"],
        )
    }
    fn window(v: &Value) -> Result<Value> {
        let src = v.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
        let mut out = fields(
            src,
            &["windowId", "pid", "title", "bundleId", "appName"],
            &["windowId", "pid", "title"],
        )?;
        out.insert(
            "bounds".into(),
            bounds(src, "bounds")?.ok_or_else(|| fail("INVALID_ARGUMENT"))?,
        );
        Ok(Value::Object(out))
    }
    let source = value.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
    let mut out = fields(source, &["ok", "protocolVersion", "scope"], &[])?;
    let action_fields: &[&str] = match action {
        "click" | "scroll" | "type" | "press" => &["sent", "connectionId", "frameId"],
        "click-target" => &[
            "sent",
            "status",
            "connectionId",
            "frameId",
            "effectVerified",
            "untrusted",
        ],
        "connect" | "chrome-start" => &["connectionId", "connected", "created"],
        "observe" => &[
            "connectionId",
            "frameId",
            "width",
            "height",
            "capturedAtMs",
            "untrusted",
            "coordinateSpace",
            "imageTransform",
            "captureBackend",
        ],
        "disconnect" => &["connected"],
        "select-file" => &["selected", "dialogClosed", "connectionId"],
        "status" => &["running", "connected", "version"],
        "permissions" => &["screenRecording", "accessibility"],
        "apps" | "windows" | "session" | "frame" => &[],
        _ => return Err(fail("INVALID_ARGUMENT")),
    };
    out.extend(fields(source, action_fields, &[])?);
    if matches!(action, "connect" | "chrome-start" | "status") {
        if let Some(v) = source.get("window") {
            if v.is_null() && action == "status" {
                out.insert("window".into(), Value::Null);
            } else {
                out.insert("window".into(), window(v)?);
            }
        }
    }
    if matches!(action, "windows" | "apps") {
        let name = if action == "windows" {
            "windows"
        } else {
            "apps"
        };
        if let Some(v) = source.get(name) {
            let items = v.as_array().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
            let projected: Result<Vec<Value>> = items
                .iter()
                .map(|item| {
                    if action == "windows" {
                        window(item)
                    } else {
                        Ok(Value::Object(fields(
                            item.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?,
                            &["pid", "bundleId", "name"],
                            &["pid", "bundleId", "name"],
                        )?))
                    }
                })
                .collect();
            out.insert(name.into(), Value::Array(projected?));
        }
    }
    if matches!(action, "connect" | "chrome-start") {
        if let Some(value) = source.get("permissions") {
            let permissions = value.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
            let mut projected = fields(
                permissions,
                &["screenRecording", "accessibility"],
                &["screenRecording", "accessibility"],
            )?;
            if let Some(v) = obj(
                permissions,
                "chromeAutomation",
                &["target", "requested", "granted", "status", "osStatus"],
                &["target", "requested", "granted", "status", "osStatus"],
            )? {
                projected.insert("chromeAutomation".into(), v);
            }
            out.insert("permissions".into(), Value::Object(projected));
        }
    }
    if action == "chrome-start" {
        if let Some(profile) = obj(
            source,
            "profile",
            &["name", "directory", "path"],
            &["name", "directory", "path"],
        )? {
            out.insert("profile".into(), profile);
        }
        if let Some(v) = source.get("layout") {
            let src = v.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
            let mut layout = fields(
                src,
                &[
                    "widthPx",
                    "heightPx",
                    "scale",
                    "maxWidthPx",
                    "availableWidthPx",
                    "availableHeightPx",
                ],
                &[],
            )?;
            if let Some(v) = bounds(src, "bounds")? {
                layout.insert("bounds".into(), v);
            }
            if layout.is_empty() {
                return Err(fail("INVALID_ARGUMENT"));
            }
            out.insert("layout".into(), Value::Object(layout));
        }
    }
    if action == "permissions" {
        if let Some(v) = obj(
            source,
            "chromeAutomation",
            &["target", "requested", "granted", "status", "osStatus"],
            &["target", "requested", "granted", "status", "osStatus"],
        )? {
            out.insert("chromeAutomation".into(), v);
        }
    }
    if action == "status" {
        if let Some(v) = obj(
            source,
            "jev",
            &["protocol", "dynamicEndpoint"],
            &["protocol", "dynamicEndpoint"],
        )? {
            out.insert("jev".into(), v);
        }
    }
    if matches!(action, "click" | "scroll" | "click-target") {
        if let Some(v) = obj(source, "screenPoint", &["x", "y"], &["x", "y"])? {
            out.insert("screenPoint".into(), v);
        }
    }
    if action == "click-target" {
        if let Some(v) = obj(
            source,
            "timingMs",
            &["observe", "decision", "click", "total"],
            &["observe", "decision", "click", "total"],
        )? {
            out.insert("timingMs".into(), v);
        }
        if let Some(v) = source.get("selection") {
            let src = v.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
            let mut selected = fields(
                src,
                &[
                    "candidateId",
                    "text",
                    "model",
                    "requestedModel",
                    "confidence",
                    "probability",
                ],
                &["candidateId", "text"],
            )?;
            if let Some(v) = obj(src, "center", &["x", "y"], &["x", "y"])? {
                selected.insert("center".into(), v);
            }
            out.insert("selection".into(), Value::Object(selected));
        }
    }
    if action == "observe" {
        if let Some(v) = bounds(source, "bounds")? {
            out.insert("bounds".into(), v);
        }
        if let Some(v) = source.get("ocr") {
            let src = v.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
            let mut ocr = fields(src, &["status", "truncated"], &["status", "truncated"])?;
            let items = src
                .get("items")
                .and_then(Value::as_array)
                .ok_or_else(|| fail("INVALID_ARGUMENT"))?;
            if items.len() > 128 {
                return Err(fail("INVALID_ARGUMENT"));
            }
            let projected: Result<Vec<Value>> = items
                .iter()
                .map(|v| {
                    let item = v.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
                    let mut clean = fields(item, &["text", "confidence"], &["text", "confidence"])?;
                    clean.insert(
                        "bbox".into(),
                        bounds(item, "bbox")?.ok_or_else(|| fail("INVALID_ARGUMENT"))?,
                    );
                    clean.insert(
                        "center".into(),
                        obj(item, "center", &["x", "y"], &["x", "y"])?
                            .ok_or_else(|| fail("INVALID_ARGUMENT"))?,
                    );
                    Ok(Value::Object(clean))
                })
                .collect();
            ocr.insert("items".into(), Value::Array(projected?));
            out.insert("ocr".into(), Value::Object(ocr));
        }
    }
    if let Some(v) = source.get("error") {
        let src = v.as_object().ok_or_else(|| fail("INVALID_ARGUMENT"))?;
        let mut error = fields(src, &["code", "reason"], &["code"])?;
        let message = src
            .get("message")
            .and_then(Value::as_str)
            .ok_or_else(|| fail("INVALID_ARGUMENT"))?;
        // Only the already-public paused message is retained verbatim. All other
        // potentially dynamic transport/helper diagnostics are replaced by fixed copy.
        let controlled = if message == crate::protocol::USER_PAUSED_PUBLIC_MESSAGE {
            message
        } else {
            "远程操作失败，请查看错误代码"
        };
        error.insert("message".into(), Value::String(controlled.into()));
        out.insert("error".into(), Value::Object(error));
    }
    Ok(Value::Object(out))
}
