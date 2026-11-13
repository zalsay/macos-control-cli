# Ubuntu X11 定向验证记录

日期：2026-11-13。分支：`codex/ubuntu-x11`，基于 `main` 的 `13ebb92`。

## 已完成

- 主 agent 检查已有 Docker X11、输入 Gate、Service、Host 和构建安装调用链后实施并自审；没有全量回归。
- macOS 开发机仅运行 `cargo test --locked --lib ubuntu_x11 --jobs 1`（5 项通过）及 `cargo test --locked --lib firefox::gate::tests --jobs 1`（8 项通过，含其中两项 Ubuntu 测试）。两组共 11 个不同测试，覆盖模式分离、会话拒绝、权限回执、Firefox 启动脚本拒绝和输入门禁。
- Linux GNU ARM64 单进程构建 `mcc` 与 `mcc-linux-helper`，通过实际 `build.sh debug` 生成原生安装包；shell 语法及 `git diff --check` 检查通过。
- 独立 Ubuntu 22.04 ARM64 X11 fixture 用普通用户、`MCC_DOCKER=0`、`MCC_LINUX_DESKTOP=1`、独立 DISPLAY/Xauthority/runtime。未挂载用户 profile、未操作现有 Docker Firefox。
- 真实运行包内安装器，入口返回 `platform:linux-x11`、`backend:x11` 和 `linux.x11.v1` 能力。
- 通过 MCC 系统按键打开本地 HTTP 测试页，OCR 找到 `Native click`，系统点击后服务端收到页面点击请求。首条输入耗时 3.08 秒，包含三秒接管倒计时。
- 使用独立 XTEST 客户端模拟外部键盘和鼠标输入，均产生 `userInteraction` 暂停；暂停后的 hover 返回既有 `FOCUS_LOST / reason:USER_PAUSED`，回执 `dispatchState:notSent`。显式 resume 后 hover 成功。
- 明确 Pause 后再次发送外部键盘事件，暂停仍为 `explicitPause`，没有被软事件覆盖。

## 验证边界

fixture 使用 Xvfb/Openbox，只用于隔离检查原生模式调用链，产品入口不会启动这些组件。外部 XTEST 事件是人工输入检测的模拟证据，不等同于物理键鼠验收。

尚未验证真实 GNOME/Mutter 桌面、物理 Ubuntu 主机、AMD64 构建、多屏/分数缩放、本轮文件选择及公网 Host。Jev、文件传输等已有功能复用原调用链，未据此宣称本轮端到端验收。未发布新版本、未提交或推送本分支。
