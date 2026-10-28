//! Shared file primitives for local configuration and remote credentials.
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "unsafe file")
}

fn check(metadata: &std::fs::Metadata, directory: bool, public: bool) -> io::Result<()> {
    if (directory && !metadata.is_dir())
        || (!directory && !metadata.is_file())
        || metadata.file_type().is_symlink()
    {
        return Err(invalid());
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & if public { 0o022 } else { 0o077 } != 0
        || metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(invalid());
    }
    #[cfg(not(unix))]
    let _ = public;
    Ok(())
}
pub(crate) fn check_private(metadata: &std::fs::Metadata, directory: bool) -> io::Result<()> {
    check(metadata, directory, false)
}

// The existing config reader retains its established permission semantics.
pub(crate) fn read_private(path: &Path, max_bytes: u64) -> io::Result<Vec<u8>> {
    read_checked(path, max_bytes, 0)
}
#[cfg(unix)]
pub(crate) fn read_credential(path: &Path, max_bytes: u64) -> io::Result<Vec<u8>> {
    let parent = std::fs::symlink_metadata(path.parent().ok_or_else(invalid)?)?;
    check_private(&parent, true)?;
    if parent.permissions().mode() & 0o7777 != 0o700 {
        return Err(invalid());
    }
    read_checked(path, max_bytes, 1)
}
#[cfg(unix)]
pub(crate) fn read_public_cert(path: &Path, max_bytes: u64) -> io::Result<Vec<u8>> {
    let parent = std::fs::symlink_metadata(path.parent().ok_or_else(invalid)?)?;
    check(&parent, true, true)?;
    read_checked(path, max_bytes, 2)
}
fn read_checked(path: &Path, max_bytes: u64, policy: u8) -> io::Result<Vec<u8>> {
    let meta = std::fs::symlink_metadata(path)?;
    check(&meta, false, policy == 2)?;
    if meta.len() > max_bytes {
        return Err(invalid());
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    let file = options.open(path)?;
    let opened = file.metadata()?;
    check(&opened, false, policy == 2)?;
    #[cfg(unix)]
    if policy != 0 {
        let current = std::fs::symlink_metadata(path)?;
        check(&current, false, policy == 2)?;
        if (policy == 1 && opened.permissions().mode() & 0o7777 != 0o600)
            || opened.nlink() != 1
            || current.nlink() != 1
            || meta.dev() != opened.dev()
            || meta.ino() != opened.ino()
            || current.dev() != opened.dev()
            || current.ino() != opened.ino()
        {
            return Err(invalid());
        }
    }
    let mut bytes = Vec::new();
    file.take(max_bytes + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        return Err(invalid());
    }
    Ok(bytes)
}
pub(crate) fn write_new(path: &Path, data: &[u8]) -> io::Result<()> {
    write_new_with_mode(path, data, false)
}
#[cfg(unix)]
pub(crate) fn write_credential_new(path: &Path, data: &[u8]) -> io::Result<()> {
    write_new_with_mode(path, data, true)
}
fn write_new_with_mode(path: &Path, data: &[u8], exact: bool) -> io::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(path)?;
    let result = (|| {
        #[cfg(unix)]
        if exact {
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        }
        #[cfg(not(unix))]
        let _ = exact;
        file.write_all(data)?;
        file.sync_all()
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(path);
    }
    result
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn public_file_owned_by_other_user_is_rejected() {
        let euid = unsafe { libc::geteuid() };
        if euid == 0 {
            eprintln!("skipped: root cannot use root-owned system file as an alien owner");
            return;
        }
        let metadata = ["/etc/passwd", "/etc/hosts"]
            .iter()
            .filter_map(|path| std::fs::symlink_metadata(path).ok())
            .find(|m| {
                m.uid() == 0
                    && m.is_file()
                    && !m.file_type().is_symlink()
                    && m.permissions().mode() & 0o022 == 0
            })
            .expect("need a root-owned non-writable regular system file for the owner test");
        assert_ne!(metadata.uid(), euid);
        assert!(metadata.is_file() && !metadata.file_type().is_symlink());
        assert_eq!(metadata.permissions().mode() & 0o022, 0);
        assert!(check(&metadata, false, true).is_err());
    }
}

/// An already-open private state directory. All sensitive file accesses use openat
/// against this descriptor; lock acquisition is non-blocking and never follows links.
#[cfg(unix)]
pub(crate) struct LockedStateDir {
    directory: std::fs::File,
    _lock: std::fs::File,
}
#[cfg(unix)]
impl LockedStateDir {
    pub(crate) fn open(path: &Path) -> io::Result<Self> {
        use std::os::fd::{AsRawFd, FromRawFd};
        if !path.is_absolute() {
            return Err(invalid());
        }
        use std::os::unix::ffi::OsStrExt;
        // macOS exposes these two root-owned fixed aliases; resolve them before
        // descriptor-relative traversal so no user-controlled symlink is followed.
        #[cfg(target_os = "macos")]
        let path = if let Ok(tail) = path.strip_prefix("/var") {
            std::path::PathBuf::from("/private/var").join(tail)
        } else if let Ok(tail) = path.strip_prefix("/tmp") {
            std::path::PathBuf::from("/private/tmp").join(tail)
        } else {
            path.to_path_buf()
        };
        #[cfg(not(target_os = "macos"))]
        let path = path.to_path_buf();
        let mut dir = std::fs::File::open("/")?;
        for component in path.components() {
            let part = match component {
                std::path::Component::RootDir => continue,
                std::path::Component::Normal(p) => p,
                _ => return Err(invalid()),
            };
            let name = std::ffi::CString::new(part.as_bytes()).map_err(|_| invalid())?;
            let mut fd = unsafe {
                libc::openat(
                    dir.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 && io::Error::last_os_error().kind() == io::ErrorKind::NotFound {
                let rc = unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o700) };
                if rc != 0 && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists {
                    return Err(io::Error::last_os_error());
                }
                fd = unsafe {
                    libc::openat(
                        dir.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                };
            }
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            dir = unsafe { std::fs::File::from_raw_fd(fd) };
        }
        let metadata = dir.metadata()?;
        check_private(&metadata, true)?;
        if metadata.permissions().mode() & 0o7777 != 0o700 {
            return Err(invalid());
        }
        let name = std::ffi::CString::new(".lock").expect("static");
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_CREAT | libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let lock = unsafe { std::fs::File::from_raw_fd(fd) };
        let meta = lock.metadata()?;
        check_private(&meta, false)?;
        if meta.permissions().mode() & 0o7777 != 0o600 || meta.nlink() != 1 {
            return Err(invalid());
        }
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            directory: dir,
            _lock: lock,
        })
    }
    pub(crate) fn read(&self, name: &str, limit: u64) -> io::Result<Option<Vec<u8>>> {
        use std::os::fd::{AsRawFd, FromRawFd};
        if name.is_empty() || name.contains('/') || name == "." || name == ".." {
            return Err(invalid());
        }
        let name = std::ffi::CString::new(name).map_err(|_| invalid())?;
        let fd = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            let e = io::Error::last_os_error();
            return if e.kind() == io::ErrorKind::NotFound {
                Ok(None)
            } else {
                Err(e)
            };
        }
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        let meta = file.metadata()?;
        check_private(&meta, false)?;
        if meta.nlink() != 1 || meta.permissions().mode() & 0o7777 != 0o600 || meta.len() > limit {
            return Err(invalid());
        }
        let mut data = Vec::new();
        file.take(limit + 1).read_to_end(&mut data)?;
        if data.len() as u64 > limit {
            return Err(invalid());
        }
        Ok(Some(data))
    }
    /// Return the identity of a private, singly-linked regular file in this
    /// locked directory. Symlinks and replaced/unowned files are never followed.
    pub(crate) fn file_identity(&self, name: &str) -> io::Result<Option<(u64, u64, i64, i64)>> {
        file_identity_at(&self.directory, name)
    }
    pub(crate) fn remove_registered(
        &self,
        name: &str,
        identity: (u64, u64, i64, i64),
    ) -> io::Result<bool> {
        remove_identity_at(&self.directory, name, identity)
    }
    pub(crate) fn write(&self, name: &str, data: &[u8]) -> io::Result<()> {
        use std::os::fd::{AsRawFd, FromRawFd};
        if name.is_empty() || name.contains('/') || name == "." || name == ".." {
            return Err(invalid());
        }
        // Check any preexisting target before atomic replacement; never follow symlinks.
        let _ = self.read(name, 64 * 1024)?;
        let temporary = std::ffi::CString::new(format!(
            ".tmp-{}",
            crate::protocol::random_id().map_err(|_| invalid())?
        ))
        .map_err(|_| invalid())?;
        let target = std::ffi::CString::new(name).map_err(|_| invalid())?;
        let fd = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
        let result = (|| {
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            file.write_all(data)?;
            file.sync_all()?;
            if unsafe {
                libc::renameat(
                    self.directory.as_raw_fd(),
                    temporary.as_ptr(),
                    self.directory.as_raw_fd(),
                    target.as_ptr(),
                )
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
            self.directory.sync_all()
        })();
        if result.is_err() {
            unsafe {
                libc::unlinkat(self.directory.as_raw_fd(), temporary.as_ptr(), 0);
            }
        }
        result
    }
}

