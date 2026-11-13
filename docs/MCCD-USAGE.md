# mccd 使用指南

`mccd` 是宿主机上的 shell 函数：把连接地址、CA、token 文件和客户端状态目录传给 `mcc --remote`，用于操作 Docker 内的 Firefox 桌面。它复用现有 MCC CLI，不是另一个二进制程序。

Firefox 使用普通桌面模式，键鼠通过 X11/XTEST 系统事件投递，鼠标沿 MCC 轨迹移动。可通过 noVNC 查看和人工接管。

## 1. 当前环境与命令定义

下表是本机在 2026-11-13 的配置；新机器的构建、密码和 Host 初始化见 [Docker 部署说明](MCC-DOCKER.md)。

| 项目 | 当前值 |
| --- | --- |
| 仓库 | `/Users/yingzhang/.codex/worktrees/mcc-docker/chrome-control-cli` |
| 宿主 CLI | 仓库内 `target/debug/mcc`，与容器同为 `0.3.6` |
| Host 地址 | `wss://127.0.0.1:8766/mcc/v1` |
| noVNC | <http://127.0.0.1:6080/vnc.html> |
| CA 文件 | `~/.config/mcc/docker-host/host-ca.pem` |
| token 文件 | `~/.config/mcc/docker-host/host.token` |
| 当前客户端状态目录 | `~/.config/mcc/docker-host/client-files-20261113` |

在宿主的 Bash 或 Zsh 中执行以下定义。函数使用绝对路径，因此定义之后可从任意目录调用：

```sh
MCCD_REPO='/Users/yingzhang/.codex/worktrees/mcc-docker/chrome-control-cli'
MCCD_REMOTE='wss://127.0.0.1:8766/mcc/v1'
MCCD_AUTH_DIR="$HOME/.config/mcc/docker-host"
MCCD_STATE_DIR="$MCCD_AUTH_DIR/client-files-20261113"

mccd() {
  "$MCCD_REPO/target/debug/mcc" \
    --remote "$MCCD_REMOTE" \
    --ca-cert "$MCCD_AUTH_DIR/host-ca.pem" \
    --token-file "$MCCD_AUTH_DIR/host.token" \
    --remote-state-dir "$MCCD_STATE_DIR" "$@"
}
```

可以把这段定义保存为 `~/.config/mcc/docker-host/mccd.sh`，在每个需要调用的终端加载：

```sh
source "$HOME/.config/mcc/docker-host/mccd.sh"
mccd status
```

也可自行在 `~/.zshrc` 或 `~/.bashrc` 加入该 `source` 行。定义中只保存 token 路径，不嵌入 token 内容；token 保持为当前用户的 0600 文件，所在目录为 0700。

迁移到新部署时修改仓库路径、Host 地址和凭据路径。Compose 默认 Host 端口为 **8765**，本机因端口占用使用 **8766**。首次连接新的 Host 可选择新的私有客户端状态目录；同一客户端建议复用原目录。Docker 中持同一 Host token 的客户端可以续用空闲的现有控制连接；切换目录不会解除明确暂停或恢复锁。

## 2. 检查服务

在宿主执行：

```sh
cd "$MCCD_REPO"
docker compose -f compose.yaml -f compose.host.yaml ps
docker compose -f compose.yaml -f compose.host.yaml logs --tail 80 mcc
mccd status

# 比较两端版本；mccd --version 只显示客户端版本。
"$MCCD_REPO/target/debug/mcc" --version
docker compose exec -T mcc mcc --version
```

需要启动已经完成初始化的容器时：

```sh
docker compose -f compose.yaml -f compose.host.yaml up -d --wait --wait-timeout 90
```

`status` 成功表示本次远程查询成功。它不会解除已有暂停，也不表示可以跳过窗口、帧和输入门禁。

## 3. 最小操作流程

### 启动 Firefox

```sh
mccd firefox start --profile google --url https://www.google.com
```

从成功 JSON 回执复制 `connectionId`，保留在当前终端。已有受控 Firefox 时，先运行 `mccd status`：Docker 的状态回执会返回当前 `connectionId`，无需寻找原启动回执，也无需重复启动 Firefox。`connectionId` 是连接标识；Host token 才是访问凭据。

```sh
CONNECTION_ID='替换为实际返回的connectionId'
```

`--profile` 是容器中的浏览器数据目录名称，允许 1–64 个字母、数字、下划线或短横线。同名 profile 复用登录信息；新名称使用独立数据。首次打开可能需要在 noVNC 处理浏览器提示。

