# macos-ble-control (mbc)

MCC 项目内的 ESP32-S3 BLE 控制客户端，使用 Swift、CoreBluetooth 和 CoreGraphics。源码从此前 `/Volumes/RC500/dev/esp32-s3-mouse-probe` 中已经验证的客户端纳入，保留原参数和 NUS 协议，不依赖该目录运行或构建，也不包含 ESP 固件、闪存备份或实验环境。

- `MBCMain.swift`：复用原 BLE 连接、顺序写入、回执和命令超时逻辑。
- `MBCOptions.swift`：参数校验、命令计划、ASCII 文本分段及空白字符处理。
- `Info.plist`：嵌入两个 CLI 可执行文件，为 macOS 蓝牙 TCC 提供非空用途说明，并沿用稳定签名标识。
- `build.sh`：原生构建并签名 `macos-ble-control` 和 `mbc` 两个等价可执行文件。
- `install.sh`：可选的独立 MBC 用户级安装；不修改 MCC 安装或 shell 配置。
- `tests/test_mbc_cli.py`：CLI 定向测试，全部使用帮助、无效参数或 `--dry-run`，不发送实际输入。

## 构建和运行

在 MCC 项目根目录执行，需要 macOS 和 Xcode Command Line Tools：

```bash
sh mbc/build.sh
./target/mbc/mbc --help
./target/mbc/mbc --status
./target/mbc/mbc --move 52,54 --click
./target/mbc/mbc --type 'Hello 123!' --key enter
./target/mbc/mbc --dry-run --move 52,54 --click
```

`sh mbc/build.sh /absolute/output-dir` 可指定输出目录；默认 `target/mbc/`。最低部署目标为 macOS 14，默认 ad-hoc 签名，可沿用 `COPIS_CHROME_SIGN_IDENTITY` 选择签名身份。

MCC 的 `bash build.sh` / `bash build.sh debug` 会同时构建这两个客户端，将源码、脚本和测试纳入功能包的 `source/mbc/`。功能包中的 `mcc --eb` 优先调用同目录 `macos-ble-control`，缺失时兼容 PATH 中的客户端；已存在的包内客户端执行失败不会改用 PATH 重试。见 [MCC ESP BLE 接口](../docs/ESPBLE.md)。

## 参数

```text
--help / -h         本地帮助，不连接 BLE
--move x,y          0–100 整数屏幕百分比，S3 端计算曲线
--click [x,y]       移动并左键单击；省略坐标取前一目标，否则读控制端主屏指针
--type "text"       美式键盘可打印 ASCII、换行、Tab；长文本自动分段并保留空格
--key cmd+a        单键或组合键，支持 cmd/gui、ctrl、shift、alt
--scroll v[,h]      -127–127，正数向上/右，负数向下/左
--status            查询固件连接状态
--dry-run           JSON 命令计划，不连接 BLE
```

设备名沿用 `pilot-2`。NUS 服务 UUID 为 `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`，RX 和 TX 分别为同前缀的 `0002` 和 `0003`。客户端不打开 USB 串口。新版 MBC 在每次移动或点击前读取 HID 接收 Mac 的主屏逻辑尺寸并同步给固件，收到 `OK screen <宽> <高>` 后才发送指针动作。需配套支持 `screen` 命令的固件；旧固件不会回退到固定尺寸。命令坐标仍为百分比。远端以 Host Mac 为准。无坐标点击读取控制端指针时会取整，且要求控制端和 HID 接收端是同一台 Mac。

MCC Host 的普通输入可追加 `--eb`，由原 helper 逐条授权后交给此客户端执行；该接口仍接收截图像素坐标并返回 MCC JSON。内部进程参数 `--host-controlled` 只增加 stdin/stdout 的逐条授权握手，复用现有参数校验、BLE 连接和 ACK；不修改固件协议，也不更改上面的独立 CLI 用法。具体边界见 [Host 操作级 ESP 输入](../docs/ESPBLE.md#per-operation-esp-input-through-host)。

组合参数按顺序执行，逐条等待 BLE 写入确认和固件回执；连接和每条命令分别超时 20 秒，失败即停止、不自动重试。输入作用于目标 Mac 当前焦点。`OK` 只确认固件处理，界面结果需另行观察。文字输出取决于目标 Mac 的输入源，暂不支持中文/任意 Unicode 直接输入。

## 定向测试及可选独立安装

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s mbc/tests -p test_mbc_cli.py -v
sh mbc/install.sh --help
# 需要独立安装 MBC 时，显式执行：
sh mbc/install.sh
```

独立安装默认生成 `~/.local/bin/mbc` 和 `~/.local/bin/macos-ble-control` 链接，真实文件为 `~/.local/lib/macos-ble-control/macos-ble-control`，支持 `--prefix /absolute/path`。MCC 的整体安装则将包内客户端放入 MCC 稳定运行目录，不改写已有独立 MBC 命令。
