//! Local CLI adapter for the existing macos-ble-control client.
//! Device discovery, validation, packet splitting and ACKs remain owned by MBC.
use crate::protocol::{Error, Result};
use std::path::PathBuf;

pub enum Action {
    Help,
    Run(Vec<String>),
}

pub fn parse(mut args: Vec<String>) -> Result<Action> {
    let Some(first) = args.first() else {
        return Ok(Action::Help);
    };
    if matches!(first.as_str(), "help" | "--help" | "-h") {
        return Ok(Action::Help);
    }
    match first.as_str() {
        "status" | "move" | "click" | "type" | "key" | "scroll" => {
            args[0] = format!("--{first}");
        }
        "--status" | "--move" | "--click" | "--type" | "--key" | "--scroll" | "--dry-run" => {}
        _ => return Err(Error::invalid("未知 ESP BLE 命令；请运行 mcc --eb --help")),
    }
    Ok(Action::Run(args))
}

pub fn help_text(program: &str) -> String {
    let program = if program == "desktop-control" {
        program
    } else {
        "mcc"
    };
    format!(
        r#"{program} --eb — ESP32 BLE 控制（espble）

用法：
  {program} --eb status
  {program} --eb move 52,54
  {program} --eb click [x,y]
  {program} --eb type 'Hello 123!'
  {program} --eb key cmd+a
  {program} --eb scroll -3,0
  {program} --eb --move 52,54 --click
  {program} --eb --dry-run --move 52,54 --click
  {program} --eb --help

优先复用 MCC 同目录的 macos-ble-control（mbc），缺失时查找 PATH；完整 MCC 构建包已包含客户端。
源码位于 mbc/，也可独立构建；需将 ESP pilot-2 与目标 Mac 配对。
不启动 MCC 的桌面 daemon/helper、模型或 Chrome；仅支持本机调用，不支持 --remote。
直接透传 BLE 客户端的标准输出、标准错误和退出码，不增加 MCC JSON 包装。

坐标为 0–100 整数屏幕百分比，不是普通 MCC 的窗口截图像素；曲线由 S3 计算。
click 省略坐标使用本次参数序列中的前一移动/点击目标；否则读取控制端 Mac 当前主屏指针，
取整到百分比，存在取整偏移；后者要求控制端和 HID 接收端是同一台 Mac。
type 支持美式键盘 ASCII、换行和 Tab，当前不支持直接输入中文；字符取决于目标 Mac 的输入源。
scroll v[,h] 范围 -127–127，正数向上/右，负数向下/左，与普通 MCC 的 --delta-y 符号约定不同。
组合参数沿用 mbc，按顺序执行并等待回执；--dry-run 只显示命令计划，不连接蓝牙。
失败不自动重试或改用软件点击。OK 表示固件处理了命令，需观察目标界面确认实际效果。
MCC 原有暂停/焦点管理不接入此独立 BLE 分支；切换前先结束自己的桌面控制连接，不用它绕过人工暂停。
Host 支持在普通 click/type/press/scroll/click-target 命令后附加 --eb（请求字段 eb:true），仍使用截图像素坐标和 MCC JSON。
例如 mcc --remote <wss-url> --token-file <absolute-token> click --connection <id> --frame <id> --x 100 --y 200 --eb。
详见 docs/ESPBLE.md；未安装 BLE 客户端也可查看本帮助。
"#
    )
}

pub fn execute(action: Action, program: &str) -> Result<i32> {
    let args = match action {
        Action::Help => {
            print!("{}", help_text(program));
            return Ok(0);
        }
        Action::Run(args) => args,
    };
    if !cfg!(target_os = "macos") {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "ESP BLE 控制仅支持 macOS",
        ));
    }
    // Separate argv values preserve literal text; never invoke a shell or retry.
    let status = std::process::Command::new(client_path()?)
        .args(args)
        .status()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                Error::new(
                    "BLE_CLIENT_NOT_FOUND",
                    "未找到 macos-ble-control；请使用完整 MCC 构建包，或独立构建/安装 mbc 并加入 PATH",
                )
            } else {
                Error::io("无法启动 macos-ble-control", error)
            }
        })?;
    Ok(status.code().unwrap_or(1))
}

fn client_path() -> Result<PathBuf> {
    let executable = std::env::current_exe().map_err(|error| Error::io("无法定位 MCC", error))?;
    let executable = std::fs::canonicalize(executable)
        .map_err(|error| Error::io("无法解析 MCC 真实路径", error))?;
    let bundled = executable
        .parent()
        .ok_or_else(|| Error::new("IO_ERROR", "无法定位 MCC 所在目录"))?
        .join("macos-ble-control");
    match std::fs::symlink_metadata(&bundled) {
        // A present but broken/unexecutable bundled client must fail, not select
        // an unrelated PATH executable or replay a partially executed action.
        Ok(_) => Ok(bundled),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(PathBuf::from("macos-ble-control"))
        }
        Err(error) => Err(Error::io("无法检查包内 BLE 客户端", error)),
    }
}