启动只确认窗口已建立，网页是否加载完成需观察确认。一个桌面同一时间只执行一个动作。已有受管理 Firefox 时复用 `mccd status` 返回的 `connectionId`，不要重复 `firefox start`。持同一 Host token 的其他客户端在连接空闲时可以接续控制同一窗口；切换客户端后必须重新 `observe`，旧帧失效，旧回执仅可只读查询、不能重放，旧 `fileId` 需要重新上传。正在执行或等待 ACK/关闭的请求返回 `BUSY`，请等请求结束再试。该行为仅适用于 Docker 桌面，macOS 的客户端归属规则保持不变。

### 观察并取得帧

```sh
mccd observe --connection "$CONNECTION_ID"
```

回执包含 `frameId`、宿主本地的 `imagePath` 和 OCR。打开该图片，依据实际截图确定操作目标，再保存返回的帧 ID：

```sh
FRAME_ID='替换为最近一次observe返回的frameId'
```

指定截图位置时，路径属于**调用方宿主机**，文件必须尚不存在：

```sh
MCCD_OUTPUT_DIR="$(mktemp -d /tmp/mccd-demo.XXXXXX)"
mccd observe --connection "$CONNECTION_ID" --out "$MCCD_OUTPUT_DIR/01-home.jpg"
# 使用上一步新返回的 frameId 更新 FRAME_ID。
```

默认不传 `--out` 也会自动下载图片，客户端保留最近 32 张登记的自动截图。显式指定的输出文件不自动删除。

### 执行一次操作并复查

```sh
# 坐标仅为格式示例，先按真实截图修改。
mccd click --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 300 --y 180
mccd observe --connection "$CONNECTION_ID" --out "$MCCD_OUTPUT_DIR/02-after-click.jpg"
```

坐标相对于截图左上角，单位为原像素。截图包含 Firefox 标签栏和地址栏。新的 `observe` 会更新帧身份，后续输入使用新返回的 `frameId`；页面、标题、窗口位置或大小变化后重新观察。

### 结束

```sh
mccd disconnect --connection "$CONNECTION_ID"
```

在当前 Docker Firefox 后端中，显式断开会关闭该受管理的 Firefox、释放控制连接，并清理该连接上传的临时文件；profile 数据保留。普通命令执行完退出终端进程不等于显式断开，后续命令仍可复用连接。

## 4. 地址栏导航：以 Google 搜索 AI 为例

以下在已有 Firefox 连接上用系统按键导航。每个 `observe` 后，都把 `FRAME_ID` 更新为该次回执值，再执行下一条输入：

```sh
mccd observe --connection "$CONNECTION_ID"
# 更新 FRAME_ID。
mccd press --connection "$CONNECTION_ID" --frame "$FRAME_ID" --key Control+l

mccd observe --connection "$CONNECTION_ID"
# 更新 FRAME_ID。
mccd type --connection "$CONNECTION_ID" --frame "$FRAME_ID" \
  --text 'https://www.google.com/search?q=AI'

mccd observe --connection "$CONNECTION_ID"
# 更新 FRAME_ID。
mccd press --connection "$CONNECTION_ID" --frame "$FRAME_ID" --key Return

# 观察加载后的页面，确认是否显示搜索结果。
mccd observe --connection "$CONNECTION_ID"
```

Ubuntu 快捷键使用 `Control`，例如 `Control+l`、`Control+a`；`Cmd` 不会自动转换成 `Control`。若 Google 显示人机验证，可在 noVNC 中人工处理，完成后重新观察。

## 5. 常用输入命令

以下每条都是独立示例。坐标、帧和目标须来自当前窗口，页面变化后先重新观察。

```sh
# 文本输入与按键；先确认相应输入框已获得焦点。
mccd type --connection "$CONNECTION_ID" --frame "$FRAME_ID" --text 'Hello 容器'
mccd press --connection "$CONNECTION_ID" --frame "$FRAME_ID" --key Control+a
mccd press --connection "$CONNECTION_ID" --frame "$FRAME_ID" --key Return

# 双击、右键、带修饰键的点击。
mccd click --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 300 --y 200 --count 2
mccd click --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 300 --y 200 --button right
mccd click --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 300 --y 200 --modifiers control

# 平滑移动、悬停、拖拽。
mccd move --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 400 --y 250
mccd hover --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 400 --y 250 --duration-ms 500
mccd drag --connection "$CONNECTION_ID" --frame "$FRAME_ID" \
  --from-x 100 --from-y 300 --to-x 500 --to-y 300 --duration-ms 600

# 在指定位置向下滚动；负 delta-y 向上。
mccd scroll --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 600 --y 500 --delta-y 480
```

