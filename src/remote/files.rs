//! Bounded, private, connection-owned uploads. Never accepts a destination path.
use crate::{
    private_files::{self, LockedStateDir},
    protocol::{Error, Result},
};
use ring::digest::{Context, SHA256};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

pub const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;
pub const CHUNK_BYTES: usize = 32 * 1024;
const MAX_TOTAL_BYTES: u64 = 256 * 1024 * 1024;
const MAX_FILES: usize = 128;
fn error(code: &str) -> Error {
    Error::new(code, "文件传输或文件归属校验失败")
}
pub fn sha256(bytes: &[u8]) -> String {
    hex(ring::digest::digest(&SHA256, bytes).as_ref())
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
}
impl Manifest {
    pub fn validate(&self) -> Result<()> {
        if self.name.is_empty()
            || self.name.len() > 200
            || matches!(self.name.as_str(), "." | ".." | ".part")
            || self.name.contains(['/', '\\'])
            || self.name.chars().any(char::is_control)
            || self.bytes > MAX_FILE_BYTES
            || self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(error("INVALID_ARGUMENT"));
        }
        Ok(())
    }
}
pub struct LocalFile {
    pub file: File,
    pub manifest: Manifest,
}
impl LocalFile {
    pub fn open(path: &Path) -> Result<Self> {
        if !path.is_absolute() {
            return Err(error("INVALID_ARGUMENT"));
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)
            .map_err(|_| error("FILE_NOT_READABLE"))?;
        let meta = file.metadata().map_err(|_| error("FILE_NOT_READABLE"))?;
        if !meta.is_file() {
            return Err(error("FILE_NOT_READABLE"));
        }
        if meta.len() > MAX_FILE_BYTES {
            return Err(error("FILE_TOO_LARGE"));
        }
        let mut digest = Context::new(&SHA256);
        let mut buf = [0; CHUNK_BYTES];
        let mut bytes = 0;
        loop {
            let n = file
                .read(&mut buf)
                .map_err(|_| error("FILE_NOT_READABLE"))?;
            if n == 0 {
                break;
            }
            bytes += n as u64;
            if bytes > MAX_FILE_BYTES {
                return Err(error("FILE_TOO_LARGE"));
            }
            digest.update(&buf[..n]);
        }
        if bytes != meta.len() {
            return Err(error("FILE_CHANGED"));
        }
        file.seek(SeekFrom::Start(0))
            .map_err(|_| error("FILE_NOT_READABLE"))?;
        let manifest = Manifest {
            name: path
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or_else(|| error("INVALID_ARGUMENT"))?
                .into(),
            bytes,
            sha256: hex(digest.finish().as_ref()),
        };
        manifest.validate()?;
        Ok(Self { file, manifest })
    }
}

