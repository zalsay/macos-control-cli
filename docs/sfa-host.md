# sfa Host（SSH）

Host 模式让另一台机器调用 Mac 上已授权的 Safarier 浏览器。客户端显式指定 SSH 目的地；已有本地命令默认仍在本机运行。

与 MCC Host 一样，Host 只接受列入白名单的控制动作，复用宿主的浏览器权限和控制连接，断线或超时后不自动重放。但它使用 OpenSSH 鉴权和主机校验，不使用 MCC 的 WSS、token 或协议，不能用 `mcc --remote` 连入。

## 宿主边界

- 使用已有 OpenSSH 服务，在 Safarier Manager 所在的同一个 macOS 用户下配置。为此用途单独生成 SSH 密钥，仅把公钥配置成带固定命令的 `restrict,command="…"` 条目；不要给同一把密钥另加可登录条目。客户端应通过可信渠道核实并预置宿主公钥，保留严格主机校验。
- 固定命令必须指向受信任的绝对路径，由宿主选择实际 App、专用私有 runtime 和允许的 profile。不要复用其他控制任务的 runtime，不要给不互信的客户端共享密钥或 runtime。为隔离权限，不要把 SSH 密钥用在有更宽权限的条目、系统或任务里。
- Manager、目标 profile 的 Runner 和对应本地控制 daemon 由宿主先准备。Manager 可从「环境 → SSH Host」按当前选中的 profile 查询、启动或停止它自己的 scoped daemon；启动要求该 profile 允许 Agent 控制。用实际 GUI 用户环境和一致的 workspace/安装包启动；SSH 身份验证不会替代 Safarier 原有身份检查、AppleEvents 授权或 Agent 开关。
- GUI 的「已启动/正在运行」只确认 scoped daemon 已就绪，不会探测 Apple Events 授权，也不保证浏览器控制已获准。首次连接失败时应分别检查 Manager 的 Apple Events 权限和 profile 的 Agent 开关；不要为了排查自动重复触发系统授权提示。
- 若确需让该 Host 请求 Apple Events 授权，在 Manager 选中 profile 后显式点「环境 → SSH Host → 为 Host 授权…」。它只向该 profile 已运行的本地 daemon 派发一次权限请求，不启动 daemon、不发送浏览器业务事件，也不自动重试；处理系统提示后可点「查看授权结果」查询同一请求。`pending` 不是授权结论，完成回执只代表该次请求的历史结果，不是当前权限探测；后续 connect 仍走原有实时权限门禁。SSH 白名单拒绝授权请求与回执查询。
- 远端不能启动/停止 daemon、选择 App/runtime 或调用本地文件选择。显式导航只接受 HTTP/HTTPS；不要在远程专用 profile 中打开本地文档或其他不打算分享的页面。窗口、浏览器环境、输入权限和交回回执仍由原控制链路处理。

宿主先打开 Manager 和获准的浏览器环境，在 Manager 中选择目标 profile，再用「环境 → SSH Host → 查询 Host 状态」确认或「启动 Host…」启动该 profile 专用 daemon。启动与查询均在后台执行，结果会显示在 Manager 中；停止会先请求 daemon 正常退出，若有活动控制连接会显示忙碌并保留 daemon，不会强制结束进程。也可以用以下命令进行定向诊断：

```sh
PROFILE_UUID='填入 sfa profile list 所示的 UUID'
# 路径后缀使用小写 UUID。
runtime="$HOME/.safarier-control-host-$(printf '%s' "$PROFILE_UUID" | tr '[:upper:]' '[:lower:]')"
sfa control --runtime "$runtime" daemon start
```

在宿主的 `authorized_keys` 中，仅为专用公钥添加类似下面的一行。替换用户名、profile UUID 及公钥；如果 App 不在默认位置，固定命令也要显式设置同一个 `SF_APP`：

```text
restrict,command="/Users/alice/.local/bin/sfa host serve --profile 01234567-89ab-cdef-0123-456789abcdef" ssh-ed25519 AAAA... safarier-host
```

该入口每次通过 SSH 的标准输入/输出处理一个请求，不另外监听端口。请求的 profile 必须匹配固定配置、并已允许 Agent 控制；已建立的连接也会复核 profile 归属。

## 客户端

在客户端的 SSH 配置中为该专用密钥设置别名（以下为示例）。首次连接前，先通过可信渠道把宿主公钥加入客户端的 `known_hosts`：

```sshconfig
Host safarier-mac
    HostName mac.example.net
    User alice
    IdentityFile ~/.ssh/safarier-host
    IdentitiesOnly yes
```

客户端需要带远程入口的 macOS 版 `sfa`。显式指定别名才会走远程：

```sh
sfa --remote safarier-mac control status
sfa --remote safarier-mac control connect --profile "$PROFILE_UUID"
# CONNECTION_UUID 取自成功的 connect 回执里的 connection。
sfa --remote safarier-mac control state --connection "$CONNECTION_UUID"
sfa --remote safarier-mac control observe --connection "$CONNECTION_UUID"
sfa --remote safarier-mac control release --connection "$CONNECTION_UUID"
```

远端连接不是独立于宿主的另一套浏览器权限；同一专用密钥用于同一授权边界内的调用者。撤销访问应移除对应公钥，并由宿主核对尚未交回的控制连接。如果远端已无权交回，用宿主本地的 `sfa control --runtime "$runtime" release --connection "$CONNECTION_UUID"`，而不是重启 daemon。

首版远程 `observe` 返回 frame、viewport 和可用的 OCR，不复制 PNG，也不把宿主文件路径当作客户端路径。需要查看截图的任务仍需在宿主本地执行。

## 断线和交回

超时、SSH 断线或回复无法校验时，命令可能已经发出；不要据此重发输入、导航、connect 或 release。保留错误，优先用已知 connection 读取 `state` 或 `observe`。如果没有拿到 connection ID 或仍无法确定状态，请宿主核对并恢复。SSH 退出不会自动 release；停止 daemon 也不等于浏览器已交回。

完成后显式 release，核对 `inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 都为 `true`。连接和 frame 仍属于该宿主/runtime，不可跨宿主复用。
