//! Frame transfer. The host MUST call SessionManager::authorize_frame before load_frame.
use super::protocol::{valid_id, ImageManifest};
use crate::{
    private_files,
    protocol::{Error, Result},
};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::{Path, PathBuf};

const LIMIT: usize = 1024 * 1024;
fn invalid() -> Error {
    Error::new("REMOTE_IMAGE_INVALID", "远程图片无效或无法安全读写")
}
fn same(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    a.dev() == b.dev() && a.ino() == b.ino()
}
fn digest(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes)
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

// Structural JPEG framing only, not an image decoder: check SOI, SOF, SOS, bounded
// segments, entropy stuffing/restart markers and terminal EOI. Pixel data is not decoded.
fn jpeg(bytes: &[u8]) -> bool {
    if bytes.len() < 4 || bytes[..2] != [0xff, 0xd8] {
        return false;
    }
    let (mut i, mut sof, mut scan, mut entropy) = (2, false, false, false);
    while i < bytes.len() {
        if entropy {
            if bytes[i] != 0xff {
                i += 1;
                continue;
            }
            if i + 1 >= bytes.len() {
                return false;
            }
            if bytes[i + 1] == 0 || (0xd0..=0xd7).contains(&bytes[i + 1]) {
                i += 2;
                continue;
            }
            entropy = false;
        }
        if bytes[i] != 0xff {
            return false;
        }
        while i < bytes.len() && bytes[i] == 0xff {
            i += 1;
        }
        if i >= bytes.len() {
            return false;
        }
        let marker = bytes[i];
        i += 1;
        if marker == 0xd9 {
            return sof && scan && i == bytes.len();
        }
        if marker == 0xd8
            || marker == 0
            || marker == 1
            || (0xd0..=0xd7).contains(&marker)
            || i + 2 > bytes.len()
        {
            return false;
        }
        let len = u16::from_be_bytes([bytes[i], bytes[i + 1]]) as usize;
        if len < 2 || i + len > bytes.len() {
            return false;
        }
        if matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) {
            if len < 8 {
                return false;
            }
            let h = u16::from_be_bytes([bytes[i + 3], bytes[i + 4]]);
            let w = u16::from_be_bytes([bytes[i + 5], bytes[i + 6]]);
            let components = bytes[i + 7] as usize;
            if w == 0
                || w > 1600
                || h == 0
                || h > 8192
                || components == 0
                || len != 8 + 3 * components
            {
                return false;
            }
            sof = true;
        }
        if marker == 0xda {
            if !sof || len < 6 || len != 6 + 2 * bytes[i + 2] as usize {
                return false;
            }
            scan = true;
            entropy = true;
        }
        i += len;
    }
    false
}