#[cfg(unix)]
fn file_identity_at(
    directory: &std::fs::File,
    name: &str,
) -> io::Result<Option<(u64, u64, i64, i64)>> {
    use std::os::fd::{AsRawFd, FromRawFd};
    if name.is_empty() || name.contains('/') || name == "." || name == ".." {
        return Err(invalid());
    }
    let name = std::ffi::CString::new(name).map_err(|_| invalid())?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let e = io::Error::last_os_error();
        return if e.kind() == io::ErrorKind::NotFound {
            Ok(None)
        } else {
            Err(e)
        };
    }
    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    let meta = file.metadata()?;
    check_private(&meta, false)?;
    if meta.nlink() != 1 || meta.permissions().mode() & 0o7777 != 0o600 {
        return Err(invalid());
    }
    Ok(Some((
        meta.dev(),
        meta.ino(),
        meta.ctime(),
        meta.ctime_nsec(),
    )))
}

#[cfg(unix)]
fn remove_identity_at(
    directory: &std::fs::File,
    name: &str,
    identity: (u64, u64, i64, i64),
) -> io::Result<bool> {
    use std::os::fd::AsRawFd;
    match file_identity_at(directory, name) {
        Ok(Some(id)) if id == identity => {}
        Ok(_) => return Ok(false),
        Err(e)
            if e.kind() == io::ErrorKind::InvalidData || e.raw_os_error() == Some(libc::ELOOP) =>
        {
            return Ok(false)
        }
        Err(e) => return Err(e),
    }
    let source = std::ffi::CString::new(name).map_err(|_| invalid())?;
    let quarantine = std::ffi::CString::new(format!(
        ".mcc-trash-{}",
        crate::protocol::random_id().map_err(|_| invalid())?
    ))
    .map_err(|_| invalid())?;
    #[cfg(target_os = "macos")]
    let rc = unsafe {
        libc::renameatx_np(
            directory.as_raw_fd(),
            source.as_ptr(),
            directory.as_raw_fd(),
            quarantine.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(target_os = "linux")]
    let rc = unsafe {
        libc::renameat2(
            directory.as_raw_fd(),
            source.as_ptr(),
            directory.as_raw_fd(),
            quarantine.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let rc = -1;
    if rc != 0 {
        let e = io::Error::last_os_error();
        return if e.kind() == io::ErrorKind::NotFound {
            Ok(false)
        } else {
            Err(e)
        };
    }
    let quarantine_name = quarantine.to_str().map_err(|_| invalid())?;
    if !matches!(file_identity_at(directory, quarantine_name),Ok(Some(id)) if (id.0,id.1)==(identity.0,identity.1))
    {
        #[cfg(target_os = "macos")]
        let restored = unsafe {
            libc::renameatx_np(
                directory.as_raw_fd(),
                quarantine.as_ptr(),
                directory.as_raw_fd(),
                source.as_ptr(),
                libc::RENAME_EXCL,
            )
        };
        #[cfg(target_os = "linux")]
        let restored = unsafe {
            libc::renameat2(
                directory.as_raw_fd(),
                quarantine.as_ptr(),
                directory.as_raw_fd(),
                source.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        let restored = -1;
        return if restored == 0 {
            Ok(false)
        } else {
            Err(invalid())
        };
    }
    if unsafe { libc::unlinkat(directory.as_raw_fd(), quarantine.as_ptr(), 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    directory.sync_all()?;
    Ok(true)
}

#[cfg(unix)]
pub(crate) fn remove_created_file(path: &Path, file: &std::fs::File) -> io::Result<bool> {
    let parent = path.parent().ok_or_else(invalid)?;
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(invalid)?;
    let directory = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(parent)?;
    let meta = file.metadata()?;
    remove_identity_at(
        &directory,
        name,
        (meta.dev(), meta.ino(), meta.ctime(), meta.ctime_nsec()),
    )
}
