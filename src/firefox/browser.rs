//! Own an ordinary Firefox process. No browser automation protocol is started.
use crate::protocol::{Error, Result};
use std::{
    fs::{File, OpenOptions},
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

pub struct Browser {
    child: Child,
    pub pid: i32,
    pub profile: String,
    _profile_lock: File,
    stopped: bool,
}
pub fn validate_profile(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 64
        || name == "."
        || name == ".."
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
    {
        return Err(Error::invalid(
            "profile 名仅允许 1–64 个 ASCII 字母、数字、下划线或连字符",
        ));
    }
    Ok(())
}
fn executable(variable: &str, default: &str) -> Result<PathBuf> {
    let path = PathBuf::from(std::env::var_os(variable).unwrap_or_else(|| default.into()));
    if !path.is_absolute() || !path.is_file() {
        return Err(Error::new(
            "FIREFOX_UNAVAILABLE",
            "Firefox 必须配置为存在的绝对路径",
        ));
    }
    let actual = std::fs::canonicalize(&path).map_err(|e| Error::io("无法解析浏览器路径", e))?;
    if actual.starts_with("/snap") || actual.starts_with("/var/lib/flatpak") {
        return Err(Error::new(
            "BROWSER_PACKAGE_UNSUPPORTED",
            "容器仅支持 Mozilla 官方非 Snap/Flatpak Firefox",
        ));
    }
    Ok(path)
}
#[cfg(unix)]
fn profile_directory(name: &str) -> Result<(PathBuf, File)> {
    use std::os::{
        fd::AsRawFd,
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    };
    let root = if let Some(p) = std::env::var_os("MCC_FIREFOX_PROFILE_ROOT") {
        PathBuf::from(p)
    } else {
        PathBuf::from(std::env::var_os("HOME").ok_or_else(|| Error::invalid("HOME 未设置"))?)
            .join(".local/share/mcc/profiles/firefox")
    };
    if !root.is_absolute() {
        return Err(Error::invalid("profile 根目录必须为绝对路径"));
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&root)
        .map_err(|e| Error::io("无法创建 profile 根目录", e))?;
    let path = root.join(name);
    match std::fs::DirBuilder::new().mode(0o700).create(&path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(Error::io("无法创建 profile", e)),
    }
    for p in [&root, &path] {
        let meta = std::fs::symlink_metadata(p).map_err(|e| Error::io("无法验证 profile", e))?;
        if !meta.is_dir()
            || meta.file_type().is_symlink()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.permissions().mode() & 0o077 != 0
        {
            return Err(Error::new(
                "INSECURE_RUNTIME",
                "Firefox profile 必须是当前用户的 0700 私有目录",
            ));
        }
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path.join(".mcc.lock"))
        .map_err(|e| Error::io("无法打开 profile 锁", e))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(Error::new(
            "PROFILE_IN_USE",
            "profile 已被另一个 owned 会话占用",
        ));
    }
    Ok((path, lock))
}
impl Browser {
    #[cfg(unix)]
    pub fn start(profile: &str, url: Option<&str>) -> Result<Self> {
        use std::os::unix::process::CommandExt;
        validate_profile(profile)?;
        if let Some(raw) = url {
            let u =
                url::Url::parse(raw).map_err(|_| Error::invalid("URL 必须为绝对 HTTP(S) 地址"))?;
            if raw.len() > 4096
                || raw.chars().any(char::is_control)
                || !matches!(u.scheme(), "http" | "https")
                || u.host_str().is_none()
                || !u.username().is_empty()
                || u.password().is_some()
            {
                return Err(Error::invalid("URL 必须为无凭据的绝对 HTTP(S) 地址"));
            }
        }
        let firefox = executable("MCC_FIREFOX_BINARY", "/opt/firefox/firefox")?;
        let (path, lock) = profile_directory(profile)?;
        // Keep existing user preferences, including the user's proxy settings.
        let userjs = path.join("user.js");
        use std::io::{Read, Write};
        use std::os::unix::fs::OpenOptionsExt;
        let mut prefs = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(userjs)
            .map_err(|e| Error::io("无法准备 Firefox profile", e))?;
        let startup_prefs = r#"
// MCC ordinary desktop startup
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.sessionstore.resume_from_crash", false);
"#;
        let mut existing = String::new();
        prefs
            .read_to_string(&mut existing)
            .map_err(|e| Error::io("无法准备 Firefox profile", e))?;
        if !existing.contains(startup_prefs) {
            prefs
                .write_all(startup_prefs.as_bytes())
                .map_err(|e| Error::io("无法准备 Firefox profile", e))?;
        }
        let mut command = Command::new(firefox);
        command
            .args(["--no-remote", "--new-instance", "--profile"])
            .arg(&path)
            .args(["--width", "1200", "--height", "820"])
            .env("MOZ_ENABLE_WAYLAND", "0")
            .env_remove("MOZ_MARIONETTE")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0);
        if let Some(url) = url {
            command.arg("--new-window").arg(url);
        }
        #[cfg(target_os = "linux")]
        unsafe {
            command.pre_exec(|| {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command
            .spawn()
            .map_err(|e| Error::io("无法启动 Firefox", e))?;
        Ok(Self {
            pid: child.id() as i32,
            child,
            profile: profile.into(),
            _profile_lock: lock,
            stopped: false,
        })
    }
    #[cfg(not(unix))]
    pub fn start(_: &str, _: Option<&str>) -> Result<Self> {
        Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "普通 Firefox 后端目前用于 Linux 容器",
        ))
    }
    pub fn is_alive(&mut self) -> bool {
        self.child.try_wait().is_ok_and(|s| s.is_none())
    }
    pub fn abort(&mut self) {
        self.shutdown();
    }
    fn shutdown(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        // Terminate owned descendants even if the main process has exited.
        #[cfg(unix)]
        unsafe {
            libc::kill(-self.pid, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            let exited = self.child.try_wait().is_ok_and(|s| s.is_some());
            #[cfg(unix)]
            let group_gone = unsafe { libc::kill(-self.pid, 0) } != 0;
            #[cfg(not(unix))]
            let group_gone = exited;
            if exited && group_gone {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        #[cfg(unix)]
        unsafe {
            libc::kill(-self.pid, libc::SIGKILL);
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Drop for Browser {
    fn drop(&mut self) {
        self.shutdown();
    }
}
#[cfg(all(test, unix))]
mod native_launch_contract_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn profile_names_cannot_escape_managed_directory() {
        for name in [
            "",
            ".",
            "..",
            "../../personal",
            "one/two",
            "two\\three",
            "user profile",
            "中文",
        ] {
            assert!(validate_profile(name).is_err());
        }
        assert!(validate_profile(&"a".repeat(65)).is_err());
        assert!(validate_profile("smoke-1_test").is_ok());
    }

    #[test]
    fn ordinary_firefox_owns_profile_and_process_without_a_driver() {
        let root = std::env::temp_dir().join(format!("mcc-native-launch-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let binary = root.join("firefox");
        let args = root.join("arguments");
        std::fs::write(
            &binary,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nexec sleep 60\n",
                args.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        let vars = [
            ("MCC_FIREFOX_BINARY", binary.as_os_str()),
            ("MCC_FIREFOX_PROFILE_ROOT", root.as_os_str()),
            (
                "MCC_GECKODRIVER",
                std::ffi::OsStr::new("/missing-geckodriver"),
            ),
        ];
        struct Restore(Vec<(&'static str, Option<std::ffi::OsString>)>);
        impl Drop for Restore {
            fn drop(&mut self) {
                for (k, v) in &self.0 {
                    match v {
                        Some(v) => std::env::set_var(k, v),
                        None => std::env::remove_var(k),
                    }
                }
            }
        }
        let _restore = Restore(
            vars.iter()
                .map(|(k, _)| (*k, std::env::var_os(k)))
                .collect(),
        );
        for (k, v) in vars {
            std::env::set_var(k, v);
        }
        let profile = root.join("ordinary");
        std::fs::create_dir_all(&profile).unwrap();
        std::fs::set_permissions(&profile, std::fs::Permissions::from_mode(0o700)).unwrap();
        let userjs = profile.join("user.js");
        std::fs::write(&userjs, "user_pref(\"network.proxy.type\", 1);\n").unwrap();
        let mut browser = Browser::start("ordinary", Some("https://example.com"))
            .expect("ordinary startup must not require geckodriver");
        let deadline = Instant::now() + Duration::from_secs(2);
        while !std::fs::read_to_string(&args).is_ok_and(|s| s.contains("https://example.com"))
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(5));
        }
        let recorded = std::fs::read_to_string(&args).unwrap();
        assert!(recorded.contains("https://example.com"));
        assert!(!recorded.contains("marionette") && !recorded.contains("remote-debugging"));
        assert!(browser.is_alive());
        assert_eq!(
            Browser::start("ordinary", None).err().unwrap().code,
            "PROFILE_IN_USE"
        );
        let pid = browser.pid;
        drop(browser);
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            -1,
            "owned process must be reaped"
        );
        let first_prefs = std::fs::read_to_string(&userjs).unwrap();
        assert!(first_prefs.contains("network.proxy.type"));
        drop(Browser::start("ordinary", None).unwrap());
        assert_eq!(std::fs::read_to_string(&userjs).unwrap(), first_prefs);
    }
}
