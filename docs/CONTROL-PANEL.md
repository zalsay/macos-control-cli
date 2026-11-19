# MCC 控制台（macOS）

MCC 控制台是单独构建的 Tauri App，管理本机 Host、MBC 的 ESP32 目标、JSON 脚本库和 Jev 配置。要求 macOS 14 或更新版本。App 本身不包含 MCC、MBC 或原生 helper；请用同一份源码构建完整 MCC 包，再在 App 里选择包目录。

## 构建并打开

在仓库根目录使用已有 Rust、Xcode Command Line Tools 和 Tauri 2 CLI：

```sh
bash build.sh debug
cd desktop
cargo tauri build --debug --bundles app -- --locked
open 'src-tauri/target/debug/bundle/macos/MCC Control Panel.app'
```

在 Host 页的「MCC / MBC 完整构建包目录」选择仓库 `dist/copis-chrome-4.0.0-darwin-arm64/`（Intel Mac 使用 `darwin-x64`），先保存。也可在该目录的安装已更新时使用默认 `~/Applications/MCC/`。面板依赖本次配套构建的 Host 启动回执及 MBC 设备命令；旧版本不能完成这些功能。

## Host 服务

设置监听地址、端口、TLS 证书、私钥和 token 文件。默认监听 `127.0.0.1:8765`。可生成独立 token，或选择已有的私有 token 文件；面板只保存路径。生成自签证书时输入客户端访问用的域名或 IP，分发结果中的**公共 CA**及通过可信渠道传递的 token。更多配置见 [Host 使用说明](REMOTE-HOST.md)。

保存后点「启动 Host」。面板收到 Host 完成绑定的回执才显示正在监听。正在运行时可修改并保存配置，下次启动时生效。停止和退出只正常关闭面板自己启动的 Host，不接管其他 Host 或本机 daemon。

## 蓝牙设备

点「扫描设备」，选择一个候选设备并「测试并保存」。`pilot-2` 固件可能只广播 HID；发现时会列出该名称的候选设备，是否支持 NUS 命令由实际 `status` 交换确认。也可输入已知的本机 CoreBluetooth UUID。测试只读状态，键鼠 HID 仍需通过 macOS 的系统蓝牙设置配对。蓝牙权限以 macOS 的实际提示与系统设置为准。

设备选择保存于 `~/.config/mcc/ble-device.json`，`MCC_CONFIG_DIR` 可覆盖目录。共用该目录的新版 `mbc`、`mcc --eb` 和本机 Host ESP 步骤会使用它。选择失效时不会回退到同名设备；「恢复默认」后重新按 `pilot-2` 查找。不同 Mac 上的 UUID 不能互用。

## 脚本库

可新建、导入、校验、搜索、编辑、复制和导出 [MCC JSON 脚本](SCRIPT.md)。`eb: true` 的步骤会在编辑器顶部标出；校验失败会显示步骤编号（如适用）。删除只移除库内副本。保存后点「CLI 命令」复制模板，将连接 ID（需要时也包括帧 ID）替换为当前会话的实际值。流程仍通过 `mcc script` 执行；面板中没有运行脚本的入口。

面板配置和脚本库存于 `<MCC_CONFIG_DIR>/control-panel/`，默认 `~/.config/mcc/control-panel/`。CLI 命令使用的库内导出路径会在再次复制命令时更新，独立导出文件则不随库变更。

## 客户端设置：Jev

在「客户端设置」新建或编辑配置，填写完整 Decisions API URL、模型名称和 API key。可选择默认配置，也可分别启用或停用已有配置。保存到 MCC 共用的 `models.toml`，不需要重启服务。已有密钥只显示 `sk-********` 这样的掩码提示；端点不变时留空可保留原密钥，更换端点时须重新输入密钥。保存配置不会发送模型请求。

本机命令及使用同一 `MCC_CONFIG_DIR` 的本机 Host 共享此配置。连接其他机器时，`mcc --remote` 使用远端 Host 自己的配置。完整字段和限制见 [Jev 模型配置](MODEL-CONFIG.md)。
