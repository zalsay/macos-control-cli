//! WSS control frames. This module does not authenticate the peer or perform I/O.
use crate::protocol::{Error, Result, Scope, MAX_MESSAGE_BYTES};
use crate::remote::protocol::{
    valid_id, validate_action_with_files, ImageManifest, REMOTE_PROTOCOL,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

fn required_option<'de, D, T>(deserializer: D) -> std::result::Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "lowercase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ClientControl {
    Session {
        remote_protocol: u32,
        scope: Scope,
        #[serde(deserialize_with = "required_option")]
        session: Option<String>,
        #[serde(deserialize_with = "required_option")]
        boot_id: Option<String>,
    },
    Ack {
        id: String,
        sequence: u64,
    },
    Query {
        session: String,
        sequence: u64,
        id: String,
        request: Value,
    },
}
impl fmt::Debug for ClientControl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Session {
                remote_protocol,
                scope,
                ..
            } => f
                .debug_struct("Session")
                .field("remote_protocol", remote_protocol)
                .field("scope", scope)
                .field("session", &"[REDACTED]")
                .finish(),
            Self::Ack { id, sequence } => f
                .debug_struct("Ack")
                .field("id", id)
                .field("sequence", sequence)
                .finish(),
            Self::Query { id, sequence, .. } => f
                .debug_struct("Query")
                .field("id", id)
                .field("sequence", sequence)
                .field("session", &"[REDACTED]")
                .field("request", &"[REDACTED]")
                .finish(),
        }
    }
}
/// This checks syntax only; Host must bind scope, token, boot, and session to the socket.
pub fn parse_client_control(bytes: &[u8]) -> Result<ClientControl> {
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(Error::new("MESSAGE_TOO_LARGE", "远程控制消息超过 64KiB"));
    }
    let message: ClientControl = serde_json::from_slice(bytes)
        .map_err(|_| Error::new("PROTOCOL_ERROR", "远程控制消息无效"))?;
    match &message {
        ClientControl::Session {
            remote_protocol,
            session,
            boot_id,
            ..
        } => {
            if *remote_protocol != REMOTE_PROTOCOL
                || session.is_some() != boot_id.is_some()
                || session.as_ref().is_some_and(|v| !valid_id(v))
                || boot_id.as_ref().is_some_and(|v| !valid_id(v))
            {
                return Err(Error::invalid("会话参数无效"));
            }
        }
        ClientControl::Ack { id, sequence } => {
            if !valid_id(id) || *sequence == 0 {
                return Err(Error::invalid("回执参数无效"));
            }
        }
        ClientControl::Query {
            session,
            id,
            sequence,
            request,
        } => {
            if !valid_id(session) || !valid_id(id) || *sequence == 0 {
                return Err(Error::invalid("查询参数无效"));
            }
            validate_action_with_files(Scope::Desktop, request, true)?;
        }
    }
    Ok(message)
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "lowercase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ServerControl {
    Session {
        session: String,
        boot_id: String,
        state: String,
    },
    Result {
        id: String,
        sequence: u64,
        response: Value,
        #[serde(deserialize_with = "required_option")]
        image: Option<ImageManifest>,
    },
    Acked {
        id: String,
        sequence: u64,
    },
}
impl fmt::Debug for ServerControl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Session { boot_id, state, .. } => f
                .debug_struct("Session")
                .field("boot_id", boot_id)
                .field("state", state)
                .field("session", &"[REDACTED]")
                .finish(),
            Self::Result { id, sequence, .. } => f
                .debug_struct("Result")
                .field("id", id)
                .field("sequence", sequence)
                .field("response", &"[REDACTED]")
                .finish(),
            Self::Acked { id, sequence } => f
                .debug_struct("Acked")
                .field("id", id)
                .field("sequence", sequence)
                .finish(),
        }
    }
}

