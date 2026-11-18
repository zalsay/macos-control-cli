use copis_chrome::{protocol::Scope, script};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    net::IpAddr,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

pub type Result<T> = std::result::Result<T, String>;
fn io(e: std::io::Error) -> String {
    e.to_string()
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Settings {
    pub bin_dir: PathBuf,
    pub host: HostConfig,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct HostConfig {
    pub address: IpAddr,
    pub port: u16,
    pub certificate: PathBuf,
    pub private_key: PathBuf,
    pub token_file: PathBuf,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
}
#[derive(Serialize, Deserialize)]
pub struct Script {
    pub id: String,
    pub name: String,
    pub content: String,
    pub needs_frame: bool,
}

#[derive(Clone)]
pub struct Store {
    pub root: PathBuf,
    pub shared: PathBuf,
    home: PathBuf,
}
impl Store {
    pub fn new(home: PathBuf) -> Result<Self> {
        let shared = std::env::var_os("MCC_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".config/mcc"));
        if !shared.is_absolute() {
            return Err("MCC_CONFIG_DIR 必须为绝对路径".into());
        }
        Ok(Self {
            root: shared.join("control-panel"),
            shared,
            home,
        })
    }
    pub fn default_settings(&self) -> Settings {
        Settings {
            bin_dir: self.home.join("Applications/MCC"),
            host: HostConfig {
                address: IpAddr::V4(std::net::Ipv4Addr::LOCALHOST),
                port: 8765,
                certificate: self.root.join("tls/host-cert.pem"),
                private_key: self.root.join("tls/host-key.pem"),
                token_file: self.root.join("host.token"),
            },
        }
    }
    pub fn settings(&self) -> Result<Settings> {
        Ok(read_json(&self.root.join("settings.json"))?.unwrap_or_else(|| self.default_settings()))
    }
    pub fn save_settings(&self, entry: &Settings) -> Result<()> {
        if entry.host.port == 0
            || [
                &entry.bin_dir,
                &entry.host.certificate,
                &entry.host.private_key,
                &entry.host.token_file,
            ]
            .iter()
            .any(|p| !p.is_absolute())
        {
            return Err("端口须为 1–65535；所有文件和目录须为绝对路径".into());
        }
        self.private_root()?;
        write_json(&self.root.join("settings.json"), entry)
    }
    pub fn private_root(&self) -> Result<()> {
        private_dir(&self.shared)?;
        private_dir(&self.root)
    }
    pub fn binary(&self, name: &str) -> Result<PathBuf> {
        let p = self.settings()?.bin_dir.join(name);
        if !p.is_absolute() || !p.is_file() {
            return Err(format!(
                "未找到 {name}，请在 Host 页选择匹配的 MCC 完整构建包"
            ));
        }
        Ok(p)
    }
    pub fn device(&self) -> Result<Option<Device>> {
        read_json(&self.shared.join("ble-device.json"))
    }
    pub fn save_device(&self, value: &Device) -> Result<()> {
        private_dir(&self.shared)?;
        write_json(&self.shared.join("ble-device.json"), value)
    }
    pub fn clear_device(&self) -> Result<()> {
        remove(&self.shared.join("ble-device.json"))
    }
    pub fn scripts(&self) -> Result<Vec<Script>> {
        let entries = match fs::read_dir(self.root.join("scripts")) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(e) => return Err(io(e)),
        };
        let mut scripts: Vec<Script> = Vec::new();
        for entry in entries {
            let path = entry.map_err(io)?.path();
            if path.extension().and_then(|v| v.to_str()) != Some("json") {
                continue;
            }
            if let Some(item) = read_json(&path)? {
                scripts.push(item);
            }
        }
        scripts.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        Ok(scripts)
    }
    pub fn save_script(&self, id: Option<String>, name: String, content: String) -> Result<Script> {
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 100 || name.chars().any(char::is_control) {
            return Err("脚本名须为 1–100 个可见字符".into());
        }
        let needs_frame = validate_script(&content)?;
        self.private_root()?;
        private_dir(&self.root.join("scripts"))?;
        let id = match id {
            Some(id) => id,
            None => copis_chrome::protocol::random_id().map_err(|e| e.message)?,
        };
        let path = self.script_path(&id)?;
        let script = Script {
            id,
            name: name.into(),
            content,
            needs_frame,
        };
        write_json(&path, &script)?;
        Ok(script)
    }
    fn script_path(&self, id: &str) -> Result<PathBuf> {
        if id.len() != 32 || !id.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("脚本 ID 无效".into());
        }
        Ok(self.root.join("scripts").join(format!("{id}.json")))
    }
    pub fn script(&self, id: &str) -> Result<Script> {
        read_json(&self.script_path(id)?)?.ok_or_else(|| "脚本不存在".into())
    }
    pub fn export_path(&self, id: &str) -> Result<PathBuf> {
        let item = self.script(id)?;
        private_dir(&self.root.join("exports"))?;
        let path = self.root.join("exports").join(format!("{id}.json"));
        write_atomic(&path, item.content.as_bytes())?;
        Ok(path)
    }
    pub fn delete_script(&self, id: &str) -> Result<()> {
        remove(&self.script_path(id)?)?;
        remove(&self.root.join("exports").join(format!("{id}.json")))
    }
}
fn remove(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(io(e)),
    }
}
pub fn validate_script(text: &str) -> Result<bool> {
    if text.len() > script::MAX_BYTES {
        return Err("脚本最多 32 KiB".into());
    }
    let value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    if script::Plan::parse(&value, Scope::Desktop, false).is_ok() {
        return Ok(false);
    }
    match script::Plan::parse(&value, Scope::Desktop, true) {
        Ok(_) => Ok(true),
        Err(e) => Err(
            match e.receipt.as_ref().and_then(|r| r["failedStep"].as_u64()) {
                Some(n) => format!("第 {n} 步：{}", e.message),
                None => e.message,
            },
        ),
    }
}
pub fn private_dir(path: &Path) -> Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .map_err(io)?;
    let meta = fs::symlink_metadata(path).map_err(io)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(format!(
            "目录必须为当前用户的私有目录（0700）：{}",
            path.display()
        ));
    }
    Ok(())
}
fn read_json<T: DeserializeOwned>(path: &Path) -> Result<Option<T>> {
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(io(e)),
    };
    let meta = file.metadata().map_err(io)?;
    if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err("配置须为当前用户的私有普通文件".into());
    }
    let content = read_bounded(&mut file, 256 * 1024)?;
    serde_json::from_slice(&content)
        .map(Some)
        .map_err(|e| e.to_string())
}
pub fn read_bounded(file: &mut File, max: usize) -> Result<Vec<u8>> {
    if !file.metadata().map_err(io)?.is_file() {
        return Err("只允许普通文件".into());
    }
    let mut b = Vec::new();
    file.take(max as u64 + 1).read_to_end(&mut b).map_err(io)?;
    if b.len() > max {
        return Err("文件超出大小上限".into());
    }
    Ok(b)
}
fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    write_atomic(path, &serde_json::to_vec(value).map_err(|e| e.to_string())?)
}
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let name = copis_chrome::protocol::random_id().map_err(|e| e.message)?;
    let tmp = path.with_file_name(format!(".mcc-{name}.tmp"));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(io)?;
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result.map_err(io)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Temp(PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn script_library_keeps_source_separate_and_validates_edits() {
        let temp = Temp(std::env::temp_dir().join(copis_chrome::protocol::random_id().unwrap()));
        private_dir(&temp.0).unwrap();
        let shared = temp.0.join("mcc");
        let store = Store {
            root: shared.join("control-panel"),
            shared,
            home: temp.0.clone(),
        };
        let external = temp.0.join("external.json");
        let text = r#"{"version":1,"steps":[{"action":"observe"},{"action":"click","x":12,"y":34,"eb":true}]}"#;
        fs::write(&external, text).unwrap();
        let imported = store
            .save_script(None, "示例".into(), fs::read_to_string(&external).unwrap())
            .unwrap();
        assert!(store
            .save_script(Some(imported.id.clone()), "错误".into(), "{}".into())
            .is_err());
        assert!(store
            .save_script(None, "过大".into(), " ".repeat(script::MAX_BYTES + 1))
            .is_err());
        assert_eq!(store.scripts().unwrap()[0].name, "示例");
        let exported = store.export_path(&imported.id).unwrap();
        assert_eq!(fs::read_to_string(&exported).unwrap(), text);
        assert_eq!(fs::metadata(&exported).unwrap().mode() & 0o777, 0o600);
        assert!(store.delete_script("../external").is_err());
        store.delete_script(&imported.id).unwrap();
        assert!(!exported.exists());
        assert!(store.scripts().unwrap().is_empty());
        assert_eq!(fs::read_to_string(&external).unwrap(), text);
    }
}
