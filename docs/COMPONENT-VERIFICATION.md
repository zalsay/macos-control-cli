# 内置 Chrome 工具组件化验证（2026-10-19）

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

## 已交付行为

- 内置七个 ChromeDesktop 工具名与 capability/token 会话边界保留；原生截图和输入调用已激活的 `chrome-desktop-cli` 组件。
- 移除 Electron 内的旧 Swift helper、旧子进程客户端、默认构建步骤、renderer 向 Agent 回传帧的 IPC；模型图片不依赖视频预览。
- 可选组件仅在 macOS 显示/安装，初始独立版本 0.1.0；功能模块设置复用 Jotai 安装、下载进度、检查更新与升级。
- 下载与发布复用 manifest/SHA256、版本目录与 active 指针。已有连接固定版本，新连接读取最新 active；组件更新不覆盖旧进程文件。
- 预览拒绝、缺失、等待或轨道结束不阻塞/撤销原生连接；保持窗口选择、停止、预览重试与顶部完整预览 Tab。
- 每帧可以重复输入，没有时间硬过期；保留最近32帧。显式 Stop/退出等待组件停止确认，失败不返回假成功。

## 自动化与构建

36个相关Bun测试文件共444项通过，含组件客户端82项、服务与授权63项、Chrome安装/更新35项。执行了组件客户端真实 CLI 子进程协议测试、Service 会话与幂等回执测试、IPC可信顶层边界测试、renderer组件行为测试、模块注册和单模块发布测试、既有功能模块安装/启动/manifest/store回归。含 module mock 的测试文件使用独立 Bun 进程。

- `bun run typecheck`：所有工作区通过。
- 自包含 Copis CLI 构建通过，主Agent复核实际编译二进制的本机模型fixture，七个Chrome工具注册检查7/7通过。
- Electron `build:main`、`build:preload`、`build:agent-rpc-worker`、`build:renderer`：通过。renderer 仅有现有 chunk 体积提示。
- 独立包 `cargo test --locked`：27项通过；`cargo fmt --check`、严格 Clippy 通过。
- Windows宿主的真实Unix进程/文件系统fixture跳过，Linux/Windows拒绝路径的纯逻辑测试保留。Windows跳过注册已通过本机模拟验证，未在实际Windows/Linux主机执行。
- `bash -n deploy.sh`：通过。PowerShell部署入口相关测试通过；当前macOS环境没有pwsh，未运行PowerShell解释器。

## 真实归档只读安装

使用本机生成的 `copis-chrome-0.1.0-darwin-arm64.tar.gz`：

1. `prepare:chrome-desktop-cli-module` 校验顶层目录、module.json、双 Mach-O 架构与执行位，准备发布归档。
2. 生成只包含 Chrome 可选组件的本地 manifest（占位公开 URL，没有上传或请求远端）。
3. 在临时模块根目录经 manager 下载、SHA256 校验、缓存、解包并激活。
4. 用实际 component client 从受管路径调用原生 `permissions`（不带 `--request`）和 `windows`。
5. 确认 screen/accessibility 均 true、componentVersion 为 0.1.0，枚举到2个 Chrome窗口；未输出窗口标题。
6. cancel 后临时 runtime/组件根目录清理完成，没有遗留 Chrome 组件进程。
7. 将同一已验证归档安装到本机 `~/.copis/modules/`，正式受管状态为 installed=true/version=0.1.0/required=false，再次只读权限与列窗通过，后台进程已停止。

没有实际截图或点击输入，也没有请求系统授权。未用截图代替 Electron UI 验收。

## 审查与交付边界

独立 reviewer 负责授权、更新固定、取消、预览与发布链集成审查。已修复并经定向复核关闭全局客户端版本门槛误阻止兼容组件更新、激活前缺少metadata校验、首次停止失败后重试假成功三项P2；停止失败保留原session/control绑定的待清理记录，确认前不允许新连接，工具和IPC都真正重试。未提供专用 @code-simplifier 工具，使用独立简化审查，未声称调用不存在的工具。

v0.1.1 已通过受管 CLI 执行真实键盘导航并完成焦点回归，详见 [FOCUS-VERIFICATION.md](FOCUS-VERIFICATION.md)。仍需用户在真实 Electron 窗口确认模块卡片、授权选窗、预览失败/恢复与顶部 Tab；真实鼠标输入尚未验收。本地代码已整合到 main，未推送或发布 COS。远端未发布本组件前，其他安装环境不能通过线上 manifest 下载它；开发代码与发布入口已经准备就绪。

根 README.md 与 AGENTS.md 未修改（按仓库要求，更新它们需用户允许）。原主工作区的聊天室未提交改动未触碰。