`move`/`drag` 不传时长时自动规划轨迹；`--duration-ms 0` 表示立即移动，正值最多 2000ms。`hover` 的时长表示到达后的停留时间。鼠标轨迹起点来自容器当前光标，noVNC 人工移动后也会重新读取。

需要把多个动作作为一组发送时，在**客户端本机**保存 JSON 文件：

```json
{"version":1,"steps":[
  {"type":"move","x":100,"y":300},
  {"type":"pointerDown","button":"left"},
  {"type":"move","x":500,"y":300,"durationMs":600},
  {"type":"pointerUp","button":"left"}
]}
```

```sh
mccd actions --connection "$CONNECTION_ID" --frame "$FRAME_ID" --file /absolute/actions.json
```

动作文件上限 64KiB，1–256 步，单步时长最多 2000ms、总计划时长最多 10 秒。按下与释放必须配对。回执 `effectVerified:false` 表示只确认输入投递，业务效果仍需重新观察。

## 6. 从宿主传文件并上传网页

先把宿主的文件传入容器：

```sh
mccd file put --connection "$CONNECTION_ID" --local '/absolute/报告 with spaces.pdf'
FILE_ID='替换为成功回执中的fileId'
```

`--local` 必须是调用方的绝对文件路径。回执包含 `fileId`、`name`、`bytes`、`sha256`，单文件上限 64MiB。

然后在网页上打开原生文件选择框：

```sh
mccd observe --connection "$CONNECTION_ID"
# 更新 FRAME_ID，按截图修改坐标，点击网页“选择文件/上传”按钮。
mccd click --connection "$CONNECTION_ID" --frame "$FRAME_ID" --x 200 --y 300

# 确认出现 Firefox 原生文件选择框后选择刚传入的文件。
mccd select-file --connection "$CONNECTION_ID" --file-id "$FILE_ID"
mccd observe --connection "$CONNECTION_ID"
```

`select-file` 只完成原生选择，网页可能随后自动上传，也可能需要继续点击“提交/发布”；按页面实际状态和已授权操作处理。等待网页完成上传后再 `disconnect`，因为断开会清理文件。

`fileId` 绑定原 Host 会话及 `connectionId`，换客户端状态目录、换连接或重启 Host 后不能沿用。`select-file --path` 指的是 Host 内路径，不会传输宿主文件；此处使用 `file put` + `--file-id`。