/// Socket wrapper checks the same absolute deadline before every TLS read/write.
/// It is constructed *before* TLS starts, and cleared only after HTTP upgrade.
pub struct DeadlineTcp {
    stream: std::net::TcpStream,
    deadline: Option<std::time::Instant>,
}
impl DeadlineTcp {
    pub fn new(stream: std::net::TcpStream, deadline: std::time::Instant) -> Self {
        Self {
            stream,
            deadline: Some(deadline),
        }
    }
    /// Set or tighten the absolute deadline for the next application phase.
    pub fn set_deadline(&mut self, deadline: std::time::Instant) {
        self.deadline = Some(deadline);
    }
    pub fn clear_deadline(&mut self) {
        self.deadline = None;
    }
    pub fn set_read_timeout(&self, timeout: Option<std::time::Duration>) -> std::io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }
    fn remaining(&self) -> std::io::Result<Option<std::time::Duration>> {
        match self.deadline {
            None => Ok(None),
            Some(deadline) => {
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                if remaining.is_zero() {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "I/O deadline",
                    ))
                } else {
                    Ok(Some(remaining))
                }
            }
        }
    }
}
impl std::io::Read for DeadlineTcp {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if let Some(t) = self.remaining()? {
            self.stream.set_read_timeout(Some(t))?;
        }
        std::io::Read::read(&mut self.stream, buf)
    }
}
impl std::io::Write for DeadlineTcp {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if let Some(t) = self.remaining()? {
            self.stream.set_write_timeout(Some(t))?;
        }
        std::io::Write::write(&mut self.stream, buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.remaining()?;
        std::io::Write::flush(&mut self.stream)
    }
}
/// Accept on an already-connected TCP socket with an absolute TLS+HTTP deadline.
pub fn accept_tls_authenticated(
    socket: std::net::TcpStream,
    config: std::sync::Arc<rustls::ServerConfig>,
    token: &crate::remote::credentials::SecretToken,
    timeout: std::time::Duration,
) -> Result<
    tungstenite::WebSocket<
        UpgradeStream<rustls::StreamOwned<rustls::ServerConnection, DeadlineTcp>>,
    >,
> {
    // A socket accepted from a nonblocking listener can inherit O_NONBLOCK on
    // Darwin. The bounded blocking TLS handshake requires resetting it first.
    socket
        .set_nonblocking(false)
        .map_err(|_| Error::new("REMOTE_HANDSHAKE_FAILED", "远程握手失败"))?;
    let deadline = std::time::Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| Error::new("REMOTE_HANDSHAKE_FAILED", "远程握手失败"))?;
    let connection = rustls::ServerConnection::new(config)
        .map_err(|_| Error::new("REMOTE_HANDSHAKE_FAILED", "远程握手失败"))?;
    let tls = rustls::StreamOwned::new(connection, DeadlineTcp::new(socket, deadline));
    let mut websocket = accept_authenticated(tls, token)?;
    websocket.get_mut().inner_mut().sock.clear_deadline();
    Ok(websocket)
}

/// During the HTTP upgrade, bound plaintext headers before tungstenite allocates them.
/// The Host is responsible for a deadline and for TLS authentication before calling.
pub struct UpgradeStream<S> {
    inner: S,
    remaining: usize,
    upgraded: bool,
}
impl<S: std::io::Read> std::io::Read for UpgradeStream<S> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.upgraded {
            return self.inner.read(buf);
        }
        if self.remaining == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "upgrade too large",
            ));
        }
        let limit = buf.len().min(self.remaining);
        let count = self.inner.read(&mut buf[..limit])?;
        self.remaining -= count;
        Ok(count)
    }
}
impl<S: std::io::Write> std::io::Write for UpgradeStream<S> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}
impl<S> UpgradeStream<S> {
    pub fn inner_mut(&mut self) -> &mut S {
        &mut self.inner
    }
}

/// Reject duplicate authorization/protocol, Origin, extensions and other routes before
/// upgrading. Returns static errors only. Caller must limit active handshakes and time.
pub fn accept_authenticated<S: std::io::Read + std::io::Write>(
    stream: S,
    token: &crate::remote::credentials::SecretToken,
) -> Result<tungstenite::WebSocket<UpgradeStream<S>>> {
    use tungstenite::handshake::server::{ErrorResponse, Request, Response};
    use tungstenite::http::{header, HeaderValue, StatusCode};
    let callback = |request: &Request,
                    mut response: Response|
     -> std::result::Result<Response, ErrorResponse> {
        let headers = request.headers();
        let auth = headers
            .get_all(header::AUTHORIZATION)
            .iter()
            .collect::<Vec<_>>();
        let protocols = headers
            .get_all(header::SEC_WEBSOCKET_PROTOCOL)
            .iter()
            .collect::<Vec<_>>();
        let valid = request
            .uri()
            .path_and_query()
            .is_some_and(|p| p.as_str() == crate::remote::protocol::PATH)
            && headers.get(header::ORIGIN).is_none()
            && headers.get(header::SEC_WEBSOCKET_EXTENSIONS).is_none()
            && auth.len() == 1
            && protocols.len() == 1
            && protocols[0].as_bytes() == crate::remote::protocol::SUBPROTOCOL.as_bytes()
            && auth[0]
                .as_bytes()
                .strip_prefix(b"Bearer ")
                .is_some_and(|candidate| token.matches(candidate));
        if !valid {
            return Err(tungstenite::http::Response::builder()
                .status(StatusCode::FORBIDDEN)
                .body(None)
                .expect("static response"));
        }
        response.headers_mut().insert(
            header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static(crate::remote::protocol::SUBPROTOCOL),
        );
        Ok(response)
    };
    let config = tungstenite::protocol::WebSocketConfig::default()
        .read_buffer_size(4096)
        .write_buffer_size(0)
        .max_write_buffer_size(128 * 1024)
        .max_message_size(Some(MAX_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_MESSAGE_BYTES))
        .accept_unmasked_frames(false);
    let stream = UpgradeStream {
        inner: stream,
        remaining: 8 * 1024,
        upgraded: false,
    };
    let mut socket = tungstenite::accept_hdr_with_config(stream, callback, Some(config))
        .map_err(|_| Error::new("REMOTE_HANDSHAKE_FAILED", "远程握手失败"))?;
    socket.get_mut().upgraded = true;
    Ok(socket)
}

