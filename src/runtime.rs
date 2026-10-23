use crate::protocol::{Error, Result, Scope};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};

pub struct Runtime {
    pub root: PathBuf,
    pub socket: PathBuf,
    pub frames: PathBuf,
    pub scope: Scope,
}
impl Runtime {
    pub fn from_env() -> Result<Self> {
        Self::from_env_for_scope(Scope::Chrome)
    }

    pub fn from_env_for_scope(scope: Scope) -> Result<Self> {
        let (runtime_variable, default_directory) = match scope {
            Scope::Chrome => ("COPIS_CHROME_RUNTIME_DIR", "chrome-desktop-cli"),
            Scope::Desktop => ("COPIS_DESKTOP_RUNTIME_DIR", "desktop-control-cli"),
        };
        Self::from_values(
            scope,
            runtime_variable,
            default_directory,
            std::env::var_os(runtime_variable),
            std::env::var_os("HOME"),
        )
    }

    fn from_values(
        scope: Scope,
        runtime_variable: &str,
        default_directory: &str,
        override_path: Option<std::ffi::OsString>,
        home: Option<std::ffi::OsString>,
    ) -> Result<Self> {
        let root = match override_path {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(home.ok_or_else(|| {
                Error::new(
                    "RUNTIME_UNAVAILABLE",
                    &format!("HOME 未设置；请指定 {runtime_variable}"),
                )
            })?)
            .join(format!(".copis/{default_directory}")),
        };
        if !root.is_absolute() {
            return Err(Error::invalid("运行目录必须是绝对路径"));
        }
        let socket = root.join("daemon.sock");
        if socket.as_os_str().as_encoded_bytes().len() > 100 {
            return Err(Error::invalid(&format!(
                "运行目录过长，无法创建 macOS Unix socket；请设置较短的 {runtime_variable}"
            )));
        }
        let runtime = Self {
            frames: root.join("frames"),
            root,
            socket,
            scope,
        };
        runtime.validate_paths()?;
        Ok(runtime)
    }
    fn validate_paths(&self) -> Result<()> {
        if [&self.root, &self.frames, &self.socket]
            .iter()
            .any(|path| !path.is_absolute() || path.to_str().is_none())
        {
            return Err(Error::invalid("运行路径必须是有效 UTF-8 绝对路径"));
        }
        Ok(())
    }
    pub fn prepare(&self) -> Result<()> {
        self.validate_paths()?;
        private_dir(&self.root)?;
        private_dir(&self.frames)
    }
    pub fn validate(&self) -> Result<()> {
        self.validate_paths()?;
        check_private(&self.root, true)?;
        match fs::symlink_metadata(&self.socket) {
            Ok(metadata)
                if metadata.file_type().is_socket()
                    && metadata.uid() == uid()
                    && metadata.permissions().mode() & 0o777 == 0o600 =>
            {
                Ok(())
            }
            Ok(_) => Err(Error::new(
                "INSECURE_RUNTIME",
                "socket 必须由当前用户拥有、权限为 0600，且不能为符号链接",
            )),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(Error::io("无法验证 socket", error)),
        }
    }
    // 调用方持有 runtime 锁；先配置私有临时socket，再原子发布正式路径。
    pub fn bind_listener(&self) -> Result<UnixListener> {
        self.bind_listener_with_setup(|listener, path| {
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))
                .map_err(|e| Error::io("无法保护 socket", e))?;
            listener
                .set_nonblocking(true)
                .map_err(|e| Error::io("无法设置 socket 模式", e))
        })
    }

    fn bind_listener_with_setup(
        &self,
        setup: impl FnOnce(&UnixListener, &Path) -> Result<()>,
    ) -> Result<UnixListener> {
        self.validate()?;
        if fs::symlink_metadata(&self.socket).is_ok() {
            return Err(Error::new(
                "INSECURE_RUNTIME",
                "正式 socket 路径已存在，拒绝覆盖",
            ));
        }
        // 名称短于daemon.sock，保留原有Unix socket路径长度契约。
        let pending = self.root.join(".socket");
        if let Ok(metadata) = fs::symlink_metadata(&pending) {
            if !metadata.file_type().is_socket() || metadata.uid() != uid() {
                return Err(Error::new(
                    "INSECURE_RUNTIME",
                    "临时 socket 路径无效，拒绝删除",
                ));
            }
            fs::remove_file(&pending).map_err(|e| Error::io("无法清理旧临时 socket", e))?;
        }
        let listener =
            UnixListener::bind(&pending).map_err(|e| Error::io("无法创建本地 socket", e))?;
        if let Err(error) = setup(&listener, &pending).and_then(|()| {
            fs::rename(&pending, &self.socket).map_err(|e| Error::io("无法发布本地 socket", e))
        }) {
            let _ = fs::remove_file(&pending);
            return Err(error);
        }
        Ok(listener)
    }

    pub fn lock(&self) -> Result<File> {
        let path = self.root.join("daemon.lock");
        let file = secure_file(&path)?;
        file.try_lock()
            .map_err(|_| Error::new("DAEMON_ALREADY_RUNNING", "后台进程已运行或正在启动"))?;
        Ok(file)
    }
    pub fn log(&self) -> Result<File> {
        secure_file(&self.root.join("daemon.log"))
    }
}
fn private_dir(path: &Path) -> Result<()> {
    match DirBuilder::new().recursive(true).mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(Error::io("无法创建私有运行目录", error)),
    }
    check_private(path, true)
}
fn uid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    // 只查询有效 UID，不修改系统状态。
    unsafe { geteuid() }
}
fn check_private(path: &Path, directory: bool) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|e| Error::io("无法验证运行路径", e))?;
    if metadata.file_type().is_symlink()
        || (directory && !metadata.is_dir())
        || (!directory && (!metadata.is_file() || metadata.nlink() != 1))
        || metadata.uid() != uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(Error::new(
            "INSECURE_RUNTIME",
            "运行路径必须由当前用户独占且不可为符号链接；目录权限为 0700，文件权限为 0600",
        ));
    }
    Ok(())
}
fn secure_file(path: &Path) -> Result<File> {
    match OpenOptions::new()
        .create_new(true)
        .read(true)
        .append(true)
        .mode(0o600)
        .open(path)
    {
        Ok(file) => Ok(file),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            check_private(path, false)?;
            let file = OpenOptions::new()
                .read(true)
                .append(true)
                .open(path)
                .map_err(|e| Error::io("无法打开私有运行文件", e))?;
            check_private(path, false)?;
            let opened = file
                .metadata()
                .map_err(|e| Error::io("无法验证私有运行文件", e))?;
            let current =
                fs::symlink_metadata(path).map_err(|e| Error::io("无法验证运行路径", e))?;
            if opened.dev() != current.dev() || opened.ino() != current.ino() {
                return Err(Error::new(
                    "INSECURE_RUNTIME",
                    "私有运行文件在打开时发生变化",
                ));
            }
            Ok(file)
        }
        Err(error) => Err(Error::io("无法创建私有运行文件", error)),
    }
}
pub fn helper_path(scope: Scope) -> Result<PathBuf> {
    let variable = match scope {
        Scope::Chrome => "COPIS_CHROME_HELPER",
        Scope::Desktop => "COPIS_DESKTOP_HELPER",
    };
    let path = if let Some(path) = std::env::var_os(variable) {
        PathBuf::from(path)
    } else {
        // 安装后的 mcc 是 bin/ 下的链接，资源必须相对真实版本目录查找。
        let executable = std::env::current_exe()
            .and_then(fs::canonicalize)
            .map_err(|e| Error::io("无法定位当前可执行文件的真实路径", e))?;
        executable
            .parent()
            .ok_or_else(|| Error::new("HELPER_NOT_FOUND", "无法定位功能包目录"))?
            .join("copis-chrome-helper")
    };
    if !path.is_absolute() || !path.is_file() {
        return Err(Error::new(
            "HELPER_NOT_FOUND",
            "找不到原生 helper；请运行功能包 build.sh，或将 copis-chrome-helper 放在 CLI 同目录",
        ));
    }
    Ok(path)
}