pub fn load_frame(
    frames_dir: &Path,
    request_id: &str,
    frame_id: &str,
) -> Result<(ImageManifest, Vec<u8>)> {
    if !valid_id(request_id) || !valid_id(frame_id) || !frames_dir.is_absolute() {
        return Err(invalid());
    }
    let before_dir = std::fs::symlink_metadata(frames_dir).map_err(|_| invalid())?;
    private_files::check_private(&before_dir, true).map_err(|_| invalid())?;
    let dir = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
        .open(frames_dir)
        .map_err(|_| invalid())?;
    let opened_dir = dir.metadata().map_err(|_| invalid())?;
    private_files::check_private(&opened_dir, true).map_err(|_| invalid())?;
    if !same(&before_dir, &opened_dir) {
        return Err(invalid());
    }
    let filename = format!("{frame_id}.jpg");
    let path = frames_dir.join(&filename);
    let before = std::fs::symlink_metadata(&path).map_err(|_| invalid())?;
    private_files::check_private(&before, false).map_err(|_| invalid())?;
    if before.nlink() != 1
        || before.permissions().mode() & 0o7777 != 0o600
        || before.len() == 0
        || before.len() >= LIMIT as u64
    {
        return Err(invalid());
    }
    let name = std::ffi::CString::new(filename).map_err(|_| invalid())?;
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(invalid());
    }
    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    let opened = file.metadata().map_err(|_| invalid())?;
    private_files::check_private(&opened, false).map_err(|_| invalid())?;
    if !same(&before, &opened)
        || opened.nlink() != 1
        || opened.permissions().mode() & 0o7777 != 0o600
        || opened.len() != before.len()
    {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    (&file)
        .take(LIMIT as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    let after = std::fs::symlink_metadata(&path).map_err(|_| invalid())?;
    let after_dir = std::fs::symlink_metadata(frames_dir).map_err(|_| invalid())?;
    let after_open = file.metadata().map_err(|_| invalid())?;
    private_files::check_private(&after, false).map_err(|_| invalid())?;
    private_files::check_private(&after_dir, true).map_err(|_| invalid())?;
    if !same(&opened_dir, &after_dir)
        || !same(&opened, &after)
        || !same(&opened, &after_open)
        || after.nlink() != 1
        || after_open.nlink() != 1
        || after.permissions().mode() & 0o7777 != 0o600
        || after_open.permissions().mode() & 0o7777 != 0o600
        || bytes.len() as u64 != opened.len()
        || after.len() != opened.len()
        || after_open.len() != opened.len()
        || !jpeg(&bytes)
    {
        return Err(invalid());
    }
    let manifest = ImageManifest {
        request_id: request_id.into(),
        frame_id: frame_id.into(),
        mime: "image/jpeg".into(),
        bytes: bytes.len() as u64,
        sha256: digest(&bytes),
    };
    Ok((manifest, bytes))
}

pub fn save_frame(
    manifest: &ImageManifest,
    bytes: &[u8],
    output: Option<PathBuf>,
    cache_dir: &Path,
) -> Result<PathBuf> {
    manifest.validate()?;
    if bytes.len() as u64 != manifest.bytes
        || digest(bytes) != manifest.sha256.to_ascii_lowercase()
        || !jpeg(bytes)
    {
        return Err(invalid());
    }
    let path = match output {
        Some(path) if path.is_absolute() => path,
        Some(path) => std::env::current_dir().map_err(|_| invalid())?.join(path),
        None => {
            let metadata = std::fs::symlink_metadata(cache_dir).map_err(|_| invalid())?;
            private_files::check_private(&metadata, true).map_err(|_| invalid())?;
            cache_dir.join(format!(
                "{}-{}.jpg",
                manifest.frame_id,
                crate::protocol::random_id()?
            ))
        }
    };
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(invalid());
    }
    private_files::write_credential_new(&path, bytes).map_err(|error| {
        if error.kind() == std::io::ErrorKind::AlreadyExists {
            Error::new(
                "OUTPUT_EXISTS",
                "输出文件已存在；为避免覆盖，请指定新文件名",
            )
        } else {
            invalid()
        }
    })?;
    Ok(path)
}

#[cfg(test)]
mod review_regressions {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn existing_output_reports_original_error_and_remains_unchanged() {
        let dir = std::env::temp_dir().join(format!(
            "mcc-image-review-{}",
            crate::protocol::random_id().unwrap()
        ));
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        let bytes = [
            0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0, 0xff, 0xda, 0, 8, 1, 1, 0,
            0, 63, 0, 0, 0xff, 0xd9,
        ];
        let manifest = ImageManifest {
            request_id: "r".into(),
            frame_id: "f".into(),
            mime: "image/jpeg".into(),
            bytes: bytes.len() as u64,
            sha256: digest(&bytes),
        };
        let output = dir.join("existing.jpg");
        std::fs::write(&output, b"unchanged").unwrap();
        let error = save_frame(&manifest, &bytes, Some(output.clone()), &dir).unwrap_err();
        assert_eq!(error.code, "OUTPUT_EXISTS");
        assert_eq!(std::fs::read(&output).unwrap(), b"unchanged");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
