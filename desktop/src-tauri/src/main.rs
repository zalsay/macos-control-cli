mod jev;

mod host;
mod store;

use serde_json::Value;
use std::{
    fs::OpenOptions,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};
use store::{Device, Result, Script, Settings, Store};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;

struct App {
    store: Store,
    host: Arc<host::Host>,
    quitting: AtomicBool,
    ble: Arc<std::sync::Mutex<()>>,
}

#[tauri::command]
fn jev_summary(app: State<'_, App>) -> Result<Value> {
    jev::summary(&copis_chrome::config::Store::new(app.store.shared.clone()))
}

#[tauri::command]
fn jev_save(
    app: State<'_, App>,
    name: String,
    url: String,
    model: String,
    key: Option<String>,
) -> Result<Value> {
    jev::save(
        &copis_chrome::config::Store::new(app.store.shared.clone()),
        &name,
        &url,
        &model,
        key.as_deref(),
    )
}

#[tauri::command]
fn jev_change(app: State<'_, App>, name: String, operation: jev::Operation) -> Result<Value> {
    jev::change(
        &copis_chrome::config::Store::new(app.store.shared.clone()),
        &name,
        operation,
    )
}

#[tauri::command]
fn settings(app: State<'_, App>) -> Result<Settings> {
    app.store.settings()
}
#[tauri::command]
fn save_settings(app: State<'_, App>, value: Settings) -> Result<()> {
    app.store.save_settings(&value)
}
#[tauri::command]
async fn choose_path(handle: AppHandle, folder: bool) -> Result<Option<PathBuf>> {
    background(move || {
        let dialog = handle.dialog().file();
        native_path(if folder {
            dialog.blocking_pick_folder()
        } else {
            dialog.blocking_pick_file()
        })
    })
    .await
}
fn native_path(path: Option<tauri_plugin_dialog::FilePath>) -> Result<Option<PathBuf>> {
    path.map(|p| p.into_path().map_err(|e| e.to_string()))
        .transpose()
}
async fn background<T: Send + 'static>(
    f: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| e.to_string())?
}
fn call(cmd: &mut Command) -> Result<Value> {
    let output = cmd.output().map_err(|e| e.to_string())?;
    let parsed: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| "未收到 MCC JSON 回执，请检查所选构建包")?;
    if output.status.success() && parsed["ok"] == true {
        Ok(parsed)
    } else {
        Err(parsed["error"]["message"]
            .as_str()
            .unwrap_or("MCC 操作失败")
            .to_owned())
    }
}
#[tauri::command]
async fn generate_token(app: State<'_, App>) -> Result<PathBuf> {
    app.store.private_root()?;
    let cmd = app.store.binary("mcc")?;
    let shared = app.store.shared.clone();
    let name = copis_chrome::protocol::random_id().map_err(|e| e.message)?;
    let path = app.store.root.join(format!("host-{name}.token"));
    background(move || {
        call(
            host::command(&cmd, &shared)
                .args(["host", "token", "init", "--output"])
                .arg(&path),
        )?;
        Ok(path)
    })
    .await
}
#[tauri::command]
async fn generate_tls(app: State<'_, App>, identity: String) -> Result<Value> {
    app.store.private_root()?;
    let cmd = app.store.binary("mcc")?;
    let shared = app.store.shared.clone();
    let id = copis_chrome::protocol::random_id().map_err(|e| e.message)?;
    let dir = app.store.root.join(format!("tls-{id}"));
    let flag = if identity.parse::<std::net::IpAddr>().is_ok() {
        "--ip"
    } else {
        "--dns"
    };
    background(move || {
        call(
            host::command(&cmd, &shared)
                .args(["host", "tls", "init", flag, &identity, "--output-dir"])
                .arg(dir),
        )
    })
    .await
}
#[tauri::command]
fn host_status(app: State<'_, App>) -> Result<host::State> {
    app.host.state()
}
#[tauri::command]
fn host_start(app: State<'_, App>) -> Result<host::State> {
    let settings = app.store.settings()?;
    app.host
        .start(&app.store.binary("mcc")?, &app.store.shared, &settings)
}
#[tauri::command]
fn host_stop(app: State<'_, App>) -> Result<host::State> {
    app.host.stop()
}
#[tauri::command]
fn ble_selection(app: State<'_, App>) -> Result<Option<Device>> {
    app.store.device()
}
#[tauri::command]
async fn ble_discover(app: State<'_, App>) -> Result<Vec<Device>> {
    let path = app.store.binary("macos-ble-control")?;
    let shared = app.store.shared.clone();
    let lock = app.ble.clone();
    background(move || {
        let _guard = lock.try_lock().map_err(|_| "蓝牙操作正在执行")?;
        mbc(&path, &shared, &["--discover-json"])
    })
    .await
}
#[tauri::command]
async fn ble_test(app: State<'_, App>, id: String, save: bool) -> Result<Device> {
    let path = app.store.binary("macos-ble-control")?;
    let shared = app.store.shared.clone();
    let lock = app.ble.clone();
    let store = app.store.clone();
    background(move || {
        let _guard = lock.try_lock().map_err(|_| "蓝牙操作正在执行")?;
        let device: Device = mbc(&path, &shared, &["--probe-json", &id])?;
        if !device.id.eq_ignore_ascii_case(&id) {
            return Err("设备回应与所选 ID 不符".into());
        }
        if save {
            store.save_device(&device)?;
        }
        Ok(device)
    })
    .await
}
fn mbc<T: serde::de::DeserializeOwned>(path: &Path, shared: &Path, args: &[&str]) -> Result<T> {
    let output = host::command(path, shared)
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(stdout
            .lines()
            .chain(stderr.lines())
            .find(|l| l.starts_with("ERROR:"))
            .unwrap_or("MBC 没有返回成功回执")
            .chars()
            .take(300)
            .collect());
    }
    let last = stdout.lines().last().ok_or("没有蓝牙回执")?;
    serde_json::from_str(last).map_err(|_| "蓝牙回执无效，请选择包含新版 MBC 的构建包".into())
}
#[tauri::command]
fn ble_clear(app: State<'_, App>) -> Result<()> {
    let _guard = app.ble.try_lock().map_err(|_| "蓝牙操作正在执行")?;
    app.store.clear_device()
}
#[tauri::command]
fn scripts(app: State<'_, App>) -> Result<Vec<Script>> {
    app.store.scripts()
}
#[tauri::command]
fn script_save(
    app: State<'_, App>,
    id: Option<String>,
    name: String,
    content: String,
) -> Result<Script> {
    app.store.save_script(id, name, content)
}
#[tauri::command]
fn script_delete(app: State<'_, App>, id: String) -> Result<()> {
    app.store.delete_script(&id)
}
#[tauri::command]
fn script_path(app: State<'_, App>, id: String) -> Result<String> {
    Ok(app.store.export_path(&id)?.to_string_lossy().into_owned())
}
#[tauri::command]
async fn script_import(app: State<'_, App>, handle: AppHandle) -> Result<Option<Script>> {
    let store = app.store.clone();
    background(move || {
        let Some(path) = native_path(
            handle
                .dialog()
                .file()
                .add_filter("JSON", &["json"])
                .blocking_pick_file(),
        )?
        else {
            return Ok(None);
        };
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("导入的脚本")
            .to_owned();
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(path)
            .map_err(|e| e.to_string())?;
        let text = String::from_utf8(store::read_bounded(
            &mut file,
            copis_chrome::script::MAX_BYTES,
        )?)
        .map_err(|_| "脚本必须是 UTF-8 JSON")?;
        Ok(Some(store.save_script(None, name, text)?))
    })
    .await
}
#[tauri::command]
async fn script_export(app: State<'_, App>, handle: AppHandle, id: String) -> Result<bool> {
    let item = app.store.script(&id)?;
    background(move || {
        let filename = format!("{}.json", item.name.replace(['/', ':', '\\'], "-"));
        let Some(path) = native_path(
            handle
                .dialog()
                .file()
                .set_file_name(filename)
                .add_filter("JSON", &["json"])
                .blocking_save_file(),
        )?
        else {
            return Ok(false);
        };
        store::write_atomic(&path, item.content.as_bytes())?;
        Ok(true)
    })
    .await
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let store = Store::new(app.path().home_dir()?).map_err(std::io::Error::other)?;
            app.manage(App {
                store,
                host: Arc::new(host::Host::default()),
                quitting: AtomicBool::new(false),
                ble: Default::default(),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            jev_summary,
            jev_save,
            jev_change,
            settings,
            save_settings,
            choose_path,
            generate_token,
            generate_tls,
            host_start,
            host_status,
            host_stop,
            ble_selection,
            ble_discover,
            ble_test,
            ble_clear,
            scripts,
            script_save,
            script_delete,
            script_path,
            script_import,
            script_export
        ])
        .build(tauri::generate_context!())
        .expect("MCC Control Panel")
        .run(|handle, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                let app = handle.state::<App>();
                match app.host.prepare_exit() {
                    Ok(true) => {
                        api.prevent_exit();
                        if app.quitting.swap(true, Ordering::AcqRel) {
                            return;
                        }
                        let host = app.host.clone();
                        let handle = handle.clone();
                        std::thread::spawn(move || {
                            while host.state().is_ok_and(|s| s.phase != "stopped") {
                                std::thread::sleep(std::time::Duration::from_millis(100));
                            }
                            handle.exit(0);
                        });
                    }
                    Ok(false) => {}
                    Err(e) => {
                        api.prevent_exit();
                        eprintln!("{e}");
                    }
                }
            }
        });
}

#[cfg(test)]
mod tests {
    #[test]
    fn script_validation_preserves_both_frame_modes() {
        assert!(
            !super::store::validate_script(r#"{"version":1,"steps":[{"action":"observe"}]}"#)
                .unwrap()
        );
        assert!(super::store::validate_script(
            r#"{"version":1,"steps":[{"action":"click","x":1,"y":1,"eb":true}]}"#
        )
        .unwrap());
        assert!(super::store::validate_script(
            r#"{"version":1,"steps":[{"action":"click","x":1,"eb":true}]}"#
        )
        .is_err());
    }
}