文件通道的总配额与超时规则见 [Docker 文件传输](MCC-DOCKER.md#从宿主传文件并上传网页)。

## 7. Jev 语义点击与模型配置

容器配置了模型后，可以直接描述当前页面的可见文字目标：

```sh
mccd click-target --connection "$CONNECTION_ID" --target '搜索按钮'
mccd observe --connection "$CONNECTION_ID"
```

此命令自行观察和 OCR，无需传 `--frame` 或坐标。它将目标描述与 OCR 候选文字发给配置的 Decisions 模型，选中候选后执行一次系统点击。它会调用外部模型，失败或目标不明确时不自动点击；详细数据契约见 [Jev 说明](JEV-CLICK-TARGET.md)。

模型配置读取 **Docker Host 内的** `/home/mcc/.config/mcc/models.toml`，宿主机自己的 `models.toml` 不会随远程调用同步。当前已同步的默认 profile 是 `jev`，模型为 `typesafe/jev-1.13`。用容器本地命令查看和管理：

```sh
cd "$MCCD_REPO"
docker compose exec -T mcc mcc --config show jev
docker compose exec -T mcc mcc --config default jev
docker compose exec -T mcc mcc --config enable jev
# 如需禁用：
docker compose exec -T mcc mcc --config disable jev
```

这些命令的 key 字段会脱敏。更新密钥用 `--api-key-stdin`，完整格式见 [Docker 模型配置](MCC-DOCKER.md#jev-模型配置)。修改后下一次模型调用生效，无需重启容器。

## 8. 登录信息和文件保存在哪里

| 内容 | 保存位置 | 生命周期 |
| --- | --- | --- |
| Firefox 登录信息、Cookie、浏览器设置 | `firefox-profiles` 卷 | 同名 `--profile` 复用；容器重建后保留，网站自身仍可能使登录过期 |
| Jev 配置、Host 证书/token、恢复状态 | `mcc-config` 卷 | 容器重建后保留 |
| VNC 密码 | `vnc-secrets` 卷 | 容器重建后保留 |
| 接收的上传文件 | `mcc-transfers` 卷 | 显式断开清理；异常残留须按部署说明处理 |
| 客户端会话与自动截图缓存 | 宿主 `MCCD_STATE_DIR` | 同一会话持续复用；与容器卷独立 |
| `observe --out` 截图、`actions --file`、`file put --local` | 调用方宿主的路径 | 由调用方管理 |

`docker compose down` 保留命名卷；`docker compose down -v` 会删除这些持久数据。

## 9. Docker 输入、明确暂停和恢复

Docker 独立桌面不使用 macOS 的自动人工接管阻拦：普通 noVNC 键鼠活动不触发 `USER_PAUSED`，不等待三秒倒计时，Host owner 在命令之间空闲超过 300 秒也不自动暂停。每条新命令会激活并检查目标窗口。

操作中失焦仍会停止当前动作并返回 `FOCUS_LOST`，但不会留下等待人工继续的暂停锁；重新观察后可发送新命令。人工按键或鼠标按钮未释放时返回 `INPUT_BUSY`，释放后即可继续。操作不会自动重放。

明确点击暂停/取消、传输中断导致结果不确定或恢复锁仍会停止输入，不会因 `status`、换客户端状态目录或新建连接而解除。有原控制条时先在 noVNC 按提示人工继续，再观察并发送新的操作。macOS 的自动暂停与三秒接管规则保持原样。

以下命令需要在容器本地执行，不能使用 `mccd` 远程管理：

| 操作 | 使用方式 |
| --- | --- |
| 模型配置 | `docker compose exec -T mcc mcc --config …` |
| Host/daemon 生命周期与恢复 | 宿主 Docker/容器本地命令 |
| `control state/pause/resume/cancel` | 容器本地 CLI；Host 持有 owner 时本地控制也会拒绝，使用可见控制条 |
| 处理网页人工验证、明确暂停 | noVNC 桌面 |

Host 重启或崩溃后出现 `RECOVERY_REQUIRED`，按 [Docker Host 恢复步骤](MCC-DOCKER.md#host-模式从容器外控制桌面) 执行。该流程会停止当前桌面，应确认操作应当停止后，在仓库目录执行：

```sh
docker compose -f compose.yaml -f compose.host.yaml stop
docker compose run --rm -T --no-deps --entrypoint mcc mcc host recover
# 只有 recover 成功后才继续启动。
docker compose -f compose.yaml -f compose.host.yaml up -d --wait --wait-timeout 90
```

恢复成功并确认新 Host 身份后，为新会话选择新目录，例如 `MCCD_STATE_DIR="$MCCD_AUTH_DIR/client-after-recovery-01"`，然后重新启动 Firefox 并保存新的连接和帧。恢复失败时保留状态和错误回执，不删除 journal 或循环重试输入。

## 10. 回执和常见问题

操作命令返回单行 JSON，成功时 `ok:true`，失败时退出码非零并包含 `error`；`--help` 返回文本，`--version` 返回客户端版本的 JSON。脚本应先检查退出码和 `ok`，再读取 ID，串行调用同一控制会话。

| 现象/回执 | 处理 |
| --- | --- |
| `mccd: command not found` | 当前 shell 尚未定义函数，执行 `source .../mccd.sh`；脚本需自行加载函数 |
| 连接失败 | 核对容器健康、宿主端口 8766、CA/token 路径和权限 |
| `PROTOCOL_ERROR` | 对照客户端和容器精确版本、scope 及具体握手错误 |
| `CONNECTION_BUSY` / `PROFILE_IN_USE` | 复用当前连接，或按正常断开流程结束原会话后再启动 |
| `BUSY` | 桌面上的操作须串行执行，等待前一条请求及 ACK/关闭结束后再试 |
| 帧过期、窗口或焦点变化 | 重新观察，使用新 `frameId` 和对应截图坐标 |
| `INPUT_BUSY` | 释放 noVNC 中仍按住的按键或鼠标按钮，再发送新操作，无需点击继续 |
| `OUTPUT_EXISTS` | `observe --out` 使用新的文件名，不覆盖已有图片 |
| `MODEL_NOT_CONFIGURED` / `MODEL_DISABLED` | 在容器本地查看、配置或启用默认模型 |
| `REMOTE_CLIENT_FAILED` | 检查服务、凭据和客户端会话；确认原连接已结束后才考虑新的状态目录 |
| `REMOTE_OUTCOME_UNKNOWN` | 先检查页面实际状态；不要自动重发可能已投递的输入 |
| `RECOVERY_REQUIRED` | 完成上一节 Host 本地恢复，再建立新会话 |

其他说明：[Docker 部署](MCC-DOCKER.md) · [远端协议与恢复](REMOTE-HOST.md) · [模型配置](MODEL-CONFIG.md)。
