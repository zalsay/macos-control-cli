# 内置 Chrome Tool 组件化（2026-10-19）

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

## 目标与行为

内置 ChromeDesktopStart/Observe/Click/Scroll/Type/Press/Stop 的工具名、会话 capability 与用户选择窗口保持兼容，实际截图和输入改为调用独立 chrome-desktop-cli 功能模块。模块仅支持 macOS 14+、可从功能模块设置按独立版本安装与更新；不要求更新 Electron。沿用 manifest 的版本、SHA256、下载、受管版本目录和 active.json，不创建另一套更新系统。

Chrome 模块为可选组件，不能成为 Windows/Linux 或整个应用启动的必选项。首次用户发起 Chrome 工具时允许按需准备模块；缺少可用发布 artifact 时明确提示到功能模块设置安装/重试，不能回退到旧的内置 Swift helper。模块列表呈现版本与更新状态，使用现有 Jotai 状态。

## 调用与更新边界

Electron 主进程中的轻量 component client 将工具动作映射为 copis-chrome CLI，保持 connectionId 仅在主进程内存；截图文件只从该组件私有运行目录读取，转为单次模型图片输入。模型仍只收到当前 Observe 图片，不积累 base64 历史。Observe 直接使用原生截图，不依赖 renderer 截帧。Electron 实时视频流仅用于现有预览，预览失败不能导致原生连接失败。

每个 Copis 主进程使用独立运行目录，与用户终端 CLI 连接隔离。一次已建立控制固定 component version/path，更新只改变 active 指针；当前动作与连接继续用旧目录，下次新连接解析新版本。取消/停止走独立命令，不等待正在执行的输入；模块超时或 EOF 不能被解释为成功。不可通过 PATH 或任意环境变量绕过受管模块路径。

同一 native frameId 可多次使用，没有时间硬过期；保留最近32帧，检查本控制归属和几何。Rust 负责原生坐标、焦点检查和自动恢复前台，Electron 不维护第二套输入控制逻辑。读取不切前台。原有紧急停止快捷键、跨 turn 复用控制和鉴权仍由 ChromeDesktopService 保留。

## 实施任务

- [x] 组件契约与版本管理：模块名 chrome-desktop-cli、macOS optional 定义、设置列表、独立版本锁、manifest/发布参数和受控构建入口；移除 Electron 默认构建中的旧 helper。
- [x] component client：受管版本解析、按需准备、CLI JSON 协议、连接/图像/输入/取消、版本固定和下次连接升级，先写BDD回归。
- [x] ChromeDesktopService：保留会话和工具契约，原生帧与输入委派组件，替换旧 helper 调用与 renderer 截帧依赖，保留32帧和幂等回执。
- [x] 预览与 IPC：窗口选择与授权流程兼容，视频预览改为尽力启动；预览轨道丢失不能撤销原生连接，停止/退出清理。
- [x] 验证：分别运行有 module mock 的 Bun 测试进程、Rust 测试、typecheck、main/preload/renderer/worker 构建、真实已激活组件只读 smoke。
- [x] 独立代码审查和简化，交付具体测试结果；Electron UI 与真实输入留给用户在实际窗口确认。

## 权限与范围

不安装新依赖，不上传 COS、不发布、不操作真实 Chrome 输入、不修改根 README/AGENTS（更新需用户允许）。发布脚本只增加能力并用本地 manifest 验证，远端发布由用户后续明确发起。继续使用 codex/chrome-desktop-cli 隔离 worktree，保留主工作区未提交聊天室修改。

## 验证与本机状态

验证明细见 COMPONENT-VERIFICATION.md。内置工具已完整委派组件，旧 helper 与 renderer 帧 IPC 已移除。本机正式配置目录中的 chrome-desktop-cli v0.1.4 已按受管流程安装激活；权限、列窗、恢复前台与原生提示生命周期验证通过，验证后台进程已停止。焦点修复与实测见 FOCUS-VERIFICATION.md。未发布线上归档或 manifest；默认开发/应用构建不捆绑该组件。

v0.1.2 在原生 CLI 恢复 Chrome 前台后展示屏幕顶部操作提示，默认 3 秒；连续输入不重复弹出，读取不提示。AppKit 状态与受管 CLI 验证见 TOAST-VERIFICATION.md，视觉效果由用户在实际屏幕确认。

v0.1.3 针对系统截图服务断连/超时加入受限的系统单窗口采集回退，不切换前台；错误保留白名单原生码和固定原因。排查与验证见 CAPTURE-VERIFICATION.md。既有连接需显式停止后重新开始，才使用当前 active 组件。

v0.1.4 指针输入联合检查 WindowServer 的实际事件接收窗口和 AX 命中，避免误拒鼠标可穿透的绘制层；真实输入遮挡和未知归属仍拒绝，没有应用白名单或裸 CGEventPost 兜底。只读回归与兼容边界见 POINTER-VERIFICATION.md。
