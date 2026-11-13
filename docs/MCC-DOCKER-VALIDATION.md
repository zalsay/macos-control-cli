# MCC Docker 原生输入验收记录

日期：2026-11-13。分支：`mcc-docker`。主 agent 独立集成和代码审查；未提交、推送或合并。

## 当前实现

官方 Firefox 153.7.0esr 以普通进程启动；镜像不安装 geckodriver，不启动 WebDriver、Marionette 或远程调试。沿用既有 CLI → daemon → Service → Linux helper，动作编译结果由 X11/XTEST 投递，后端为 `firefox-x11`。

环境为 macOS / Apple Silicon 上的 OrbStack、Ubuntu 22.04 容器。ARM64 原生运行，AMD64 使用 OrbStack 的 x86_64 兼容执行环境。全部桌面测试使用 UID/GID 1000、默认 Docker seccomp、cap_drop ALL、no-new-privileges 和 Firefox sandbox。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `cargo test --locked --tests -- --test-threads=1` | 30 套件，378 通过、0 失败、1 个原有付费模型测试忽略 |
| 普通 Firefox 生命周期专项 | 2 通过；无需 driver、无自动化参数、profile 排斥/名称安全、保留代理偏好、重复启动不重复追加偏好、退出回收 |
| Linux crate 单元测试 | 121 通过、0 失败、2 忽略；忽略项为付费模型及另行实测的 X11 live 测试。运行时挂载原 `tests` fixture |
| 实际 Xvfb/Openbox X11 live 测试 | 1 通过；XRes 进程身份、原像素截图、原生 ASCII、Unicode 键码正常/中断恢复、共享 Shift 持有、外部 grab 期间的 XTEST 接管和控制条 |
| ARM64 与 AMD64 runtime | 两种架构均构建、健康启动通过 |
| 两种架构的 `tests/docker_smoke.py` | 均通过；完整原生窗口 JPEG/OCR、实际系统光标轨迹和精确终点、点击前曲线靠近、Unicode/emoji/PUA 字面输入、Control、左右击、悬停/拖拽/滚动 |
| 两种架构的暂停/故障测试 | 均通过；旧帧拒绝、启动中暂停清理、靠近途中暂停不点击、在途拖拽中断和均衡释放、Firefox 退出时确认 X11 释放、显式断开及同 profile 重启 |
| 两种架构的 noVNC 实际协议 | WebSocket → RFB 密码认证 → x11vnc → X11 人工接管与 Pause/Resume/Cancel 均通过 |
| 两种架构的 `tests/docker_remote_smoke.py` | 均通过；WSS TLS/token、新能力协商、Linux peer/owner、本地抢占拒绝、远端窗口图像、页面点击、软接管、按住鼠标时人工中断、部分执行/释放回执和断开 |
| ARM64 容器重启持久化 | `tests/docker_persistence_smoke.py` set → 停止/启动容器 → check 通过；停止时保留已打开的 Firefox，cookie 仍保留 |
| desktop-base 打包检查 | UID1000、Xvfb/Openbox、Tesseract eng/chi_sim、认证 VNC/noVNC、普通可见 Firefox、未安装/运行 driver 均通过 |
| 格式与打包静态检查 | `cargo fmt --check`、`git diff --check`、Shell/Python 语法、Compose 配置、VNC 密码 5 项测试及文档本地链接检查通过 |

页面事件和内容区屏幕原点由测试页自身报告；MCC 生产代码不注入脚本。测试专用新 profile 使用 Firefox 自身测试环境的首次提示设置，实际 profile 的首次使用提示仍由用户在 noVNC 处理。页面测试等待 fixture 已绘制后再截图；普通启动不承诺网页加载完成。

## 主 agent 审查与修复

