//! Private, local-only persisted configuration. No environment/dotenv credential fallback.
use crate::protocol::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Read;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

use crate::private_files;

const MAX_BYTES: u64 = 64 * 1024;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Model {
    #[serde(default = "enabled_by_default")]
    pub enabled: bool,
    pub url: String,
    pub api_key: String,
    pub model: String,
}
fn enabled_by_default() -> bool {
    true
}
impl std::fmt::Debug for Model {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Model { credentials: [REDACTED] }")
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Models {
    #[serde(default)]
    default_model: Option<String>,
    #[serde(default)]
    models: BTreeMap<String, Model>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct AppConfig {
    chrome: ChromeConfig,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct ChromeConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    profile: Option<String>,
    window: WindowConfig,
}
#[derive(Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct WindowConfig {
    position: String,
    height: String,
    max_width_px: u32,
}
impl Default for WindowConfig {
    fn default() -> Self {
        Self {
            position: "left".into(),
            height: "available".into(),
            max_width_px: 1600,
        }
    }
}

pub struct Store {
    directory: PathBuf,
}
impl Store {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory }
    }
    pub fn from_env() -> Result<Self> {
        let directory = if let Some(path) = std::env::var_os("MCC_CONFIG_DIR") {
            let path = PathBuf::from(path);
            if !path.is_absolute() {
                return Err(invalid());
            }
            path
        } else {
            PathBuf::from(std::env::var_os("HOME").ok_or_else(invalid)?).join(".config/mcc")
        };
        Ok(Self::new(directory))
    }
    pub fn resolve_model(&self, explicit_key: Option<&str>) -> Result<Model> {
        let models = self.models()?;
        let name = models.default_model.as_ref().ok_or_else(|| {
            Error::new(
                "MODEL_NOT_CONFIGURED",
                "请先用 mcc --config set 配置模型并选择 default；不会自动读取 .env",
            )
        })?;
        let mut model = models.models.get(name).cloned().ok_or_else(invalid)?;
        validate_model(&model)?;
        if !model.enabled {
            return Err(Error::new(
                "MODEL_DISABLED",
                "默认模型已禁用；请用 mcc --config enable <name> 启用或显式选择其他已启用的默认模型；未调用模型或执行点击",
            ));
        }
        if let Some(key) = explicit_key {
            model.api_key = crate::jev::resolve_key(Some(key), None)?;
        }
        Ok(model)
    }
    pub fn chrome_start_settings(&self) -> Result<(u32, Option<String>)> {
        let config: AppConfig = self.read("config.toml")?;
        validate_window(&config.chrome.window)?;
        if let Some(profile) = &config.chrome.profile {
            validate_chrome_profile(profile)?;
        }
        Ok((config.chrome.window.max_width_px, config.chrome.profile))
    }
    pub fn window_max_width(&self) -> Result<u32> {
        self.chrome_start_settings().map(|(width, _)| width)
    }
    /// `input` is only read for --api-key-stdin; bounded and never echoed.
    pub fn execute(&self, args: &[String], input: impl Read) -> Result<Value> {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        match args.as_slice() {
            [] => self.summary(),
            ["show", name] => {
                valid_name(name)?;
                let models = self.models()?;
                let model = models.models.get(*name).ok_or_else(invalid)?;
                validate_model(model)?;
                Ok(json!({"name":name,"default":models.default_model.as_deref()==Some(*name),"profile":masked(model)}))
            }
            ["default", name] => {
                valid_name(name)?;
                let _lock = self.lock()?;
                let mut models = self.models()?;
                validate_model(models.models.get(*name).ok_or_else(invalid)?)?;
                models.default_model = Some(name.to_string());
                self.write("models.toml", &models)?;
                Ok(json!({"default_model":name,"saved":true}))
            }
            [command @ ("enable" | "disable"), name] => {
                valid_name(name)?;
                let _lock = self.lock()?;
                let mut models = self.models()?;
                let model = models.models.get_mut(*name).ok_or_else(invalid)?;
                model.enabled = *command == "enable";
                let view = masked(model);
                self.write("models.toml", &models)?;
                Ok(json!({"saved":true,"name":name,"default_model":models.default_model,"profile":view}))
            }
            ["set", name, rest @ ..] => self.set_model(name, rest, input),
            ["window", "--max-width", width] => {
                let width: u32 = width.parse().map_err(|_| invalid())?;
                let _lock = self.lock()?;
                let mut config: AppConfig = self.read("config.toml")?;
                config.chrome.window.max_width_px = width;
                validate_window(&config.chrome.window)?;
                self.write("config.toml", &config)?;
                Ok(json!({"saved":true,"chrome":config.chrome}))
            }
            ["chrome", "--profile", profile] => {
                validate_chrome_profile(profile)?;
                let _lock = self.lock()?;
                let mut config: AppConfig = self.read("config.toml")?;
                validate_window(&config.chrome.window)?;
                config.chrome.profile = Some((*profile).to_owned());
                self.write("config.toml", &config)?;
                Ok(json!({"saved":true,"chrome":config.chrome}))
            }
            ["chrome", "--clear-profile"] => {
                let _lock = self.lock()?;
                let mut config: AppConfig = self.read("config.toml")?;
                validate_window(&config.chrome.window)?;
                config.chrome.profile = None;
                self.write("config.toml", &config)?;
                Ok(json!({"saved":true,"chrome":config.chrome}))
            }
            _ => Err(Error::invalid("配置命令：--config [show <name> | set <name> --url <url> --model <model> --api-key-stdin | default <name> | enable <name> | disable <name> | window --max-width <400..1600> | chrome --profile <name> | chrome --clear-profile]")),
        }
    }
    fn set_model(&self, name: &str, args: &[&str], input: impl Read) -> Result<Value> {
        valid_name(name)?;
        let mut options = BTreeMap::new();
        let mut args = args.iter();
        while let Some(&flag) = args.next() {
            if !["--url", "--model", "--api-key", "--api-key-stdin"].contains(&flag)
                || options.contains_key(flag)
            {
                return Err(invalid());
            }
            let value = if flag == "--api-key-stdin" {
                ""
            } else {
                args.next().copied().ok_or_else(invalid)?
            };
            options.insert(flag, value);
        }
        if options.is_empty()
            || (options.contains_key("--api-key") && options.contains_key("--api-key-stdin"))
        {
            return Err(invalid());
        }
        let key = if options.contains_key("--api-key-stdin") {
            let mut bytes = Vec::new();
            input
                .take(1027)
                .read_to_end(&mut bytes)
                .map_err(|_| invalid())?;
            let text = String::from_utf8(bytes).map_err(|_| invalid())?;
            // Permit a single terminal newline, never arbitrary whitespace or multiple records.
            let key = text
                .strip_suffix("\r\n")
                .or_else(|| text.strip_suffix('\n'))
                .unwrap_or(&text);
            Some(crate::jev::resolve_key(Some(key), None)?)
        } else {
            options
                .get("--api-key")
                .map(|key| crate::jev::resolve_key(Some(key), None))
                .transpose()?
        };
        let _lock = self.lock()?;
        let mut models = self.models()?;
        let previous = models.models.get(name);
        let url = options
            .get("--url")
            .map(|s| s.to_string())
            .or_else(|| previous.map(|p| p.url.clone()))
            .ok_or_else(invalid)?;
        validate_endpoint(&url)?;
        if key.is_none() && previous.is_some_and(|p| p.url != url) {
            return Err(Error::new(
                "MODEL_KEY_REQUIRED",
                "修改端点必须显式提供新 key；不会把旧端点凭据转发给新端点",
            ));
        }
        let model = Model {
            enabled: previous.is_none_or(|p| p.enabled),
            url,
            api_key: key
                .or_else(|| previous.map(|p| p.api_key.clone()))
                .ok_or_else(invalid)?,
            model: options
                .get("--model")
                .map(|s| s.to_string())
                .or_else(|| previous.map(|p| p.model.clone()))
                .ok_or_else(invalid)?,
        };
        validate_model(&model)?;
        let view = masked(&model);
        models.models.insert(name.into(), model);
        if models.default_model.is_none() {
            models.default_model = Some(name.into());
        }
        self.write("models.toml", &models)?;
        Ok(
            json!({"saved":true,"name":name,"default_model":models.default_model,"profile":view,
            "warning":options.contains_key("--api-key").then_some("命令行 key 可能出现在历史或进程列表；建议 --api-key-stdin")}),
        )
    }
    fn models(&self) -> Result<Models> {
        let models: Models = self.read("models.toml")?;
        for (name, model) in &models.models {
            valid_name(name)?;
            validate_model(model)?;
        }
        if let Some(default) = &models.default_model {
            valid_name(default)?;
            if !models.models.contains_key(default) {
                return Err(invalid());
            }
        }
        Ok(models)
    }
    fn summary(&self) -> Result<Value> {
        let models = self.models()?;
        let (max_width_px, profile) = self.chrome_start_settings()?;
        let mut views = BTreeMap::new();
        for (name, model) in &models.models {
            views.insert(name, masked(model));
        }
        let mut summary = json!({
            "models_path":self.directory.join("models.toml"),
            "config_path":self.directory.join("config.toml"),
            "configured":models.default_model.is_some(),
            "default_model":models.default_model,
            "models":views,
            "chrome":{"window":{"position":"left","height":"available","max_width_px":max_width_px}}
        });
        if let Some(profile) = profile {
            summary["chrome"]["profile"] = json!(profile);
        }
        Ok(summary)
    }
    fn read<T: for<'de> Deserialize<'de> + Default>(&self, filename: &str) -> Result<T> {
        if !self.check_directory()? {
            return Ok(T::default());
        }
        let path = self.directory.join(filename);
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(T::default()),
            Err(_) => return Err(invalid()),
        };
        private_files::check_private(&metadata, false).map_err(|_| invalid())?;
        let bytes = private_files::read_private(&path, MAX_BYTES).map_err(|_| invalid())?;
        let text = String::from_utf8(bytes).map_err(|_| invalid())?;
        // TOML errors contain the source line and hence may contain an API key. Discard them.
        toml::from_str(&text).map_err(|_| invalid())
    }
    fn check_directory(&self) -> Result<bool> {
        match std::fs::symlink_metadata(&self.directory) {
            Ok(m) => {
                private_files::check_private(&m, true).map_err(|_| invalid())?;
                Ok(true)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(_) => Err(invalid()),
        }
    }
    fn lock(&self) -> Result<Lock> {
        if !self.check_directory()? {
            if let Some(parent) = self.directory.parent() {
                std::fs::create_dir_all(parent).map_err(|_| invalid())?;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                let mut b = std::fs::DirBuilder::new();
                b.mode(0o700);
                b.create(&self.directory)
                    .or_else(|e| {
                        if e.kind() == std::io::ErrorKind::AlreadyExists {
                            Ok(())
                        } else {
                            Err(e)
                        }
                    })
                    .map_err(|_| invalid())?;
            }
            #[cfg(not(unix))]
            std::fs::create_dir(&self.directory).map_err(|_| invalid())?;
            self.check_directory()?;
        }
        let path = self.directory.join("config.lock");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        options.open(&path).map_err(|_| {
            Error::new(
                "CONFIG_BUSY",
                "配置正在写入，或存在上次异常退出的 config.lock；确认无配置写入者后移除锁文件",
            )
        })?;
        Ok(Lock(path))
    }
    fn write(&self, filename: &str, value: &impl Serialize) -> Result<()> {
        let text = toml::to_string_pretty(value).map_err(|_| invalid())?;
        if text.len() as u64 > MAX_BYTES {
            return Err(invalid());
        }
        let dest = self.directory.join(filename);
        if let Ok(m) = std::fs::symlink_metadata(&dest) {
            private_files::check_private(&m, false).map_err(|_| invalid())?;
        }
        let path = self
            .directory
            .join(format!(".{}.tmp", crate::protocol::random_id()?));
        let result = (|| {
            private_files::write_new(&path, text.as_bytes()).map_err(|_| invalid())?;
            std::fs::rename(&path, &dest).map_err(|_| invalid())?;
            std::fs::File::open(&self.directory)
                .and_then(|f| f.sync_all())
                .map_err(|_| invalid())?;
            Ok(())
        })();
        let _ = std::fs::remove_file(path);
        result
    }
}
struct Lock(PathBuf);
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
fn masked(model: &Model) -> Value {
    json!({"enabled":model.enabled,"url":model.url,"model":model.model,"api_key":"[REDACTED]"})
}
fn valid_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    {
        return Err(invalid());
    }
    Ok(())
}
fn validate_window(window: &WindowConfig) -> Result<()> {
    if window.position != "left"
        || window.height != "available"
        || !(400..=1600).contains(&window.max_width_px)
    {
        return Err(invalid());
    }
    Ok(())
}
pub fn validate_chrome_profile(profile: &str) -> Result<()> {
    let scalar_count = profile.chars().count();
    if !(1..=128).contains(&scalar_count)
        || profile.chars().any(char::is_control)
        || profile.trim() != profile
    {
        return Err(Error::invalid(
            "Chrome profile显示名称须为1–128个Unicode字符，不含控制字符或首尾空白",
        ));
    }
    Ok(())
}
pub fn validate_model(model: &Model) -> Result<()> {
    validate_endpoint(&model.url)?;
    crate::jev::resolve_key(Some(&model.api_key), None)?;
    if model.model.is_empty()
        || model.model.len() > 256
        || !model.model.bytes().all(|c| c.is_ascii_graphic())
    {
        return Err(invalid());
    }
    Ok(())
}
pub fn validate_endpoint(endpoint: &str) -> Result<()> {
    if endpoint.len() > 2048 || !endpoint.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(invalid());
    }
    let url = url::Url::parse(endpoint).map_err(|_| invalid())?;
    let loopback = url.host_str().is_some_and(|h| {
        h == "localhost"
            || h.parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
            || h == "[::1]"
    });
    if !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.query().is_some()
        || url.host_str().is_none()
        || !(url.scheme() == "https" || (url.scheme() == "http" && loopback))
    {
        return Err(invalid());
    }
    Ok(())
}
fn invalid() -> Error {
    Error::new(
        "CONFIG_INVALID",
        "配置无效或无法安全读写；检查 TOML 字段、URL、目录0700/文件0600及所有权（不跟随符号链接）",
    )
}