/// The caller must additionally bind returned session/boot and result ID/sequence to
/// the current socket and validate the hello's exact version and scope.
pub fn parse_server_control(bytes: &[u8]) -> Result<ServerControl> {
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(Error::new("MESSAGE_TOO_LARGE", "远程控制消息超过 64KiB"));
    }
    let message: ServerControl = serde_json::from_slice(bytes)
        .map_err(|_| Error::new("PROTOCOL_ERROR", "远程控制消息无效"))?;
    match &message {
        ServerControl::Session {
            session,
            boot_id,
            state,
        } => {
            if !valid_id(session)
                || !valid_id(boot_id)
                || !matches!(
                    state.as_str(),
                    "ready" | "lost_paused" | "cancellation_unconfirmed" | "recovery_required"
                )
            {
                return Err(Error::new("PROTOCOL_ERROR", "远程会话响应无效"));
            }
        }
        ServerControl::Acked { id, sequence } => {
            if !valid_id(id) || *sequence == 0 {
                return Err(Error::new("PROTOCOL_ERROR", "远程确认无效"));
            }
        }
        ServerControl::Result {
            id,
            sequence,
            response,
            image,
        } => {
            if !valid_id(id) || *sequence == 0 || !response.is_object() {
                return Err(Error::new("PROTOCOL_ERROR", "远程回执无效"));
            }
            if let Some(manifest) = image {
                manifest.validate()?;
                if manifest.request_id != *id
                    || response.get("frameId").and_then(Value::as_str)
                        != Some(manifest.frame_id.as_str())
                {
                    return Err(Error::new("PROTOCOL_ERROR", "图片与请求不匹配"));
                }
            }
        }
    }
    Ok(message)
}

/// Establish WSS directly with the provided trust roots; no proxy, redirects or downgrade.
pub fn connect_authenticated(
    url: &str,
    config: std::sync::Arc<rustls::ClientConfig>,
    token: &crate::remote::credentials::SecretToken,
) -> Result<
    tungstenite::WebSocket<
        UpgradeStream<rustls::StreamOwned<rustls::ClientConnection, DeadlineTcp>>,
    >,
