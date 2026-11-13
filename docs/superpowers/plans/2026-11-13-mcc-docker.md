# MCC Docker Implementation Plan

> 执行：按任务并行实现互不重叠的模块，主 agent 负责集成与全部代码审查。

**Goal:** 在 `mcc-docker` 分支交付可构建、可观察和人工接管的 Ubuntu 22.04 Docker Firefox 桌面。

**Architecture:** 保留既有 CLI/daemon/Service/Native 调用链。新增 Rust Linux helper，将浏览器协议与 X11 原生适配封装在既有 helper 边界内；Docker 编排只管理桌面进程及分发。

**Tech Stack:** Rust、x11rb、image、base64、Ubuntu 22.04、Xvfb/Openbox、Firefox/geckodriver、Tesseract、x11vnc/noVNC。

**Spec:** `docs/superpowers/specs/2026-11-13-mcc-docker-design.md`，沿用 `2026-11-10-firefox-webdriver-design.md` 的网页输入约束。

## Global Constraints

- 先理解现有功能再扩展，复用 Service/Native/daemon，不另建绕开门禁的执行器。
- code review 仅由主 agent 执行；实现代理不得再派子代理或提交审查。
- 页面输入仅 WebDriver Actions，无网页脚本注入、无失败后输入后端切换。
- 不覆盖源工作区 `swift/CursorMotion.swift` 的并行修改。
- Ubuntu 22.04 容器、普通用户、独立 Xvfb；noVNC 仅回环发布；保留浏览器 sandbox。
- 有意义的新行为先写失败测试再实现；容器实测验证可见结果。
- 分支保留供用户审阅，不自动推送、合并或部署。

## Task 1: X11 桌面适配（独立实现任务）

**Files:** `src/linux/x11.rs`，只允许此实现文件及同模块测试；Cargo 依赖由主 agent 维护。

**Interfaces:** 使用 `crate::protocol::{Error,Result}` 与 `crate::service::{Window,Bounds}`。

```rust
pub enum DesktopEvent { UserInteraction, FocusChanged, Pause, Resume, Cancel }
pub struct Desktop { /* owns X11 connection and control window */ }
impl Desktop {
    pub fn connect() -> Result<Self>;
    pub fn windows(&self) -> Result<Vec<Window>>;
    pub fn window(&self, id: u32, pid: i32) -> Result<Window>;
    pub fn activate(&self, id: u32) -> Result<()>;
    pub fn focused(&self, id: u32) -> Result<bool>;
    pub fn capture(&self, window: &Window, path: &std::path::Path) -> Result<(u32,u32)>;
    pub fn native_input(&mut self, window: &Window, request: &serde_json::Value) -> Result<()>;
    pub fn poll_events(&mut self) -> Result<Vec<DesktopEvent>>;
    pub fn draw_control(&self, status: &str) -> Result<()>;
}
```

- [x] 检查既有 Window/Native/帧几何协议；以实际 X server 用例验证窗口列表、身份、焦点和截图。
- [x] 实现 X11/EWMH/XRes 窗口身份与原始截图，不信任标题或仅信任 PID 属性。
- [x] 以可见控件提供暂停/继续/取消；通过事件返回而不自建业务许可状态。
- [x] 监测用户输入；不要忽略所有 XTEST 设备，因为 noVNC 也依赖 XTEST。记录并过滤自身精确注入事件，其他输入保留接管信号。
- [x] 原生输入仅使用受限动作，未知能力明确拒绝；上层 helper 掌管许可/epoch 和资源释放。
- [x] 原生动作测试与截图几何测试，报告实际运行命令及限制。

## Task 2: Docker 分发（独立实现任务）

**Files:** `Dockerfile`、`.dockerignore`、`compose.yaml`、`docker/*`、`docs/MCC-DOCKER.md`。