struct Entry {
    session: String,
    connection: String,
    path: PathBuf,
    identity: (u64, u64),
    manifest: Manifest,
}
pub struct FileStore {
    root: PathBuf,
    _lock: LockedStateDir,
    entries: HashMap<String, Entry>,
}
pub struct PendingUpload {
    id: String,
    session: String,
    connection: String,
    directory: PathBuf,
    file: File,
    manifest: Manifest,
    written: u64,
    digest: Context,
    published: bool,
}
impl Drop for PendingUpload {
    fn drop(&mut self) {
        if !self.published {
            let _ = private_files::remove_created_file(&self.directory.join(".part"), &self.file);
            let _ = private_files::remove_created_file(
                &self.directory.join(&self.manifest.name),
                &self.file,
            );
            let _ = std::fs::remove_dir(&self.directory);
        }
    }
}
impl PendingUpload {
    pub fn remaining(&self) -> u64 {
        self.manifest.bytes - self.written
    }
    pub fn push(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() || bytes.len() > CHUNK_BYTES || bytes.len() as u64 > self.remaining() {
            return Err(error("FILE_TRANSFER_INVALID"));
        }
        self.file
            .write_all(bytes)
            .map_err(|_| error("FILE_TRANSFER_FAILED"))?;
        self.digest.update(bytes);
        self.written += bytes.len() as u64;
        Ok(())
    }
}
impl FileStore {
    pub fn open(root: &Path) -> Result<Self> {
        if !root.is_absolute() {
            return Err(error("INVALID_ARGUMENT"));
        }
        let guard = LockedStateDir::open(root).map_err(|_| error("INSECURE_UPLOAD_DIR"))?;
        let root = root
            .canonicalize()
            .map_err(|_| error("INSECURE_UPLOAD_DIR"))?;
        let store = Self {
            root,
            _lock: guard,
            entries: HashMap::new(),
        };
        store.usage()?;
        Ok(store)
    }
    // Count crash leftovers too. Never follow a symlink during quota inspection.
    fn usage(&self) -> Result<(usize, u64)> {
        let mut count = 0;
        let mut bytes = 0u64;
        for entry in std::fs::read_dir(&self.root).map_err(|_| error("INSECURE_UPLOAD_DIR"))? {
            let entry = entry.map_err(|_| error("INSECURE_UPLOAD_DIR"))?;
            if entry.file_name() == ".lock" {
                continue;
            }
            let meta = std::fs::symlink_metadata(entry.path())
                .map_err(|_| error("INSECURE_UPLOAD_DIR"))?;
            private_files::check_private(&meta, true).map_err(|_| error("INSECURE_UPLOAD_DIR"))?;
            count += 1;
            if count > MAX_FILES {
                return Err(error("FILE_QUOTA_EXCEEDED"));
            }
            for file in std::fs::read_dir(entry.path()).map_err(|_| error("INSECURE_UPLOAD_DIR"))? {
                let meta = std::fs::symlink_metadata(
                    file.map_err(|_| error("INSECURE_UPLOAD_DIR"))?.path(),
                )
                .map_err(|_| error("INSECURE_UPLOAD_DIR"))?;
                private_files::check_private(&meta, false)
                    .map_err(|_| error("INSECURE_UPLOAD_DIR"))?;
                bytes = bytes
                    .checked_add(meta.len())
                    .ok_or_else(|| error("FILE_QUOTA_EXCEEDED"))?;
                if bytes > MAX_TOTAL_BYTES {
                    return Err(error("FILE_QUOTA_EXCEEDED"));
                }
            }
        }
        Ok((count, bytes))
    }
    pub fn begin(
        &self,
        session: &str,
        connection: &str,
        manifest: Manifest,
    ) -> Result<PendingUpload> {
        manifest.validate()?;
        let (count, bytes) = self.usage()?;
        if count >= MAX_FILES || bytes + manifest.bytes > MAX_TOTAL_BYTES {
            return Err(error("FILE_QUOTA_EXCEEDED"));
        }
        let id = crate::protocol::random_id()?;
        let directory = self.root.join(&id);
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|_| error("FILE_TRANSFER_FAILED"))?;
        let file = match OpenOptions::new()
            .write(true)
            .read(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(directory.join(".part"))
        {
            Ok(f) => f,
            Err(_) => {
                let _ = std::fs::remove_dir(&directory);
                return Err(error("FILE_TRANSFER_FAILED"));
            }
        };
        Ok(PendingUpload {
            id,
            session: session.into(),
            connection: connection.into(),
            directory,
            file,
            manifest,
            written: 0,
            digest: Context::new(&SHA256),
            published: false,
        })
    }
    pub fn commit(&mut self, mut pending: PendingUpload) -> Result<Value> {
        if pending.remaining() != 0
            || hex(pending.digest.clone().finish().as_ref()) != pending.manifest.sha256
        {
            return Err(error("FILE_HASH_MISMATCH"));
        }
        pending
            .file
            .sync_all()
            .map_err(|_| error("FILE_TRANSFER_FAILED"))?;
        let meta = pending
            .file
            .metadata()
            .map_err(|_| error("FILE_TRANSFER_FAILED"))?;
        let path = pending.directory.join(&pending.manifest.name);
        // .part is reserved for staging, so publish only to a distinct basename.
        if pending.manifest.name == ".part" {
            return Err(error("INVALID_ARGUMENT"));
        }
        std::fs::hard_link(pending.directory.join(".part"), &path)
            .map_err(|_| error("FILE_TRANSFER_FAILED"))?;
        std::fs::remove_file(pending.directory.join(".part"))
            .map_err(|_| error("FILE_TRANSFER_FAILED"))?;
        File::open(&pending.directory)
            .and_then(|f| f.sync_all())
            .map_err(|_| error("FILE_TRANSFER_FAILED"))?;
        let receipt = json!({"fileId":pending.id,"name":pending.manifest.name,"bytes":pending.manifest.bytes,"sha256":pending.manifest.sha256});
        self.entries.insert(
            pending.id.clone(),
            Entry {
                session: pending.session.clone(),
                connection: pending.connection.clone(),
                path,
                identity: (meta.dev(), meta.ino()),
                manifest: pending.manifest.clone(),
            },
        );
        pending.published = true;
        Ok(receipt)
    }
    pub fn resolve(&self, session: &str, connection: &str, id: &str) -> Result<PathBuf> {
        let entry = self
            .entries
            .get(id)
            .filter(|e| e.session == session && e.connection == connection)
            .ok_or_else(|| error("FILE_NOT_ALLOWED"))?;
        let parent = entry
            .path
            .parent()
            .ok_or_else(|| error("FILE_NOT_ALLOWED"))?;
        private_files::check_private(
            &std::fs::symlink_metadata(parent).map_err(|_| error("FILE_NOT_ALLOWED"))?,
            true,
        )
        .map_err(|_| error("FILE_NOT_ALLOWED"))?;
        let local = LocalFile::open(&entry.path).map_err(|_| error("FILE_NOT_ALLOWED"))?;
        let meta = local
            .file
            .metadata()
            .map_err(|_| error("FILE_NOT_ALLOWED"))?;
        if (meta.dev(), meta.ino()) != entry.identity
            || meta.nlink() != 1
            || local.manifest.bytes != entry.manifest.bytes
            || local.manifest.sha256 != entry.manifest.sha256
        {
            return Err(error("FILE_NOT_ALLOWED"));
        }
        // Keep metadata and file contents checked together; selection uses the
        // private path through the existing helper contract (same-UID boundary).
        Ok(entry.path.clone())
    }
    pub fn release(&mut self, session: &str, connection: &str) {
        self.entries.retain(|_, entry| {
            if entry.session != session || entry.connection != connection {
                return true;
            }
            if let Ok(file) = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(&entry.path)
            {
                if file
                    .metadata()
                    .is_ok_and(|m| (m.dev(), m.ino()) == entry.identity)
                {
                    let _ = private_files::remove_created_file(&entry.path, &file);
                }
            }
            if let Some(parent) = entry.path.parent() {
                let _ = std::fs::remove_dir(parent);
            }
            false
        });
    }
}