- 停用并移除 WebDriver 会话、HTTP/BiDi 链路及 driver 打包，改为持有普通 Firefox 进程组与私有 profile 锁；现有用户偏好和代理保留。
- 截图与坐标统一到 X11 原生窗口，包含标签栏和地址栏；输入前及每段动作检查当前帧、窗口身份、标题、几何、焦点与输入 epoch。
- 曲线从接管倒计时结束后的实际 X11 光标位置开始；沿用 Bézier/minimum-jerk、时间预算和单调时钟采样，迟到时跳过过时中间点。
- Unicode 清理仅在恢复映射成功后移除原映射记录，失败时保留恢复依据并进入未知输入恢复锁；逻辑按键共享物理键码/Shift 时不能提前释放。
- 先复现了 XI 2.0 在 Firefox pointer grab 期间漏掉外部输入，改为要求 XI 2.1；再复现并修复自身松键原始事件延迟造成的误接管。
- 延迟事件过滤只覆盖本次同步边界内已持有键/按钮的释放，按下和移动仍要求精确请求身份；每次请求结束或错误都清空期待记录。边界、序号回绕及外部 grab 测试通过。
- 保留暂停、owner、epoch、输入释放和恢复锁；错误不会重放已经发生的动作。浏览器退出时 X server 仍在可确认释放，不把进程退出一律当作未知输入。
- 主工作区的 `swift/CursorMotion.swift`、`tests/cursor-motion/main.swift` 并行修改未复制或改动。

## 最终镜像与当前桌面

| 架构 | 镜像 | 镜像 ID |
| --- | --- | --- |
| ARM64 | `mcc-desktop:dev` / `mcc-desktop:native` | `sha256:911e47726b30ea1c463ca5f509e624d72c5b08529be88adb7069e1b62f0c305e` |
| AMD64 | `mcc-desktop:host-amd64` / `mcc-desktop:native-amd64` | `sha256:34568e92769c99f11df7297669487b2434b6070c10010b06e9f61f01b81f8952` |

默认 Compose 桌面已切换到上述 ARM64 镜像并健康运行，保留原配置、VNC 密码、`google` 与 `xiaohongshu` profile 卷。普通 Firefox 复用 `google` profile 打开原 AI 搜索地址。实际进程参数为 `--no-remote --new-instance --profile …/google --width 1200 --height 820 --new-window URL`；确认无 `--marionette` / 远程调试参数，也无 geckodriver 进程。仅打开页面和观察窗口，不操作人机验证。

## Docker Host 增补验收

本次新增的是打包和进程托管：可选 `compose.host.yaml`、入口脚本、健康检查及 Host 端口元数据；未增加 Rust 执行器或更改键鼠算法。Host 沿用原 WSS/TLS/token、daemon/helper、owner、frame/epoch 和恢复 journal。主 agent 完成代码审查。

| 检查 | 结果 |
| --- | --- |
| 修改前真实失败 | 原镜像即使配置 `MCC_HOST_ENABLED=1` 并发布端口，宿主 status 仍为 `REMOTE_CONNECT_FAILED`，因为入口未托管 Host |
| 两架构构建 | ARM64 与 AMD64 Host 镜像构建成功；Rust builder 命中既有原生输入版本缓存 |
| 两架构宿主跨端口 smoke | `tests/docker_host_smoke.py` 均通过：真实 Docker 发布端口、CA/token、错误 token 拒绝、不回退本机 helper、启动普通 Firefox、JPEG 下载到宿主、系统点击、Unicode 输入、客户端 Actions 文件、显式 disconnect |
| 干净停止/启动 | ARM64 专用 Compose 桌面先 disconnect 再停止/启动，CA 与 token 逐字节保持相同，再次通过宿主 smoke |
| 恢复锁 | ARM64 持有 owner 停止/启动后，新客户端输入返回 `RECOVERY_REQUIRED`；停止容器后通过 one-off `mcc host recover` 显式恢复，再启动成功 |
| Host 进程监督 | 专用桌面的 Host 被 SIGKILL 后，容器联动结束且退出码非零；重新启动健康 |
| 启动拒绝 | Host 缺少 TLS/token、`MCC_HOST_ENABLED=yes` 均在启动桌面前失败 |
| 默认桌面回归 | 全新未启用 Host 的容器保持六个受监督进程并健康；完整 `tests/docker_smoke.py` 通过 |
| 启用 Host 的原有回归 | `tests/docker_remote_smoke.py` 通过；本地 `tests/docker_smoke.py` 复测通过，保留 noVNC 真实接管、暂停和输入释放 |
| 本机 CLI 与打包 | `cargo build --locked --bin mcc`、Shell/Compose/Python 检查、VNC 密码 5 项测试、差异空白与文档链接检查通过 |