/// 用户指定导出文件只在 CLI 进程中写入，不交给 daemon 处理任意路径。
pub fn export_image(source: &Path, destination: &Path) -> Result<PathBuf> {
    let absolute = if destination.is_absolute() {
        destination.to_owned()
    } else {
        std::env::current_dir()
            .map_err(|e| Error::io("无法解析输出目录", e))?
            .join(destination)
    };
    let data = fs::read(source).map_err(|e| Error::io("无法读取截图", e))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&absolute)
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                Error::new(
                    "OUTPUT_EXISTS",
                    "输出文件已存在；为避免覆盖，请指定新文件名",
                )
            } else {
                Error::io("无法创建输出截图", error)
            }
        })?;
    if let Err(error) = file.write_all(&data) {
        let _ = fs::remove_file(&absolute);
        return Err(Error::io("无法写入输出截图", error));
    }
    Ok(absolute)
}

#[cfg(test)]
mod scope_tests {
    use super::*;
    use std::ffi::OsString;

    #[test]
    fn given_socket_initialization_when_configuring_permissions_then_final_path_stays_unpublished()
    {
        let root = PathBuf::from(format!(
            "/tmp/socket-publish-{}",
            crate::protocol::random_id().unwrap()
        ));
        let runtime = Runtime::from_values(
            Scope::Chrome,
            "COPIS_CHROME_RUNTIME_DIR",
            "chrome-desktop-cli",
            Some(root.clone().into_os_string()),
            None,
        )
        .unwrap();
        runtime.prepare().unwrap();
        let listener = runtime
            .bind_listener_with_setup(|listener, path| {
                assert!(
                    !runtime.socket.exists(),
                    "客户端不应看到尚未设为0600的socket"
                );
                assert_ne!(path, runtime.socket);
                runtime.validate().unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
                listener.set_nonblocking(true).unwrap();
                Ok(())
            })
            .unwrap();
        runtime.validate().unwrap();
        assert_eq!(
            fs::symlink_metadata(&runtime.socket)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(std::os::unix::net::UnixStream::connect(&runtime.socket).is_ok());
        drop(listener);
        fs::remove_file(&runtime.socket).unwrap();
        // 配置失败不发布半成品，也不能覆盖临时路径上的普通文件。
        let failed =
            runtime.bind_listener_with_setup(|_, _| Err(Error::new("TEST_FAILED", "模拟配置失败")));
        assert_eq!(failed.unwrap_err().code, "TEST_FAILED");
        assert!(!runtime.socket.exists());
        let pending = root.join(".socket");
        assert!(!pending.exists());
        fs::write(&pending, b"keep").unwrap();
        assert_eq!(
            runtime.bind_listener().unwrap_err().code,
            "INSECURE_RUNTIME"
        );
        assert_eq!(fs::read(&pending).unwrap(), b"keep");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn given_runtime_override_for_each_mode_then_keep_private_roots_separate() {
        let chrome = Runtime::from_values(
            Scope::Chrome,
            "COPIS_CHROME_RUNTIME_DIR",
            "chrome-desktop-cli",
            Some(OsString::from("/tmp/chrome-private")),
            None,
        )
        .unwrap();
        let desktop = Runtime::from_values(
            Scope::Desktop,
            "COPIS_DESKTOP_RUNTIME_DIR",
            "desktop-control-cli",
            Some(OsString::from("/tmp/desktop-private")),
            None,
        )
        .unwrap();
        assert_eq!(chrome.root, PathBuf::from("/tmp/chrome-private"));
        assert_eq!(desktop.root, PathBuf::from("/tmp/desktop-private"));
    }

    #[test]
    fn given_no_desktop_override_then_use_desktop_default_under_home() {
        let desktop = Runtime::from_values(
            Scope::Desktop,
            "COPIS_DESKTOP_RUNTIME_DIR",
            "desktop-control-cli",
            None,
            Some(OsString::from("/Users/tester")),
        )
        .unwrap();
        assert_eq!(
            desktop.root,
            PathBuf::from("/Users/tester/.copis/desktop-control-cli")
        );
    }
}
