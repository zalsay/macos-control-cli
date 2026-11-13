# MCC Docker 虚拟桌面

用户于 2026-11-13 授权在独立 `mcc-docker` 分支实现 Ubuntu 22.04 容器桌面，后续明确要求停用 WebDriver、去掉 `--marionette`，通过普通 Firefox 和系统键鼠事件操作。本文记录最终架构；普通 GNOME/Wayland 桌面不属于本目标。

## 运行目标

Ubuntu 22.04 容器运行 Xvfb、Openbox、Mozilla 官方 Firefox、Tesseract、x11vnc 与 noVNC/websockify。不安装 geckodriver，不启动 Marionette、WebDriver 或远程调试服务。Firefox 由 helper 直接启动为有界面进程，键鼠通过既有 X11/XTEST 注入；生产代码不注入或执行网页脚本。

所有桌面进程以 UID/GID 1000 运行，保留 Firefox sandbox；Compose 丢弃 capabilities、启用 no-new-privileges。不挂载宿主 X11、输入设备或 Docker socket。noVNC 默认仅发布宿主回环端口并要求密码；持久卷保存 Firefox profile、MCC 配置和私有密码。Host WSS 继续要求显式 TLS/token，不自动开放端口。

## Docker Host

通过可选 `compose.host.yaml` 启用 `MCC_HOST_ENABLED=1`，将现有 `mcc host start` 加为第七个受监督进程。容器内监听 `0.0.0.0:8765`，宿主默认仅发布 `127.0.0.1:8765`；`MCC_HOST_BIND_IP`/`MCC_HOST_PORT` 可显式配置外部入口，证书 SAN 必须匹配客户端实际地址。基础 Compose 保持原六进程桌面。

凭据由既有 `mcc host tls init`/`host token init` 显式生成，保存在 `mcc-config` 卷内的 `host-tls`/`host.token`，Host journal 使用同卷原有 `remote-host/desktop` 目录。启动不生成或覆盖凭据，不自动 recover。进程健康检查通过 procfs 确认 Host 持有监听 socket，不发送会消耗认证失败预算的探针。

外部 CLI 使用现有 `--remote`、CA 和 token 调用同一 daemon/helper，不增加执行器或输入通道。保留 owner、配对版本、frame/epoch、人工接管、暂停和恢复语义，截图通过既有协议回传客户端文件，Actions 读取客户端文件。停机先向 Host 发送 SIGTERM 并限时等待，再停 daemon 和显示服务；正常使用应先由原客户端 disconnect，仍持有 owner 的停止保留恢复锁。异常 Host 退出联动停止整个容器。

### 宿主文件传输与网页上传

扩展原 WSS 通道：`file put --connection ID --local /absolute/client/file` 发送 basename、长度、SHA256 manifest，Host 确认 owner/connection 并回复 ready 后按 32KiB 接收二进制块。长度与摘要匹配后返回 `fileId/name/bytes/sha256`；临时文件独占创建、不跟随符号链接，未完成传输不会产生可选 ID。

独立 `mcc-transfers` 私有卷通过 Host `--upload-dir` 启用，单文件 64MiB、全目录 256MiB/128 项，55 秒总预算与 5 秒读等待。旧 Host 默认不启用接收；能力声明为 `remote.files.v1`。文件 ID 绑定原 Host session/connection，选择前重新校验文件身份及摘要；显式 disconnect 清理，重启后 ID 失效，异常残留继续占配额。

点击网页上传控件打开原生选择框后，`select-file --connection ID --file-id ID` 将文件解析成 Host 私有路径，沿原 Service/helper 调用链选择。Linux 仅信任同一 owned Firefox 的 XRes 进程身份、父窗口、GTK 角色与模态状态，保留暂停/epoch/释放门禁。该模态窗口可保留父窗口的 focus lease，普通输入仍要求精确焦点；确认 Enter 复用已有原生按下/释放接口。回执确认选择框关闭，不自动提交网页。原 `--path`/`--files-root` 契约继续生效，文件接收不开放任意 Host 路径。

## 复用既有调用链

保留 CLI → execution → daemon → Service → Native helper，以及 connectionId、最近 32 帧、OCR/Jev、owner/sequence、输入 epoch 与远端回执。Linux Rust helper 实现既有 Native 协议；macOS helper 保持原行为。Linux SO_PEERCRED 和进程启动身份验证继续生效。