一次在启用 Host 的专用桌面连续运行 WSS smoke 和本地综合测试时，拖拽收到 `FOCUS_LOST/USER_PAUSED`，回执为 partial/released。该次不计通过；同一桌面原测试复跑及全新默认模式桌面测试均通过，未复现稳定触发条件，未修改输入门禁或增加自动重放。本次没有重新运行整套 Rust 测试；上文的 Rust 测试结果来自原生输入交付，打包增补未更改其源码。

另一次 ARM64、AMD64 和默认桌面同时启动 Firefox 的并行复跑中，AMD64 兼容执行的 start 返回 `WINDOW_IDENTITY_UNAVAILABLE`。该次不计通过；按既有流程停止/恢复测试桌面后，串行运行同一宿主 smoke 通过。原生绑定有八秒窗口等待预算，未确定该次失败的稳定触发条件，也未放宽窗口身份校验或自动重试输入。两项偶发失败仍是本机验收的限制。

本机实际部署使用 `compose.yaml` + `compose.host.yaml`。宿主 8765 已被既有 Python 服务占用，因此本工作区私有 `.env` 设置 `MCC_HOST_PORT=8766`；未停止该服务。Host 对外入口为 `wss://127.0.0.1:8766/mcc/v1`，noVNC 保持 `http://127.0.0.1:6080/vnc.html`。CA 公钥与 token 导出在宿主私有 `~/.config/mcc/docker-host/`，服务端私钥留在原配置卷。客户端使用该目录的 `client-active` 状态目录，当前连接回执单独保存在 0600 的 `current-session.json`；不将凭据内容写入仓库或日志。

原配置、profile、VNC 三个卷沿用，Host TLS/token/journal 新增在原配置卷。通过宿主本分支 CLI 复用 `google` profile 打开 AI 搜索并观察；不操作验证码。ARM64/AMD64 专用测试桌面使用独立卷和端口，测试结束清理。跨机器局域网/公网入口未部署；物理 Ubuntu Docker 主机仍未实测。

## 文件传输与原生上传增补验收

本次扩展既有 WSS/Host、Service 和 Linux helper，不增加执行器。`file put --local` 接收宿主文件，`select-file --file-id` 用系统事件完成已打开的 Firefox GTK 文件选择框。独立 `mcc-transfers` 卷保存私有暂存文件；保留原 profile/config/VNC 卷。

| 检查 | 结果 |
| --- | --- |
| 修改前失败 | 原 Host 镜像在宿主 `file put` 步骤返回 `ACTION_UNSUPPORTED`；新增 hello 回归测试复现客户端拒绝 `remote.files.v1` |
| 本机 Rust | `cargo test --locked -- --test-threads=1`：384 项通过、1 项按原约定忽略 |
| Ubuntu ARM64 Rust | 121 项库测试与 6 项文件测试通过；另在独立 Xvfb/Openbox 显示中运行 X11 live 测试通过 |
| 文件存储 | 不完整/摘要不符/超长/路径穿越/符号链接替换/跨 session 或 connection 拒绝；空文件、中文文件名、异常残留配额与显式断开清理通过 |
| ARM64 与 AMD64 宿主 smoke | 两种最终镜像均通过 `tests/docker_host_smoke.py --files`：三块二进制传输、SHA256、中文/空格文件名、跨会话及错误连接拒绝、Host 路径限制、无选择框拒绝、普通输入精确焦点、人工暂停/恢复、原生 GTK 选择、真实 HTTP multipart 文件名/字节比对和 disconnect 清理 |
| 原桌面回归 | 最终 ARM64 镜像的 `tests/docker_smoke.py` 通过，覆盖轨迹、精确物理终点、JPEG/OCR、Unicode、组合键、拖拽、滚轮、暂停释放、noVNC/RFB 人工接管及浏览器退出处理 |
| 打包 | 两架构构建成功；Rust 格式、差异空白、Bash/Python 语法、Compose 配置和 VNC 密码 5 项测试通过 |

