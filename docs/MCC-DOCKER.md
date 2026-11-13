# MCC Docker 虚拟桌面

在独立的 Ubuntu 22.04 桌面中运行有界面的 Firefox、MCC daemon 和 Linux helper。Xvfb 提供显示器，Openbox 管理窗口，x11vnc/noVNC 提供人工接管。容器内使用普通用户 `mcc`（UID/GID 1000），不需要宿主显示器、X11 socket、输入设备或 Docker socket。

本镜像支持 `linux/arm64` 与 `linux/amd64` 构建。Compose 默认构建宿主的原生架构。当前普通 Firefox/X11 后端的实测范围见文末验收记录；物理 x86_64 Ubuntu 主机尚未复测。

从宿主调用 Docker 桌面的日常命令、`mccd` 函数定义、文件上传与模型配置见 [mccd 使用指南](MCCD-USAGE.md)。

## 构建与首次启动

在仓库根目录执行，需要 Docker Engine 与 Compose：

```sh
docker compose build
# 密码只在交互终端输入，保存于 vnc-secrets 卷中的 0600 文件。
# VNC 协议只使用八个字符，因此这里要求恰好八个非空格 ASCII 字符。
docker compose run --rm -it --no-deps \
  --entrypoint /opt/mcc/bin/mcc-vnc-password mcc
docker compose up -d
docker compose ps
docker compose logs --tail 100 mcc
```

