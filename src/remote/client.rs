//! Short-lived WSS client. No local daemon/model fallback.
use crate::protocol::{Error, Result, Scope, MAX_MESSAGE_BYTES, PROTOCOL_VERSION};
use crate::remote::{
    credentials, images,
    options::ClientOptions,
    protocol::{self, RemoteEnvelope},
    wire::{self, ClientControl, ServerControl},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::{path::PathBuf, sync::Arc};
use tungstenite::Message;

type Socket = tungstenite::WebSocket<
    wire::UpgradeStream<rustls::StreamOwned<rustls::ClientConnection, wire::DeadlineTcp>>,
>;
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CachedSession {
    session: String,
    boot_id: String,
    sequence: u64,
    #[serde(default)]
    auto_images: Vec<AutoImage>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AutoImage {
    name: String,
    dev: u64,
    ino: u64,
    ctime: i64,
    ctime_nsec: i64,
}
fn valid_image_name(name: &str) -> bool {
    name.len() <= 256
        && name.strip_suffix(".jpg").is_some_and(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
        })
}
fn invalid() -> Error {
    Error::new("REMOTE_CLIENT_FAILED", "远程客户端操作失败")
}
fn outcome(id: &str) -> Error {
    Error::new(
        "REMOTE_OUTCOME_UNKNOWN",
        &format!("远程结果不确定；请求 ID：{id}，不会自动重试"),
    )
}
fn state_root(options: &ClientOptions, scope: Scope) -> Result<PathBuf> {
    let root = match &options.state_dir {
        Some(p) => p.clone(),
        None => match std::env::var_os("MCC_CONFIG_DIR") {
            Some(p) => PathBuf::from(p).join("remote-sessions"),
            None => PathBuf::from(std::env::var_os("HOME").ok_or_else(invalid)?)
                .join(".config/mcc/remote-sessions"),
        },
    };
    if !root.is_absolute() {
        return Err(invalid());
    }
    // The common root itself is private, not only the endpoint child.
    let root_guard = crate::private_files::LockedStateDir::open(&root).map_err(|_| invalid())?;
    drop(root_guard);
    let mut input = Vec::new();
    input.extend_from_slice(options.url.as_bytes());
    input.push(0);
    input.extend_from_slice(scope.name().as_bytes());
    input.push(0);
    match &options.ca_cert {
        Some(path) => input.extend(
            crate::private_files::read_public_cert(path, 64 * 1024).map_err(|_| invalid())?,
        ),
        None => input.extend_from_slice(b"system-roots"),
    }
    let digest = ring::digest::digest(&ring::digest::SHA256, &input);
    let identity: String = digest.as_ref().iter().map(|b| format!("{b:02x}")).collect();
    Ok(root.join(identity))
}
fn send<T: Serialize>(socket: &mut Socket, value: &T) -> Result<()> {
    let data = serde_json::to_string(value).map_err(|_| invalid())?;
    if data.len() > MAX_MESSAGE_BYTES {
        return Err(Error::new("MESSAGE_TOO_LARGE", "远程控制消息超过 64KiB"));
    }
    socket
        .send(Message::Text(data.into()))
        .map_err(|_| invalid())
}
fn set_deadline(socket: &mut Socket, deadline: std::time::Instant) {
    socket.get_mut().inner_mut().sock.set_deadline(deadline);
}
fn receive(socket: &mut Socket, deadline: std::time::Instant) -> Result<Message> {
    for _ in 0..128 {
        let now = std::time::Instant::now();
        if now >= deadline {
            return Err(invalid());
        }
        // One complete WS message must arrive within 15 seconds, even if a peer
        // drips bytes into a single fragmented frame. Ping/Pong is processed below.
        set_deadline(
            socket,
            deadline.min(now + std::time::Duration::from_secs(15)),
        );
        match socket.read().map_err(|_| invalid())? {
            Message::Ping(_) | Message::Pong(_) => socket.flush().map_err(|_| invalid())?,
            Message::Text(v) => return Ok(Message::Text(v)),
            Message::Binary(v) => return Ok(Message::Binary(v)),
            _ => return Err(invalid()),
        }
    }
    Err(invalid())
}
fn text(socket: &mut Socket, deadline: std::time::Instant) -> Result<Vec<u8>> {
    match receive(socket, deadline)? {
        Message::Text(v) => Ok(v.as_str().as_bytes().to_vec()),
        _ => Err(invalid()),
    }
}
fn save_state(store: &crate::private_files::LockedStateDir, state: &CachedSession) -> Result<()> {
    let data = serde_json::to_vec(state).map_err(|_| invalid())?;
    store.write("session.json", &data).map_err(|_| invalid())
}
fn validate_response(response: &Value, scope: Scope) -> Result<()> {
    if response.get("protocolVersion").and_then(Value::as_u64) != Some(PROTOCOL_VERSION as u64)
        || (scope == Scope::Desktop
            && response.get("scope").and_then(Value::as_str) != Some("desktop"))
        || (scope == Scope::Chrome
            && response
                .get("scope")
                .is_some_and(|v| v.as_str() != Some("chrome")))
    {
        return Err(invalid());
    }
    match response.get("ok") {
        Some(Value::Bool(true)) => Ok(()),
        Some(Value::Bool(false)) => {
            let value = response.get("error").ok_or_else(invalid)?;
            let _: Error = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
            if value.get("reason").is_some_and(|v| !v.is_string()) {
                return Err(invalid());
            }
            Ok(())
        }
        _ => Err(invalid()),
    }
}
fn decode_result(mut response: Value, scope: Scope) -> Result<Value> {
    validate_response(&response, scope)?;
    if response.get("ok") == Some(&Value::Bool(false)) {
        let err = response.get("error").ok_or_else(invalid)?;
        let mut error: Error = serde_json::from_value(err.clone()).map_err(|_| invalid())?;
        if err.get("reason").and_then(Value::as_str) == Some("USER_PAUSED") {
            error.code = "USER_PAUSED".into();
        }
        return Err(error);
    }
    if response.get("ok") != Some(&Value::Bool(true)) {
        return Err(invalid());
    }
    let map = response.as_object_mut().ok_or_else(invalid)?;
    map.remove("ok");
    map.remove("protocolVersion");
    map.remove("scope");
    Ok(response)
}
/// The local session lock is held across the complete RPC and is never queued.
pub fn run(
    options: ClientOptions,
    request: Value,
    output: Option<PathBuf>,
    scope: Scope,
) -> Result<Value> {
    protocol::validate_action_with_files(scope, &request, true)?;
    let action = request["action"].as_str().ok_or_else(invalid)?.to_owned();
    if output.is_some() && action != "observe" && action != "frame" {
        return Err(Error::invalid("只有观察帧可以指定输出"));
    }
    if let Some(path) = output.as_deref() {
        match std::fs::symlink_metadata(path) {
            Ok(_) => {
                return Err(Error::new(
                    "OUTPUT_EXISTS",
                    "输出文件已存在；为避免覆盖，请指定新文件名",
                ))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Error::new("REMOTE_IMAGE_INVALID", "无法检查输出文件")),
        }
    }
    let token = credentials::read_token(&options.token_file)?;
    let tls = credentials::client_config(options.ca_cert.as_deref())?;
    let state_dir = state_root(&options, scope)?;
    let store = crate::private_files::LockedStateDir::open(&state_dir)
        .map_err(|_| Error::new("BUSY", "远程会话不可用或正在使用"))?;
    let mut state = store
        .read("session.json", MAX_MESSAGE_BYTES as u64)
        .map_err(|_| invalid())?
        .map(|data| serde_json::from_slice::<CachedSession>(&data).map_err(|_| invalid()))
        .transpose()?;
    if let Some(s) = &state {
        if !protocol::valid_id(&s.session)
            || !protocol::valid_id(&s.boot_id)
            || s.auto_images.len() > 32
            || s.auto_images.iter().any(|image| {
                !valid_image_name(&image.name)
                    || image.ino == 0
                    || !(0..1_000_000_000).contains(&image.ctime_nsec)
            })
            || s.auto_images
                .iter()
                .enumerate()
                .any(|(i, image)| s.auto_images[..i].iter().any(|old| old.name == image.name))
        {
            return Err(invalid());
        }
    }
    let mut socket = wire::connect_authenticated(&options.url, Arc::clone(&tls), &token)?;
    let hello_deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let hello = wire::parse_hello(
        &text(&mut socket, hello_deadline)?,
        env!("CARGO_PKG_VERSION"),
        scope,
    )?;
    if state.as_ref().is_some_and(|s| s.boot_id != hello.boot_id) {
        return Err(Error::new(
            "RECOVERY_REQUIRED",
            "Host 已重启；旧会话未自动替换",
        ));
    }
    let session_deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    set_deadline(&mut socket, session_deadline);
    send(
        &mut socket,
        &ClientControl::Session {
            remote_protocol: protocol::REMOTE_PROTOCOL,
            scope,
            session: state.as_ref().map(|s| s.session.clone()),
            boot_id: state.as_ref().map(|s| s.boot_id.clone()),
        },
    )?;
    let (session, boot, status) =
        match wire::parse_server_control(&text(&mut socket, session_deadline)?)? {
            ServerControl::Session {
                session,
                boot_id,
                state,
            } => (session, boot_id, state),
            _ => return Err(invalid()),
        };
    if boot != hello.boot_id
        || state
            .as_ref()
            .is_some_and(|s| s.session != session || s.boot_id != boot)
    {
        return Err(Error::new("RECOVERY_REQUIRED", "Host 会话身份不匹配"));
    }
    if status != "ready"
        && !matches!(
            action.as_str(),
            "status" | "apps" | "windows" | "permissions" | "session" | "frame" | "observe"
        )
    {
        return Err(Error::new(
            "RECOVERY_REQUIRED",
            "Host 会话已暂停或需要本地恢复",
        ));
    }
    let s = state.get_or_insert(CachedSession {
        session,
        boot_id: boot,
        sequence: 0,
        auto_images: Vec::new(),
    });
    s.sequence = s.sequence.checked_add(1).ok_or_else(invalid)?;
    let id = crate::protocol::random_id()?;
    let envelope = RemoteEnvelope {
        remote_protocol: protocol::REMOTE_PROTOCOL,
        id: id.clone(),
        session: s.session.clone(),
        sequence: s.sequence,
        scope,
        request,
    };
    let serialized = serde_json::to_vec(&envelope).map_err(|_| invalid())?;
    if serialized.len() > MAX_MESSAGE_BYTES {
        return Err(Error::new("MESSAGE_TOO_LARGE", "远程消息超过 64KiB"));
    }
    save_state(&store, s)?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(55);
    set_deadline(&mut socket, deadline);
    socket
        .send(Message::Text(
            String::from_utf8(serialized).map_err(|_| invalid())?.into(),
        ))
        .map_err(|_| outcome(&id))?;
    let result =
        wire::parse_server_control(&text(&mut socket, deadline).map_err(|_| outcome(&id))?)
            .map_err(|_| outcome(&id))?;
    let (mut response, manifest) = match result {
        ServerControl::Result {
            id: rid,
            sequence,
            response,
            image,
        } if rid == id && sequence == s.sequence => (response, image),
        _ => return Err(outcome(&id)),
    };
    if response.get("imagePath").is_some() {
        return Err(outcome(&id));
    }
    validate_response(&response, scope).map_err(|_| outcome(&id))?;
    let automatic = output.is_none();
    let mut saved = None;
    let mut saved_file = None;
    let mut auto_image = None;
    let mut local_output_error = None;
    if let Some(manifest) = manifest {
        if !matches!(action.as_str(), "observe" | "frame") {
            return Err(outcome(&id));
        }
        let mut bytes = Vec::with_capacity(manifest.bytes as usize);
        while bytes.len() < manifest.bytes as usize {
            match receive(&mut socket, deadline).map_err(|_| outcome(&id))? {
                Message::Binary(chunk)
                    if !chunk.is_empty()
                        && chunk.len() <= MAX_MESSAGE_BYTES
                        && bytes.len() + chunk.len() <= manifest.bytes as usize =>
                {
                    bytes.extend_from_slice(&chunk)
                }
                _ => return Err(outcome(&id)),
            }
        }
        let path = match images::save_frame(&manifest, &bytes, output, &state_dir) {
            Ok(path) => Some(path),
            Err(error) if !automatic && error.code == "OUTPUT_EXISTS" => {
                local_output_error = Some(error);
                None
            }
            Err(_) => return Err(outcome(&id)),
        };
        if let Some(path) = path {
            let file = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(&path)
                .map_err(|_| invalid())?;
            let opened = file.metadata().map_err(|_| invalid())?;
            let named = std::fs::symlink_metadata(&path).map_err(|_| invalid())?;
            if !opened.is_file()
                || opened.nlink() != 1
                || opened.uid() != unsafe { libc::geteuid() }
                || opened.mode() & 0o7777 != 0o600
                || opened.dev() != named.dev()
                || opened.ino() != named.ino()
            {
                return Err(invalid());
            }
            saved_file = Some(file);
            if automatic {
                let name = path
                    .file_name()
                    .and_then(|v| v.to_str())
                    .filter(|v| valid_image_name(v))
                    .ok_or_else(invalid)?
                    .to_owned();
                let (dev, ino, ctime, ctime_nsec) = store
                    .file_identity(&name)
                    .map_err(|_| invalid())?
                    .ok_or_else(invalid)?;
                if (dev, ino, ctime, ctime_nsec)
                    != (
                        opened.dev(),
                        opened.ino(),
                        opened.ctime(),
                        opened.ctime_nsec(),
                    )
                {
                    return Err(invalid());
                }
                auto_image = Some(AutoImage {
                    name,
                    dev,
                    ino,
                    ctime,
                    ctime_nsec,
                });
            }
            response["imagePath"] = Value::String(path.to_string_lossy().into_owned());
            saved = Some(path);
        }
    } else if matches!(action.as_str(), "observe" | "frame")
        && response.get("ok") == Some(&Value::Bool(true))
    {
        return Err(outcome(&id));
    }
    let confirmation = (|| -> Result<()> {
        set_deadline(&mut socket, deadline);
        send(
            &mut socket,
            &ClientControl::Ack {
                id: id.clone(),
                sequence: s.sequence,
            },
        )?;
        match wire::parse_server_control(&text(&mut socket, deadline)?)? {
            ServerControl::Acked { id: rid, sequence } if rid == id && sequence == s.sequence => {
                Ok(())
            }
            _ => Err(invalid()),
        }
    })();
    if confirmation.is_err() {
        if let Some(image) = auto_image.as_ref() {
            let _ = store.remove_registered(
                &image.name,
                (image.dev, image.ino, image.ctime, image.ctime_nsec),
            );
        } else if let (Some(path), Some(file)) = (saved, saved_file) {
            let _ = crate::private_files::remove_created_file(&path, &file);
        }
        return Err(outcome(&id));
    }
    if let Some(image) = auto_image {
        while s.auto_images.len() >= 32 {
            let old = s.auto_images.remove(0);
            // An unknown replacement is not ours: leave it alone and drop only its registration.
            store
                .remove_registered(&old.name, (old.dev, old.ino, old.ctime, old.ctime_nsec))
                .map_err(|_| invalid())?;
        }
        s.auto_images.push(image);
        save_state(&store, s)?;
    }
    set_deadline(
        &mut socket,
        deadline.min(std::time::Instant::now() + std::time::Duration::from_secs(5)),
    );
    socket.close(None).map_err(|_| outcome(&id))?;
    if let Some(error) = local_output_error {
        return Err(error);
    }
    decode_result(response, scope)
}