主 agent 审查并修复：客户端能力白名单遗漏；原生选择中断回执缺少 `completedSteps` 导致 Host 回执投影失败；确认 Enter 复用既有原生按下/释放接口，避免选择框在按下时关闭后阻断松键；无法确认释放时返回 unknown 回执并保持恢复锁。普通键盘输入未放宽焦点条件。

并行运行本机 Rust 测试时出现短超时，串行全量通过。多镜像编译期间的一次 Firefox start 返回原有八秒窗口绑定超时 `WINDOW_IDENTITY_UNAVAILABLE`；停止编译并按原流程恢复独立测试桌面后，同一 smoke 串行通过，未放宽身份校验或自动重放。测试页还修正了异步 HTTP 事件乱序导致旧输入前缀覆盖完整值的问题，并以本次连接前后的文件列表验证清理，保留前次异常退出残留。

| 最终镜像 | ID |
| --- | --- |
| `mcc-desktop:files-arm64` / `mcc-desktop:dev` | `sha256:d8396b687dd550f1e368d2840821ed925b2be556dd88afe12d291d5fc07391c2` |
| `mcc-desktop:files-amd64` | `sha256:07638c9dea5a64b4bf63bee3372638da2ca5c4af774c4c4303804f02af891b3c` |

验收环境仍为 macOS OrbStack，ARM64 原生运行，AMD64 兼容执行；物理 Ubuntu x86_64 主机未新增实测。实际网页上传使用本机 fixture 服务，不涉及第三方站点账号或验证码。常驻 Compose 容器已使用最终 ARM64 镜像，WSS 仍为 `wss://127.0.0.1:8766/mcc/v1`，noVNC 仍为 `http://127.0.0.1:6080/vnc.html`；原有命名卷、CA/token 保留，新增私有传输卷。常驻容器另经宿主新 CLI 验证中文文件传输、无选择框拒绝和断开清理，随后重新打开原 `google` profile 的 AI 搜索地址。客户端当前状态目录为私有 `client-files-20261113`，新连接与截图回执保存在原私有 `current-session.json`；仅重新打开和观察，没有操作验证码。

## Docker 独立桌面暂停修复（2026-11-13）

Docker 独立桌面的普通 noVNC 键鼠、窗口失焦和 Host owner 命令间空闲不再产生持续的人工暂停锁，也不等待三秒接管倒计时。每条新命令仍激活并核验目标窗口；操作中失焦停止当前动作，明确暂停/取消、在途心跳丢失和未知输入恢复锁继续生效。macOS 规则保持原样。

本次补齐的恢复问题位于 `src/firefox/gate.rs::Gate::resume`：原实现恢复后仍报告 `awaitingCountdown`，Host 的现有 lease/epoch 恢复校验因此拒绝下一条命令。恢复已绑定目标时改为报告 `running`，保留 Host 原有身份、epoch 和恢复条件检查。

用户要求减少测试后，停止全量测试，后续仅单进程执行 `cargo build --locked --bin mcc-linux-helper --jobs 1`，并通过实际 `mcc --remote` 命令验证本次修复。未完成的 Linux 全量测试不计为通过。helper 在 Ubuntu 22.04、Rust 1.89.0 ARM64 中构建，当前开发镜像使用移除调试信息的 dev helper，复用现有 release CLI 和 Firefox 基础层；未进行正式 release 或 AMD64 重建验收。

| 本次直接验证 | 结果 |
| --- | --- |
| 修改前复现 | 既有 `unattended-arm64` 镜像中，人工继续后下一条远程输入返回 `RECOVERY_REQUIRED` |
| 启动与观察 | 修复镜像启动 Host 和普通 Firefox，宿主 MCC 成功观察原生窗口 |
| 首次系统鼠标输入 | 约 0.34 秒完成，无三秒倒计时 |
| 普通鼠标活动 | 外部 X11 鼠标移动后，下一条远程 hover 成功 |
| 明确暂停与继续 | 点击桌面 Pause 后输入被 `USER_PAUSED` 拒绝；点击 Resume 后同一连接的下一条 hover 成功 |
| 正常断开 | 同一远程连接显式 disconnect 成功 |
| 原常驻服务 | 原 MCC 容器使用修复镜像并健康；宿主通过原 `8766` 入口启动、观察原 `google` profile |

