# 独立 Chrome 桌面自动化功能包

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

独立包保持不依赖 Electron。内置工具组件化接入详见 COMPONENT-INTEGRATION.md；本文件中的“不修改 Electron/部署链”描述独立包第一阶段的边界，后续阶段已由用户明确授权接入。

## 范围与边界

实现用户已确定的独立 CLI + 本地后台进程方案，使用 Rust + Swift，完全位于 `native/chrome-desktop-cli/`，不依赖 Electron、Bun、Node、Pi 或特定模型。不修改当前 Electron 实现、根 README/AGENTS、部署链或现有 CLI。

Rust 负责命令解析、版本化 JSON 协议、Unix socket、单实例后台进程、连接与帧状态、坐标映射、超时和错误。Swift 负责权限、Chrome 窗口身份、后台按需截图、窗口激活、焦点检查和 CGEvent 输入。只支持 macOS 14+；其他平台给出结构化的不支持错误。

## 命令契约

独立可执行文件 `copis-chrome`，默认输出单行 JSON，接受 `--json`；成功退出 0，业务/参数错误退出 1。所有响应有 `protocolVersion: 1` 和 `ok`；失败有 `error: {code, message}`。stdout 不输出日志、图片 base64 或输入文本。帮助与版本单独提供。

- `daemon start|stop|status|run`：自动启动或显式管理后台进程；status 不自动启动。
- `permissions [--request]`：只在显式 request 时请求系统权限。
- `windows`：列出 Chrome 普通窗口及 PID、窗口 ID、逻辑坐标。
- `connect --window <id>`：显式选择窗口，返回随机 `connectionId`；单实例只允许一个控制连接，已有连接返回占用错误而不抢占。
- `status`：返回后台进程和连接状态，不泄露连接凭据。
- `observe --connection <id> [--out <path>]`：不激活窗口；返回 JPEG 绝对路径、图像尺寸、逻辑 bounds、时间和随机 `frameId`。最长边 1600px，大小小于 1MiB；不返回 base64。不覆盖已有输出文件。
- `click --connection <id> --frame <id> --x <n> --y <n> [--count 1|2]`。
- `scroll --connection <id> --frame <id> --x <n> --y <n> --delta-y <n>`，滚动范围 [-1200,1200] 且不能为 0。
- `type --connection <id> --frame <id> --text <text>`，1–4096 Unicode code points，拒绝控制字符。
- `press --connection <id> --frame <id> --key <key>`，沿用 21 个按键白名单。
- `disconnect --connection <id>`：释放连接，清除本连接截图；不撤销系统权限。

## 状态、安全与生命周期

系统权限由 macOS 管理，CLI 不承诺绕过授权或系统撤销。连接跨命令、跨对话复用，直到显式断开、后台进程退出或目标窗口失效。截图帧没有基于时间的硬过期，也不一次性消费；最多保留最近 32 帧，同一连接内几何匹配的任一保留帧均可多次输入。窗口位置或尺寸变化、连接不符或帧被淘汰时拒绝输入并要求重新观察。

输入串行，多 Agent 同时提交返回 BUSY，不排队重放坐标。每次输入前尝试恢复用户选择的 Chrome 窗口，再确认窗口身份、几何和真实焦点；无法确认时不投递。读页面不切前台。输入仍占用系统桌面，不能承诺与用户输入隔离。回执只代表事件已投递，不代表网页业务成功。

使用用户私有运行目录（0700）和 Unix socket（0600），不开放 TCP。connectionId 是同一用户安全边界内的持有者凭据，不写日志、不通过 status 回传。协议输入限长，未知字段和错误参数拒绝。后台进程锁防止启动竞争；退出释放 helper、socket 与私有截图。紧急 `daemon stop` 可打断进行中的输入，取消不能撤回已发送事件。

## 交付与验证

独立 Cargo 包和 Swift 源文件；本目录 `build.sh` 生成包含两个二进制、使用文档和版本元数据的独立 macOS 功能包，不联动根部署。使用 BDD 风格 Rust 单元/进程集成测试，覆盖帧复用、无时间超时、连接占用、几何变化、无权限、取消、helper EOF、协议畸形、输出文件保护、后台进程重启。以假原生 helper 验证输入流程；真实原生测试只做不交互的权限和窗口枚举。真实截图及点击由用户显式授权后验收，不擅自操作当前浏览器。

## 依赖选择与分发

新增依赖前已检索 Cargo 注册表；serde 当前检索为 1.0.229、serde_json 为 1.0.154。本包选择与仓库现有 Rust 服务一致的 serde 1.0.229 与 serde_json 1.0.151，精确约束并提交 Cargo.lock，避免为本功能引入不必要的依赖升级。没有新增第三方 Swift 依赖。遵循仓库 AGPL-3.0-only，分发归档包含许可证和完整功能包源码。