> {
    use std::net::ToSocketAddrs;
    use tungstenite::client::IntoClientRequest;
    use tungstenite::http::{header, HeaderValue};
    fn invalid() -> Error {
        Error::new("REMOTE_CONNECT_FAILED", "远程连接失败")
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut parsed = url::Url::parse(url).map_err(|_| invalid())?;
    if parsed.scheme() != "wss"
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(invalid());
    }
    if parsed.path() == "/" {
        parsed.set_path(crate::remote::protocol::PATH);
    }
    if parsed.path() != crate::remote::protocol::PATH {
        return Err(invalid());
    }
    let (host, ip) = match parsed.host().ok_or_else(invalid)? {
        url::Host::Domain(name) => (name.to_owned(), None),
        url::Host::Ipv4(ip) => (ip.to_string(), Some(std::net::IpAddr::V4(ip))),
        url::Host::Ipv6(ip) => (ip.to_string(), Some(std::net::IpAddr::V6(ip))),
    };
    let server_name =
        rustls::pki_types::ServerName::try_from(host.clone()).map_err(|_| invalid())?;
    let port = parsed.port_or_known_default().ok_or_else(invalid)?;
    let addrs = if let Some(ip) = ip {
        vec![std::net::SocketAddr::new(ip, port)]
    } else {
        static RESOLVERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        RESOLVERS
            .fetch_update(
                std::sync::atomic::Ordering::AcqRel,
                std::sync::atomic::Ordering::Acquire,
                |v| (v < 4).then_some(v + 1),
            )
            .map_err(|_| invalid())?;
        struct Slot;
        impl Drop for Slot {
            fn drop(&mut self) {
                RESOLVERS.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
            }
        }
        let slot = Slot;
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let name = host.clone();
        std::thread::Builder::new()
            .name("mcc-dns".into())
            .spawn(move || {
                let _slot = slot;
                let addresses = (name.as_str(), port)
                    .to_socket_addrs()
                    .map(|iter| iter.take(8).collect::<Vec<_>>());
                let _ = tx.send(addresses);
            })
            .map_err(|_| invalid())?;
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err(invalid());
        }
        rx.recv_timeout(remaining)
            .map_err(|_| invalid())?
            .map_err(|_| invalid())?
    };
    let mut tcp = None;
    for addr in addrs {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        if let Ok(stream) = std::net::TcpStream::connect_timeout(&addr, remaining) {
            tcp = Some(stream);
            break;
        }
    }
    let tcp = tcp.ok_or_else(invalid)?;
    tcp.set_read_timeout(Some(std::time::Duration::from_secs(5)))
        .map_err(|_| invalid())?;
    tcp.set_write_timeout(Some(std::time::Duration::from_secs(5)))
        .map_err(|_| invalid())?;
    let tls = rustls::StreamOwned::new(
        rustls::ClientConnection::new(config, server_name).map_err(|_| invalid())?,
        DeadlineTcp::new(tcp, deadline),
    );
    let mut request = parsed
        .as_str()
        .into_client_request()
        .map_err(|_| invalid())?;
    let mut auth = HeaderValue::from_str(&format!("Bearer {}", token.header_value()))
        .map_err(|_| invalid())?;
    auth.set_sensitive(true);
    request.headers_mut().insert(header::AUTHORIZATION, auth);
    request.headers_mut().insert(
        header::SEC_WEBSOCKET_PROTOCOL,
        HeaderValue::from_static(crate::remote::protocol::SUBPROTOCOL),
    );
    let options = tungstenite::protocol::WebSocketConfig::default()
        .read_buffer_size(4096)
        .write_buffer_size(0)
        .max_write_buffer_size(128 * 1024)
        .max_message_size(Some(MAX_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_MESSAGE_BYTES))
        .accept_unmasked_frames(false);
    let wrapped = UpgradeStream {
        inner: tls,
        remaining: 8 * 1024,
        upgraded: false,
    };
    let (mut socket, response) =
        tungstenite::client::client_with_config(request, wrapped, Some(options))
            .map_err(|_| invalid())?;
    if response
        .headers()
        .get_all(header::SEC_WEBSOCKET_PROTOCOL)
        .iter()
        .count()
        != 1
        || response
            .headers()
            .get(header::SEC_WEBSOCKET_PROTOCOL)
            .is_none_or(|h| h.as_bytes() != crate::remote::protocol::SUBPROTOCOL.as_bytes())
        || response
            .headers()
            .contains_key(header::SEC_WEBSOCKET_EXTENSIONS)
    {
        return Err(invalid());
    }
    socket.get_mut().upgraded = true;
    socket.get_mut().inner_mut().sock.clear_deadline();
    Ok(socket)
}

pub fn parse_hello(
    bytes: &[u8],
    version: &str,
    scope: Scope,
) -> Result<crate::remote::protocol::Hello> {
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(Error::new("MESSAGE_TOO_LARGE", "远程握手消息过大"));
    }
    let hello: crate::remote::protocol::Hello = serde_json::from_slice(bytes)
        .map_err(|_| Error::new("PROTOCOL_ERROR", "远程握手消息无效"))?;
    if hello.remote_protocol != REMOTE_PROTOCOL
        || hello.version != version
        || hello.scope != scope
        || !valid_id(&hello.boot_id)
        || hello.capabilities.len() > 64
        || hello.capabilities.iter().any(|v| !valid_id(v))
    {
        return Err(Error::new("PROTOCOL_ERROR", "远程版本、scope 或能力无效"));
    }
    Ok(hello)
}