**Interfaces:** 构建 `cargo build --release --locked --bin mcc --bin mcc-linux-helper`。CLI 和 helper 位于 `/opt/mcc/bin/`。环境 `COPIS_DESKTOP_HELPER=/opt/mcc/bin/mcc-linux-helper`、`MCC_DOCKER=1`、`DISPLAY=:99`、`MCC_FIREFOX_BINARY=/opt/firefox/firefox`、`MCC_GECKODRIVER=/usr/local/bin/geckodriver`；profile 根目录由主模块读取 `MCC_FIREFOX_PROFILE_ROOT`，默认 `$HOME/.local/share/mcc/profiles/firefox`。

- [x] Ubuntu 22.04 运行镜像安装 Xvfb/Openbox/Tesseract 中英文、x11vnc/noVNC、必要 GTK/X11 依赖和字体；Mozilla 官方非 Snap Firefox；支持本机可测架构并明确分发架构。
- [x] Firefox/geckodriver 版本固定且提供校验来源；普通用户运行，使用 tini/可靠进程监督并联动失败退出与清理。
- [x] noVNC 密码来自私有文件/显式配置，不记录密码；Compose 默认发布 `127.0.0.1:6080`，不发布 driver/VNC。
- [x] Desktop 和 mcc daemon 启动健康检查；volume 保留配置/profile；提供完整启动、CLI、人工接管与停止命令。
- [x] 运行 shell/Compose 检查和可用的启动测试，报告证据；不要自行启动多个镜像构建或修改 Rust 文件。

## Task 3: Firefox 与现有调用链（主 agent）

**Files:** `src/linux/mod.rs`、`src/firefox/webdriver.rs`、`src/firefox/actions.rs`、`src/bin/mcc-linux-helper.rs`、`src/args.rs`、`src/service.rs`、`src/execution.rs`、`src/daemon.rs`、`src/runtime.rs`、`src/remote/*`、`Cargo.toml`/`Cargo.lock`。

- [x] 写 CLI/Service/动作 JSON 校验的失败测试：启动/连接、按钮、拖拽/时长/越界、未知字段、均衡释放。
- [x] 添加受限 loopback WebDriver 客户端，owned geckodriver 生命周期、持久 profile 与 Release Actions；不接受任意 URL/任意脚本端点。
- [x] helper 重用现有 Native 协议、截图/JPEG/OCR schema；单独线程处理 transport sideband 与桌面控件，输入前及各片段检查 epoch/owner/暂停。
- [x] Linux SO_PEERCRED 和进程创建身份；Linux 专用 helper 选择；仅显式容器模式允许新增平台本地执行。
- [x] 同步远端白名单、动作分类和能力协商，旧 Host 必须拒绝未支持命令。
- [x] 运行原有测试和新测试，集成容器完成实际网页事件与可见结果验收。

## Task 4: 主 agent 审查和交付

- [x] 检查全部 diff 的范围、兼容性、取消/释放、帧映射、身份和进程清理。
- [x] 执行容器启动、截图/OCR、Actions、暂停/恢复、持久化与故障检查。
- [x] 同步文档中的实际版本和验收状态，保留分支与工作区，报告未完成项。

## 执行结果

- 保留既有调用链，由独立实现任务分别完成 X11、Docker 打包与 CLI 集成；主 agent 完成 Firefox/helper、集成修复和全部代码审查。
- Rust 完整回归 372 通过、0 失败，1 个原有付费模型测试忽略；Linux peer、Actions 与实际 X11 测试通过。
- ARM64 完整容器与 WSS、真实 noVNC、暂停/释放、driver 故障恢复锁、Firefox/容器重启持久化、监督进程联动退出通过。
- amd64 镜像构建、浏览器/noVNC 与 WSS 在 x86_64 兼容环境通过；架构范围见 `docs/MCC-DOCKER-VALIDATION.md`。
- 交付使用指南 `docs/MCC-DOCKER.md`；验收记录 `docs/MCC-DOCKER-VALIDATION.md`。保留独立工作区供审阅，没有提交、推送、合并或远端部署。