打开 [本机 noVNC](http://127.0.0.1:6080/vnc.html)，点击连接并输入刚设置的密码。只将容器的 6080 映射到宿主 `127.0.0.1`；原始 VNC 不发布宿主端口；镜像不安装 geckodriver。这个 HTTP 入口供本机使用。远程查看可先通过 SSH 把宿主回环 6080 转发到自己的回环端口。

可以用以下命令等待健康；超时后查看日志，不继续输入：

```sh
docker compose up -d --wait --wait-timeout 90
docker compose exec mcc mcc daemon status
```

健康检查同时确认六个受监督进程、X server、窗口管理器、noVNC 页面和既有 MCC daemon/helper 的状态。启用下述 Host 模式时增加第七个受监督进程和监听检查。任一受监督进程退出都会结束容器。停止时先通知 Host 暂停 owned 输入，再请求 daemon 释放资源，最后终止并回收子进程组；`tini` 回收遗留进程。

## CLI 与人工接管

CLI 与 helper 位于 `/opt/mcc/bin`，已加入 `PATH`。所有命令都通过原有 MCC daemon、Service 和 helper：

```sh
docker compose exec mcc mcc --version
docker compose exec mcc mcc status
docker compose exec mcc mcc firefox start --url https://example.com --profile default
```

`firefox start` 的回执包含 `connectionId`。已有受控窗口时，`mcc status`（宿主远程调用为 `mccd status`）也会返回当前 `connectionId`，无需找回启动回执。它是连接标识，不代替 Host token 认证。后续命令显式使用该 ID；`observe` 返回的 `frameId` 仅用于当前帧：

```sh
docker compose exec mcc mcc observe --connection CONNECTION_ID --out /tmp/firefox.jpg
# 将图像导出到宿主；frame 回执仍从 observe 的 JSON 中读取。
docker compose exec -T mcc cat /tmp/firefox.jpg > ./firefox.jpg
docker compose exec mcc mcc click --connection CONNECTION_ID --frame FRAME_ID --x 200 --y 180
docker compose exec mcc mcc disconnect --connection CONNECTION_ID
```

Firefox 由 helper 直接启动，不启动 WebDriver、Marionette 或远程调试服务。键鼠通过 X11/XTEST 系统事件投递，Unicode 使用临时键码映射并在结束/中断后恢复。Docker 使用独立虚拟桌面：普通 noVNC 键鼠活动和失焦不会锁入 `USER_PAUSED`，输入不等待三秒接管倒计时；每条新命令先激活并核验目标窗口。noVNC 中可见的 MCC 控制条仍提供明确的暂停、继续、取消。具体按钮、当前帧和输入许可由 helper 管理，容器启动脚本不另建许可状态。断开、明确暂停或浏览器故障之后，按 CLI 回执重新观察/连接。macOS 的人工接管与倒计时规则不受此 Docker 行为影响。

Firefox 初始原生窗口为 **1200×820**，由窗口管理器决定实际位置和尺寸。`observe` 返回 X11 原像素窗口截图，**包含标签栏和地址栏**；操作坐标相对于这张图的左上角，不能沿用旧 WebDriver 内容区坐标。每次新观察更新帧身份；旧帧、窗口标题或几何变化会拒绝输入。图片超过 1MiB 时返回错误，不缩放后继续输入。

首次创建的普通 profile 可能显示 Firefox 首次使用提示，请在 noVNC 中查看并操作后重新观察。`firefox start` 只确认原生窗口已建立，不承诺网页加载完成。这里不通过浏览器协议监测导航、标签页或 DOM；同标题页面变化不能凭帧号检测，应在业务操作后重新观察确认。

```sh
docker compose exec mcc mcc type --connection CONNECTION_ID --frame FRAME_ID --text 'Hello 容器'
docker compose exec mcc mcc press --connection CONNECTION_ID --frame FRAME_ID --key Control+a
docker compose exec mcc mcc hover --connection CONNECTION_ID --frame FRAME_ID --x 300 --y 200 --duration-ms 500
docker compose exec mcc mcc drag --connection CONNECTION_ID --frame FRAME_ID \
  --from-x 100 --from-y 300 --to-x 500 --to-y 300 --duration-ms 600
docker compose exec mcc mcc control --command state
docker compose exec mcc mcc control --command pause
docker compose exec mcc mcc control --command resume
```

`click` 还支持 `--button left|middle|right`、`--count 1|2` 和 `--modifiers shift,control,alt,meta`。`Cmd` 不会被改写为 `Control`。新移动/拖拽/按钮选项要求受管理的 Firefox 系统输入连接；X11 原生窗口只有基本点击、滚动、ASCII 文本与受限按键。

### Firefox 鼠标轨迹

Firefox 的 `click`、`move`、`hover`、`drag` 与组合动作中的移动，使用从 macOS `swift/CursorMotion.swift` 迁移的三次 Bézier 曲线和 minimum-jerk 缓动：起步、停止较慢，中段较快；曲率和自动耗时带有界变化，目标坐标不随机偏移。默认计划时长按距离计算，约 150–700ms，以接近 60Hz 的计划采样点交给现有 XTEST 注入接口。曲线会越出虚拟屏幕时改用保留缓动的直线路径。

- `click` 先沿轨迹靠近，再按下/释放；双击只移动一次。
- `move` 和 `drag` 未指定 `--duration-ms` 时按距离计算；显式 `0` 表示立即定位，正值控制该段计划时长。拖拽先松键靠近起点，再按住按钮沿曲线拖动；时长参数仅控制按住后的移动。
- `hover` 先沿轨迹靠近，`--duration-ms` 仍表示到达后的停留时间。
- 组合动作的 `move` 未写 `durationMs` 时使用自动时长，显式 `0` 保留立即定位；自动移动也计入 10 秒的整组计划上限。

每条命令在激活目标窗口后读取 **容器 X11 的实际光标位置**作为曲线起点，连续命令和 noVNC 人工移动后均使用当前物理位置。noVNC 可看到系统光标随输入移动；宿主 macOS 光标不受影响。其他非受管理的 X11 窗口仍使用原有基本输入接口。

实际投递受 CPU 和桌面负载影响，不保证达到 60Hz 或精确墙钟耗时。每段仍检查明确暂停、epoch、焦点、窗口身份、标题与几何；迟到时跳过过时中间点，保留精确终点，不集中补发。靠近途中明确暂停不会继续发出点击。执行期间失焦会停止当前操作并返回 `FOCUS_LOST`，不设置持续暂停锁；重新观察后发送新命令会重新激活目标。人工仍按住的按键或鼠标按钮返回 `INPUT_BUSY`，释放后可发送新操作，无需点击继续。

组合动作使用 `mcc actions --connection CONNECTION_ID --frame FRAME_ID --file /absolute/actions.json`。本地模式下文件位于容器内；远端模式在调用方读取并内联发送文件内容。文件最多 64KiB，`version:1`，1–256 步，单步时长最多 2000ms、总计划时长最多 10 秒；所有按下动作必须配对释放，例如：

```json
{"version":1,"steps":[
  {"type":"move","x":100,"y":300},
  {"type":"pointerDown","button":"left"},
  {"type":"move","x":500,"y":300,"durationMs":600},
  {"type":"pointerUp","button":"left"}
]}
```

动作回执的 `effectVerified:false` 表示只确认输入投递，业务结果需要重新观察确认。暂停可能返回 `dispatchState:partial` 和 `inputState:released`；不会重放已经发生的输入。系统输入释放无法确认时返回 `inputState:unknown` 并锁住会话。先显式 `disconnect` 再启动新的 owned 会话；普通 `resume` 不解除未知输入状态。

容器支持下述 Host 模式。Host 持有 owner 时，本地 CLI `control` 被拒绝，桌面可见控件仍可明确暂停或取消。Docker owner 在命令之间空闲超过 300 秒也不会自动暂停；在途请求的心跳、传输故障、未知输入状态和 Host 恢复锁仍按原协议处理，不自动重放输入。

### Jev 模型配置

Docker 版沿用 MCC 的 `models.toml`，路径为 `/home/mcc/.config/mcc/models.toml`（`MCC_CONFIG_DIR` 已在镜像中设置）。配置保存在 `mcc-config` 卷中，重建镜像、重建或重启容器后继续使用；宿主机的 `~/.config/mcc/models.toml` 不会自动同步到容器。

配置文件格式如下，仓库中的 [配置示例](../docker/models.toml.example) 使用占位密钥，供填写格式参考，不会自动加载：

```toml
default_model = "jev"

[models.jev]
enabled = true
url = "https://openrouter.ai/api/alpha/decisions"
api_key = "YOUR_API_KEY"
model = "typesafe/jev-1.13"
```

推荐用现有配置命令写入该文件，以复用权限检查、写锁和原子保存。`secret-provider-command` 是宿主安全读取密钥的占位命令；密钥只经 stdin 传入容器：

```sh
secret-provider-command | docker compose exec -T mcc mcc --config set jev \
  --url https://openrouter.ai/api/alpha/decisions \
  --model typesafe/jev-1.13 --api-key-stdin
docker compose exec -T mcc mcc --config default jev
# 已有 profile 若曾禁用，可显式重新启用：
docker compose exec -T mcc mcc --config enable jev
# 显示 URL、model 和启用状态，API key 始终脱敏：
docker compose exec -T mcc mcc --config show jev
```

文件必须属于容器用户 `mcc`（UID/GID 1000），目录权限为 0700、文件为 0600。真实密钥只保存在私有配置卷，不写进仓库、Dockerfile 或 Compose 环境变量。每次 `click-target` 重新读取配置，修改后下一次调用生效，无需重启容器或 daemon；已开始的请求不受影响。具体配置规则见 [模型配置说明](MODEL-CONFIG.md)。

通过 `mcc --remote` 调用 `click-target` 时，使用 **Docker Host 的模型配置**。客户端宿主机的配置不随远程请求自动复制；`--remote --config` 不支持修改服务端配置，仍通过上述容器本地命令管理。

## Host 模式：从容器外控制桌面

复用原来的 `mcc host` 和 `mcc --remote`，完整协议见 [远端控制说明](REMOTE-HOST.md)。调用经过 WSS → Host → daemon → Linux helper → X11/XTEST，鼠标轨迹与系统输入沿用容器内 CLI 的实现；不会启动 WebDriver。客户端与容器的 MCC 版本必须一致，本分支为 0.3.6。

先按前文构建镜像、设置 VNC 密码，再显式初始化一次 Host 凭据。这两个命令拒绝覆盖已有文件；重启时沿用原凭据：

```sh
docker compose run --rm -T --no-deps --entrypoint mcc mcc \
  host tls init --ip 127.0.0.1 --output-dir /home/mcc/.config/mcc/host-tls
docker compose run --rm -T --no-deps --entrypoint mcc mcc \
  host token init --output /home/mcc/.config/mcc/host.token
docker compose -f compose.yaml -f compose.host.yaml up -d --wait --wait-timeout 90
```

`compose.host.yaml` 设置 `MCC_HOST_ENABLED=1`，容器内监听 `0.0.0.0:8765`，默认发布为宿主 `127.0.0.1:8765`。后续 `up`/`stop`/`down` 都使用相同的两个 `-f` 参数。基础 `compose.yaml` 单独使用时保持 Host 关闭。凭据缺失、权限不正确或 Host 退出会使启动失败或结束容器；启动脚本不会自动初始化凭据或解除恢复锁。

将 CA 公钥和访问 token 导出到宿主私有目录。服务端私钥和 CA 私钥留在容器卷中：

```sh
install -d -m 700 "$HOME/.config/mcc/docker-host"
(
  umask 077
  docker compose exec -T mcc cat /home/mcc/.config/mcc/host-tls/host-ca.pem \
    > "$HOME/.config/mcc/docker-host/host-ca.pem"
  docker compose exec -T mcc cat /home/mcc/.config/mcc/host.token \
    > "$HOME/.config/mcc/docker-host/host.token"
)
# 构建宿主 CLI；不替换已安装的 mcc：
cargo build --locked --bin mcc
# 在仓库根目录的当前 shell 中定义快捷命令：
mccd() {
  ./target/debug/mcc --remote wss://127.0.0.1:8765/mcc/v1 \
    --ca-cert "$HOME/.config/mcc/docker-host/host-ca.pem" \
    --token-file "$HOME/.config/mcc/docker-host/host.token" \
    --remote-state-dir "$HOME/.config/mcc/docker-host/client" "$@"
}
mccd status
mccd firefox start --profile default --url https://example.com
mccd observe --connection CONNECTION_ID --out /tmp/docker-firefox.jpg
mccd click --connection CONNECTION_ID --frame FRAME_ID --x 200 --y 180
mccd type --connection CONNECTION_ID --frame FRAME_ID --text '容器输入 AI'
mccd disconnect --connection CONNECTION_ID
```

`CONNECTION_ID` 来自 start 回执，`FRAME_ID` 来自最近 observe 回执。保存 start 回执供后续调用使用。远端截图自动下载到**客户端本机**的 `--out` 路径，目标文件必须尚不存在，每次观察使用新文件名；`actions --file` 同样读取客户端文件并通过原协议发送。一个桌面保持一个 owner：切换本地/远端前先从原控制端显式 disconnect，不通过重启或删除状态抢占。

跨机器调用时，将证书初始化的 `--ip` 换成客户端实际访问的宿主 IP，或用 `--dns` 指定域名；可重复添加 SAN，最多八项。启动时显式配置发布地址，例如：

```sh
MCC_HOST_BIND_IP=192.168.1.20 MCC_HOST_PORT=8765 \
  docker compose -f compose.yaml -f compose.host.yaml up -d --wait
```

客户端改用 `wss://192.168.1.20:8765/mcc/v1`，私下传递 CA 和 token 文件并保持目录 0700、文件 0600。证书 SAN 必须匹配访问地址。noVNC 仍绑定宿主回环地址；可通过 SSH 转发查看。Host 仅开放现有远程命令，不提供任意 shell 执行。

正常停止前先 `mccd disconnect --connection CONNECTION_ID`，再执行双文件 Compose 的 stop。Host 停止时若仍持有 owner，或进程意外退出，持久 journal 会要求恢复；重启不会自动清除。确认桌面应停止后执行本地恢复，再启动：

```sh
docker compose -f compose.yaml -f compose.host.yaml stop
docker compose run --rm -T --no-deps --entrypoint mcc mcc host recover
docker compose -f compose.yaml -f compose.host.yaml up -d --wait
```

恢复命令保留现有 PID/owner 校验，无法确认旧进程已停止时仍拒绝恢复。确认新 Host 身份后为客户端选择新的 `--remote-state-dir`（例如 `.../client-after-restart`）重新配对；更换客户端目录不能解除服务端恢复锁。不要删除 `remote-host` journal 或自动运行 recover。TLS/token 与恢复状态保存在 `mcc-config` 卷，Firefox 登录数据保存在原 profile 卷。

### 从宿主传文件并上传网页

Host 模式在私有 `mcc-transfers` 卷启用文件接收。沿用上文的 `mccd` 函数和 Firefox 连接：

```sh
# --local 是调用方本机文件，必须使用绝对路径。
mccd file put --connection CONNECTION_ID --local '/absolute/报告 with spaces.pdf'
# 保存回执中的 fileId；回执同时包含原文件名、bytes 和 sha256。

# 观察网页，点击它的“上传/选择文件”按钮，打开 Firefox 原生文件选择框。
mccd observe --connection CONNECTION_ID --out /tmp/before-file-picker.jpg
mccd click --connection CONNECTION_ID --frame FRAME_ID --x 200 --y 300
# 将 FILE_ID 替换为 file put 返回的 ID；无需输入容器路径或 frame。
mccd select-file --connection CONNECTION_ID --file-id FILE_ID

# 重新观察，确认网页显示已选文件，再按网页流程点击提交。
mccd observe --connection CONNECTION_ID --out /tmp/after-file-picker.jpg
```

文件通过已认证的 WSS 以 32KiB 二进制块传输，容器核对长度和 SHA256 后发布；不需要挂载宿主文件目录或 Docker socket。原始文件名保持不变，包括中文与空格。单文件最多 64MiB，每次传输有 55 秒总预算和 5 秒读等待；整个接收目录最多 256MiB、128 项。失败或中断的暂存文件清理后不会产生可选的 `fileId`。

`fileId` 仅供上传它的 Host 会话和 `connectionId` 使用。显式 `disconnect` 会清理该连接的文件，因此应等网页完成上传后再断开。Host 重启后旧 ID 失效；异常退出的残留继续占用配额，须由本地操作者在停止 Host 后检查清理，启动脚本不自动删除文件。

`select-file` 核验 Firefox 进程身份、父窗口、GTK 文件选择器角色和模态状态，再通过 X11 系统按键输入路径。没有选择框、身份不符或已暂停时拒绝输入；普通 `type`/`press` 仍要求浏览器主窗口的精确焦点。选择回执只确认原生选择框已关闭，网页是否接收文件需要观察确认；MCC 不自动提交表单。此流程不使用 WebDriver、Marionette 或 DOM 注入。

直接运行 `mcc host start` 时，文件接收默认关闭，需显式传 `--upload-dir /absolute/private/transfers`。原 `select-file --path` 仍指向 Host 文件系统，只允许 `--files-root` 放行的目录；启用文件接收不会放开任意 Host 路径。

## 持久化、密码与停止

| 卷 | 容器目录 | 内容 |
| --- | --- | --- |
| `mcc-config` | `/home/mcc/.config/mcc` | MCC 模型配置、Host TLS/token 与恢复状态 |
| `firefox-profiles` | `/home/mcc/.local/share/mcc/profiles/firefox` | Firefox profile |
| `vnc-secrets` | `/home/mcc/.secrets` | 私有 VNC 密码文件 |
| `mcc-transfers` | `/home/mcc/.local/share/mcc/transfers` | Host 私有文件接收与异常退出残留 |

首次创建的命名卷继承镜像目录的 UID 1000 和 0700 权限。替换为 bind mount 时，目录必须由 UID 1000 拥有且可写；密码文件必须由 UID 1000 拥有、为普通文件、权限 0600，不能使用符号链接。启动失败不会以 root 自动修复宿主权限。

密码可通过同一个交互命令更换，再重建运行中的容器：

```sh
docker compose run --rm -it --no-deps \
  --entrypoint /opt/mcc/bin/mcc-vnc-password mcc
docker compose up -d --force-recreate
```

显式配置其他密码文件时，将私有文件挂载到容器，并设置 `MCC_VNC_PASSWORD_FILE` 为对应绝对路径；默认流程无需 bind mount。VNC 密码不会作为进程参数或日志内容输出。

```sh
docker compose stop
# 删除容器和网络，保留配置、密码与 profile：
docker compose down
# 重启后使用同一个 --profile 名称复用浏览器数据：
docker compose up -d --wait
```

`docker compose down -v` 会删除这四个卷，包括浏览器数据、凭据与传输文件；只有明确要重置时执行。不要单独在常驻容器内执行 `mcc daemon stop`：daemon 是容器的受监督服务，停止它将结束桌面。

## 版本、校验与构建边界

| 组件 | 固定版本 | 校验来源 |
| --- | --- | --- |
| 运行/编译系统 | Ubuntu 22.04 | 官方 `ubuntu:22.04` 镜像；APT 取得该发行版的维护更新 |
| Firefox | `153.7.0esr`，en-US，Mozilla 官方非 Snap 构建 | [Mozilla SHA512SUMS](https://archive.mozilla.org/pub/firefox/releases/153.7.0esr/SHA512SUMS)，对应值保存在 `docker/firefox.sha512` |
| Rust | `1.89.0` | [官方工具链 manifest](https://static.rust-lang.org/dist/channel-rust-1.89.0.toml) 的 `xz_hash`，保存在 `docker/rust.sha256` |

安装脚本只接受上述版本，分别核对两个架构的归档哈希；没有运行时 `latest` 下载。更新版本时同步安装脚本、对应校验文件与本表，并重新验证浏览器输入和截图。Firefox 下载只发生在构建阶段。

Rust 编译器、Cargo、标准库也使用已固定校验的官方发行包。`mcc` 与 `mcc-linux-helper` 在 Ubuntu 22.04 上执行 `cargo build --release --locked --bin mcc --bin mcc-linux-helper`，避免从更新的系统复制出依赖更高 glibc 版本的二进制。网页运行时保留 Firefox sandbox，不设置 `MOZ_DISABLE_CONTENT_SANDBOX`，不加 `--no-sandbox` 或特权模式。默认 Compose 丢弃容器 capabilities 并使用 `no-new-privileges`。

镜像包含 Tesseract 的 `eng`/`chi_sim`、Noto CJK 字体、GTK/X11 依赖，以及用于诊断的 `xdpyinfo`、`xprop`、`xdotool`；图像编码由 Rust helper 完成。

可先缓存不依赖 Rust 源码的桌面层：

```sh
docker build --target desktop-base -t mcc-desktop-base:dev .
docker build --target rust-toolchain -t mcc-rust-toolchain:dev .
# 不需要 Rust 二进制的实际桌面/可见 Firefox 依赖检查：
docker/test-desktop-base.sh mcc-desktop-base:dev
# 在可执行 amd64 镜像的 buildx 环境中构建分发镜像：
docker buildx build --platform linux/amd64 --load -t mcc-desktop:amd64 .
```

## 验证与诊断

打包层本地检查：

```sh
bash -n docker/desktop-entrypoint.sh docker/healthcheck.sh
sh -n docker/install-browser.sh docker/install-rust.sh
python3 docker/test-vnc-password.py
docker compose config --quiet
docker compose -f compose.yaml -f compose.host.yaml config --quiet
```

完整验收脚本在已设置密码并健康启动的专用测试桌面中执行：

```sh
docker compose exec -T mcc python3 - < tests/docker_smoke.py
docker compose exec -T mcc python3 - < tests/docker_remote_smoke.py
# 此测试故意保留已打开的 Firefox，再停止/重启容器：
docker compose exec -T -e MCC_PERSIST_PHASE=set mcc python3 - < tests/docker_persistence_smoke.py
docker compose stop
docker compose up -d --wait
docker compose exec -T -e MCC_PERSIST_PHASE=check mcc python3 - < tests/docker_persistence_smoke.py
```

宿主跨端口验收使用 `tests/docker_host_smoke.py`。在专用 Host 桌面上完成上述初始化、导出凭据和启动后执行（替换容器名和端口）：

```sh
python3 tests/docker_host_smoke.py --files --mcc ./target/debug/mcc \
  --remote wss://127.0.0.1:8765 \
  --ca-cert "$HOME/.config/mcc/docker-host/host-ca.pem" \
  --token-file "$HOME/.config/mcc/docker-host/host.token" \
  --container YOUR_DEDICATED_TEST_CONTAINER
```

此脚本在宿主启动临时 fixture HTTP 服务，并通过 `host.docker.internal` 供 Firefox 访问。Linux Docker Engine 需在测试 Compose 中为该名称添加 `extra_hosts: ["host.docker.internal:host-gateway"]`。脚本会启动新的测试 profile 并操作桌面，只用于独立验收容器；不会自动接管已有会话。它验证发布端口、TLS/token、错误 token 拒绝、本机图像下载、系统点击、Unicode 输入、客户端 Actions 文件与断开。`--files` 另外验证分块传输、SHA256、跨会话/连接拒绝、Host 路径限制、无选择框与暂停拒绝、普通输入焦点门禁、GTK 原生选择、真实 multipart 内容和断开后的文件清理。

验收覆盖原生窗口 JPEG/OCR、实际系统光标轨迹、Unicode 输入、Control、拖拽/滚动、旧帧拒绝、明确暂停释放、普通 noVNC 操作不暂停及 Firefox 退出恢复。具体架构、测试数量和最新镜像见 [验收记录](MCC-DOCKER-VALIDATION.md)。测试页由自身上报事件；MCC 没有注入或执行网页脚本。

当前验收使用 macOS 上的 OrbStack Linux 引擎。普通 Ubuntu GNOME/Wayland 桌面、容器内微信业务及 Windows/macOS 的 Firefox 后端未在本分支交付。

完整测试数量、两种架构的运行范围与审查修复见 [验收记录](MCC-DOCKER-VALIDATION.md)。

```sh
docker compose exec mcc id
docker compose exec mcc tesseract --list-langs
docker compose exec mcc /opt/firefox/firefox --version
docker compose exec mcc /opt/mcc/bin/mcc-desktop-healthcheck
docker compose logs --tail 100 mcc
```

缺少/权限不正确的密码文件会在启动桌面前拒绝。配置或 profile 卷不可写会明确失败。Firefox 或显示服务故障由 helper/监督进程返回并停止有关资源；排除故障后重启容器，按回执显式恢复会话。