/// Bounded, fail-closed handshake admission. Host must call `reject` for every
/// failed handshake and drop the lease on every socket exit.
#[derive(Clone, Default)]
pub struct Admission {
    inner: std::sync::Arc<std::sync::Mutex<AdmissionState>>,
}
#[derive(Default)]
struct AdmissionState {
    pending: usize,
    authenticated: usize,
    now: u64,
    failures: std::collections::HashMap<std::net::IpAddr, std::collections::VecDeque<u64>>,
    global_failures: std::collections::VecDeque<u64>,
}
pub struct AdmissionLease {
    inner: std::sync::Arc<std::sync::Mutex<AdmissionState>>,
    ip: std::net::IpAddr,
    authenticated: bool,
    rejected: bool,
}
impl AdmissionState {
    fn tick(&mut self, now: u64) -> Result<()> {
        if now < self.now {
            return Err(Error::new("INVALID_TIME", "握手时间无效"));
        }
        self.now = now;
        while self
            .global_failures
            .front()
            .is_some_and(|v| now.saturating_sub(*v) >= 60_000)
        {
            self.global_failures.pop_front();
        }
        self.failures.retain(|_, events| {
            while events
                .front()
                .is_some_and(|v| now.saturating_sub(*v) >= 60_000)
            {
                events.pop_front();
            }
            !events.is_empty()
        });
        Ok(())
    }
}
impl Admission {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn enter(&self, ip: std::net::IpAddr, now: u64) -> Result<AdmissionLease> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| Error::new("BUSY", "远程握手不可用"))?;
        state.tick(now)?;
        if state.pending >= 8
            || state.global_failures.len() >= 100
            || state
                .failures
                .get(&ip)
                .is_some_and(|events| events.len() >= 10)
            || (state.failures.len() >= 256 && !state.failures.contains_key(&ip))
        {
            return Err(Error::new("BUSY", "远程握手不可用"));
        }
        state.pending += 1;
        Ok(AdmissionLease {
            inner: self.inner.clone(),
            ip,
            authenticated: false,
            rejected: false,
        })
    }
}
impl AdmissionLease {
    pub fn authenticate(&mut self) -> Result<()> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| Error::new("BUSY", "远程握手不可用"))?;
        if self.rejected || self.authenticated || state.authenticated >= 4 {
            return Err(Error::new("BUSY", "远程连接不可用"));
        }
        state.pending -= 1;
        state.authenticated += 1;
        self.authenticated = true;
        Ok(())
    }
    pub fn reject(&mut self, now: u64) -> Result<()> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| Error::new("BUSY", "远程握手不可用"))?;
        state.tick(now)?;
        if self.rejected || self.authenticated {
            return Err(Error::new("INVALID_ARGUMENT", "握手状态无效"));
        }
        if state.global_failures.len() < 100 {
            state.global_failures.push_back(now);
        }
        if state.failures.contains_key(&self.ip) || state.failures.len() < 256 {
            let events = state.failures.entry(self.ip).or_default();
            if events.len() < 10 {
                events.push_back(now);
            }
        }
        self.rejected = true;
        Ok(())
    }
}
impl Drop for AdmissionLease {
    fn drop(&mut self) {
        if let Ok(mut state) = self.inner.lock() {
            if self.authenticated {
                state.authenticated = state.authenticated.saturating_sub(1);
            } else {
                state.pending = state.pending.saturating_sub(1);
            }
        }
    }
}

/// Per-session token bucket: ten requests/second, burst twenty, bounded to 64 keys.
/// The keys are SHA-256 digests, never raw session credentials.
#[derive(Default)]
pub struct RequestBudget {
    now: u64,
    buckets: std::collections::HashMap<[u8; 32], RequestBucket>,
}
struct RequestBucket {
    last: u64,
    milli_tokens: u64,
}
impl std::fmt::Debug for RequestBudget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RequestBudget")
            .field("entries", &self.buckets.len())
            .finish()
    }
}
impl RequestBudget {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn consume(&mut self, session: &str, now: u64) -> Result<()> {
        if !valid_id(session) || now < self.now {
            return Err(Error::new("INVALID_ARGUMENT", "远程限速参数无效"));
        }
        self.now = now;
        self.buckets
            .retain(|_, b| now.saturating_sub(b.last) < 300_000);
        let digest: [u8; 32] = ring::digest::digest(&ring::digest::SHA256, session.as_bytes())
            .as_ref()
            .try_into()
            .expect("sha256 length");
        if self.buckets.len() >= 64 && !self.buckets.contains_key(&digest) {
            return Err(Error::new("BUSY", "远程请求限速"));
        }
        let bucket = self.buckets.entry(digest).or_insert(RequestBucket {
            last: now,
            milli_tokens: 20_000,
        });
        bucket.milli_tokens = bucket
            .milli_tokens
            .saturating_add(now.saturating_sub(bucket.last).saturating_mul(10))
            .min(20_000);
        bucket.last = now;
        if bucket.milli_tokens < 1_000 {
            return Err(Error::new("BUSY", "远程请求限速"));
        }
        bucket.milli_tokens -= 1_000;
        Ok(())
    }
}