定向检查中还实际观察到人工按住 Shift 时返回 `INPUT_BUSY`。新增的人工按键释放和失焦后再激活脚本用例仅做语法检查，未运行整份桌面 smoke；本次不据此宣称这两项完整流程已实测通过。外网页面加载期间曾返回 `CONTEXT_CHANGED`，后改用容器内静态页面完成上述暂停恢复验证，未放宽帧校验。

上一轮部署完成时，`mcc-desktop:dev`、`mcc-desktop:files-arm64`、`mcc-desktop:unattended-arm64-fixed` 指向 `sha256:18b912841923026c73048d41edc3aa5d93821da184c92993dd78a252db46e00b`。此前常驻镜像保留为 `mcc-desktop:before-unattended-20261113`。原服务停止期间通过既有 `mcc host recover` 完成这次崩溃状态的显式恢复；未增加自动恢复或自动重放行为。原 profile/config/transfers/VNC 命名卷和 CA/token 沿用，旧客户端状态先备份再重新配对，当前连接回执仍保存在私有 `current-session.json`。测试用构建容器、桌面容器及两个临时 home 卷已清理。

## Docker 已有连接跨客户端续用（2026-11-13）

本次修改既有 Service status、Host 和 SessionManager：仅 Docker 桌面返回当前 `connectionId`，持同一 Host token 的客户端在请求空闲时可续用原窗口。沿用 daemon capability，用 Host 已有的全局 RPC ticket 作为底层操作序号，避免不同客户端从各自序号 1 开始引发 `OPERATION_REPLAY`。接续时旧帧失效，旧回执保留只读查询但不能重放，原客户端上传文件释放；明确暂停、取消未确认和恢复锁保持原有规则。macOS 不启用此接续行为。

只运行本次新增的 3 个 `shared_desktop_tests` 定向用例，均通过；未运行全量回归或整套 smoke。使用官方 Rust 1.89 ARM64 slim-bullseye 工具容器单核、jobs=1 构建开发版 MCC；本次未重编译 Linux helper，也未重新下载或打包 Firefox。最终在原 Ubuntu 22.04 桌面运行时直接用宿主 MCC 验证：

- 原客户端启动原 `google` profile，`status` 返回当前连接 ID。
- 第二个独立客户端状态目录，通过同一 Host token 查询到相同连接 ID 和窗口 ID，重新 observe 后系统 hover 成功。
- 原客户端直接用原连接重新 observe 和 hover 成功，两次接续均保留窗口 ID `16777219`。
- 截图可见 Google 的 AI 搜索结果；未进行验证码操作。
- 当前常驻容器健康，profile/config/transfers/VNC 卷及 CA/token 沿用。原客户端状态先备份再重新配对，当前回执保存在私有 `current-session.json`。

当前 `mcc-desktop:dev` 和 `mcc-desktop:shared-desktop-arm64` 为 `sha256:1a680cf437dafc5fa37b4f5602ad28f10cfde2f1f987fc12d4945ebaa1a2b2cc`；升级前镜像保留为 `mcc-desktop:before-shared-desktop-20261113`。直接验证回执为 `/tmp/mcc-shared-desktop-direct-result.json`，构建工具容器和临时 Rust 镜像已清理。本次未新增 AMD64、物理 Ubuntu 主机或公网验证。

## 使用边界

输入坐标来自包含工具栏的窗口截图，不能复用旧 WebDriver 内容区坐标。原生窗口观察无法提供 BiDi 导航/DOM/标签页事件，同标题页面变化无法仅凭帧号检测；业务结果应重新观察确认，回执仍为 `effectVerified:false`。

物理 x86_64 Ubuntu Docker/AppArmor、普通 GNOME/Wayland、Windows/macOS Firefox、容器内微信及公网远端部署未在本次验收。其他非受管理的 X11 窗口保留基本输入接口及 ASCII 限制。此次未处理验证码，也未修改网页可见的自动化属性。

启动、测试与诊断命令见 [使用指南](MCC-DOCKER.md)。