helper 持有普通 Firefox 子进程组、profile 文件锁与身份验证的 X11 窗口。退出或启动失败时释放 profile 锁并清理 owned 进程；不修改其他应用的输入会话。已有 profile 偏好和代理保留，普通首次使用提示由用户在 noVNC 操作。`firefox start` 确认窗口建立，不等待网页加载完成。

受管理后端标记为 `firefox-x11`，能力为 `firefox.x11.v1`、`firefox.system-input.v1`；旧 WebDriver 能力不兼容，不自动回退。其他显式选择的 X11 原生窗口继续使用基本点击/滚动/ASCII 输入接口。

## 截图与系统输入

`observe` 复用 X11 原像素窗口 JPEG 截图，包含标签栏和地址栏。初始窗口请求 1200×820，实际位置、尺寸由 X11 返回。所有输入坐标相对于截图左上角；点击/滚动由 Service 映射到屏幕，移动/拖拽/组合动作在 helper 中加窗口原点。不得沿用旧内容视口坐标或缩放截图继续输入；编码超过 1MiB 时拒绝。

每次观察刷新 frameId，并保存窗口标题、几何和进程身份。旧帧或可观察到的窗口变化拒绝输入；每段动作重查许可、焦点、身份、标题和几何。原生截图无法提供 BiDi 导航/标签页/DOM 事件，同标题页面变化不能仅凭 frameId 检测，业务操作后应重新观察。

复用原动作编译器的完整预校验、配对按下/释放与时间预算；编译出的封闭动作词汇交给既有 XTEST 注入接口。Unicode 对布局中不存在的字符临时使用空闲非修饰键码，完成或中断后恢复原映射。逻辑按键共享物理键码/Shift 时保留持有关系，不能提前松开其他步骤需要的键。

可见控制条保留暂停/继续/取消和三秒接管倒计时，helper sideband 及时撤销在途许可。自身 XTEST 输入按请求身份过滤，noVNC 等外部 XTEST 输入触发人工接管。已持有的键鼠状态只扣除本执行器所有的部分，外部物理状态仍拒绝后续输入。

所有退出路径均释放 owned 按键/按钮并恢复临时键码。Firefox 退出时 X server 仍在可确认释放；若无法确认释放或恢复映射，则进入 `inputState:unknown` 恢复锁，关闭 owned 浏览器，必须显式断开后重建，不自动重放。

## 鼠标轨迹

沿用从 `swift/CursorMotion.swift` 迁移的三次 Bézier、minimum-jerk、有界曲率/耗时、精确终点和屏幕边缘回退。点击、悬停先松键靠近，拖拽先靠近起点再按住移动；组合动作复用同一规划器。显式零时长立即定位，默认耗时随距离约 150–700ms。

接管倒计时完成后读取实际 X11 光标作为起点，连续命令及 noVNC 人工移动后均使用当前系统位置。约 60Hz 计划采样使用单调时钟调度，迟到中间点跳过，最终坐标保留，不突发补发。整组动作在投递前预校验，自动移动计入 10 秒预算。

## 验收

1. Rust 回归、普通 Firefox 无 driver 启动、profile 名称安全/排斥、偏好幂等与进程退出回收。
2. Compose 健康启动、普通用户/默认安全配置、无 headless/Marionette 参数或 driver 进程。
3. 页面自身报告实际轨迹、精确物理终点、点击、Unicode、组合键、拖拽及滚动；原像素 JPEG 与 OCR。
4. 原生 X11 live 测试验证进程身份、截图、外部输入接管、Unicode 键码恢复、共享 Shift 释放。
5. 暂停/取消、过期帧、浏览器退出中断、noVNC WebSocket/RFB 接管、WSS owner/TLS/token 与容器/profile 持久化。
6. 主 agent 独立审查完整差异并记录实际架构范围；不提交、推送或部署远端。
7. 宿主 CLI 跨 Docker 发布端口验证 TLS/token、错误凭据拒绝、普通 Firefox、截图下载、系统点击/Unicode/Actions；验证默认模式、凭据重启复用、dirty journal 显式恢复、Host 退出联动停止。
8. 从宿主传输中文/空格文件名与多块二进制内容，通过 GTK 原生选择框上传到 fixture HTTP 服务，比对实际 multipart 文件名和字节；验证跨 owner/connection、无选择框、暂停和普通输入焦点门禁及断开清理。
