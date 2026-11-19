# Safarier AI CLI 操作指南

用于打开或连接已授权的浏览器环境、观察页面、原生操作及交回窗口。以下是按任务选用的命令示例，不是需要全部执行的测试清单。以当前用户指令和实际 CLI help/错误为准。

跨机器控制请见 [sfa Host（SSH）](sfa-host.md)。同机 DSH 调用本机 `sfa` 时不需要 Host。

## 1. 安装一次 sfa，找到实际 App

在项目根执行一次，安装真实启动脚本至 `~/.local/bin/sfa`：

```sh
sh scripts/install-cli.sh
# 仅当 PATH 尚未包含 ~/.local/bin 时，在当前 shell 设置：
export PATH="$HOME/.local/bin:$PATH"
sfa --help
sfa control --help
```

也可直接使用 `"$HOME/.local/bin/sfa" --help`，无需修改 shell rc。`sfa` 将所有既有 CLI 参数原样透传，没有 wrapper 专用参数。
默认先找 `$HOME/Applications/Safarier AI.app`，缺失时兼容 `$HOME/Applications/Safarier.app`，读取实际 `CFBundleExecutable` 执行，不扫描归档。不能只凭目录名判定版本，以实际执行包及 help 显示的功能/版本为准。
安装 `sfa` 不代表安装或更新了 App，也不会切换正在运行的 Manager。App 装在其他位置时，可选设置：

```sh
export SF_APP="/实际安装位置/Safarier AI.app"
```

`SF_APP` 非空时只使用该显式位置，不 fallback；正常默认安装无需每次设置长路径。
新包 Manager 的 Name/DisplayName/Executable 均为 `Safarier AI`；内嵌 `Contents/Helpers/Safarier AI Browser.app`，其 executable 为 `Contents/MacOS/Safarier AI Browser`，Name/DisplayName 同为 `Safarier AI Browser`。Bundle IDs 不变。
安装缺失或版本不符时说明环境阻碍，按当前授权处理安装更新。测试授权不自动授权退出或替换现有用户 App/窗口。运行目录必须满足 CLI 原安全校验；不要从外置卷归档绕过安装路径，也不要 chmod 放宽门禁。

本机构建推荐安装到 `~/Applications/Safarier AI.app`。本次实测系统 `/Applications` 为 `root:admin 0775`，组可写，不满足原身份校验对祖先目录 `(mode & 0022) == 0` 的要求；即使包的 pins 与签名正确也会拒绝，`SF_APP` 不会绕过该门禁。这是当前目录属性的限制，不是永久禁止所有 `/Applications` 安装；不要修改系统目录权限来绕过。

## 2. 打开 Manager，选择环境

仅当已有唯一 Manager 位于 sfa 选定的同一安装位置且身份校验通过时，才跳过启动。若路径不符或校验失败，先说明阻碍，按用户授权正常关闭并切换；不直接另开第二个 Manager。尚未打开时，可手动打开实际安装的 App，或在当前任务授权范围内使用 `open -g "/实际安装位置/Safarier AI.app" --args --show-manager-without-activation`；路径应与 sfa 选择的包一致。后续手动打开仍正常激活。随后列出环境：

```sh
sfa profile list
```

确认实际唯一 Manager 的路径、签名与 workspace。`profile list` 是表格输出，无 `--json`；按目标选 UUID，可使用已有“视频号”等授权环境，不要求新建 fixture。同名多项时先明确目标。
CLI 与 Manager 必须使用一致的 `SAFARIER_HOME`/workspace；不要为了连接改 profile 设置或复制环境。testing 默认数据目录仍是 `~/Library/Application Support/Safarier Test`，不是 App 改名遗漏，不迁移现有数据。
目标未运行时普通启动；已有目标 Runner 窗口则直接进入连接步骤，不重复 launch：

```sh
PROFILE_UUID="从 profile list 选出的 UUID"
sfa launch "$PROFILE_UUID"
```

`launch` 请求已有 Manager，不会代为启动 Manager。启动会请求激活浏览器窗口；返回成功不等于窗口已获得焦点或控制连接已建立。接管要求浏览器已不在前台且窗口不是 key/main；用户切换到其他应用后再 connect。不会在 connect 时自动切换前台应用，以 connect 的真实结果为准。

Manager 唯一性检查只计入已完成 GUI 启动且未退出的应用；同 bundle ID 下未启动 GUI 的 CLI/daemon 注册记录不会被计作第二个 Manager。多个真正的 GUI Manager 仍拒绝歧义路由。

AppleEvents 权限查询和业务请求均使用已核验 Manager 的系统进程序列号（PSN），绑定这一次进程启动。不会再按 bundle ID 查找接收者，避免同一可执行文件的 `sfa daemon` 被系统选成目标。PID 只用于从已持有的 Manager 获取并核验进程身份，不直接作为 AppleEvent 地址；Manager 更换时仍需重新建立客户端。

### Manager 重启后重新接管

新版 Runner 在 Manager 退出后保留已打开的窗口和标签。旧控制会话必须先清理并还回输入，再允许新 Manager 重新认证。重新打开 Manager 后，对同一环境发出新的 `connect`，以返回的新 connection 开始 `observe`，不复用旧 frame 或重发之前的输入。如果 daemon 仍在运行，显式 `connect` 会在确认原 Manager 已退出后验证和切换接收端；旧连接不能发送给新的 Manager。

此行为要求运行中的 Runner 已支持重连。旧版已打开的环境仍可能返回 `PROFILE_ALREADY_RUNNING`，需先保存页面内容，再由新版 Manager 启动一次。环境授权关闭、进程或环境身份不一致、旧输入无法确认已释放时，不会接管。随 Manager 退出的 DSH 任务不会自动恢复。

### 单独查询或申请 AppleEvents 授权

在同一个实际执行宿主（例如 Copis/DSH）的子进程链中使用：

```sh
sfa authorize            # 默认只查，不弹权限提示
sfa authorize --request  # 仅用户明确要求授权时执行一次，由用户本人点系统提示
```

须已有同位置且通过身份校验的唯一 Manager；该命令不启动 App/环境/daemon，不发送 `SFAu/requ` 业务事件，仅向系统查询或申请这个精确事件范围。等待人工提示不套单次控制操作期限；不要让外部 driver 用短超时反复重试。返回 JSON 的 `status` 为 `allowed`、`consent_required`、`not_permitted`、`target_changed` 或 `unavailable`，含 `statusDescription`、`osStatus`（未调用时可为 null）、`businessEventSent:false`。仅 `allowed` 退出码为0，其他结果为1，参数错误为64。系统未许可不等于已证实用户刚点拒绝；目标变更时不得使用本次授权结果。

默认只读查询在进入权限调用后最多等待5秒；系统权限 API 未及时返回时输出 `unavailable`、`osStatus:-1712`，表示授权状态未知，不代表已授权或拒绝。底层 API 无法取消，迟到结果会被丢弃；命令不自动重试，也不转为申请授权。该期限不包含原有的 Manager 身份核验时间，不适用于 `--request` 的人工同意等待。

权限归属由 macOS TCC 决定，不因 `sfa` 名称固定而跨宿主共享。此前 Copis 缺少 NSAppleEventsUsageDescription 是历史诊断；用户现已在同一 Copis/DSH 宿主实测返回 `allowed`，不再将该缺失描述为当前状态。没有提示或仍未许可时保存结果并停止；不要借 Codex、另一终端或测试 SwiftHost 的授权代替 Copis，也不要重置 TCC。授权成功只证明权限及本次目标身份检查通过，不代表连接、页面控制或业务验收成功。

## 3. 建立连接，观察页面

已注册浏览器的控制连接不再按90秒代次或60秒空闲自动到期，也不再按剩余代次预算拒绝新命令。单次启动、IPC 与系统调用仍有超时；超时不能解释为网页未执行。sfa 不自动重放输入或导航，agent 根据回执及 observe 决定后续操作，完成后主动 release。

已注册连接中的 `state`/`observe` 单次超时不会再让 Runner 状态机关闭整个会话。完整发送后的只读请求超时或取消时，客户端返回原调用错误，并保留原请求关联信息来核验、消费迟到回包；迟到结果不会交给下一次调用。真实通道断开或回包不匹配仍返回实际错误。`release` 的准备/提交明确返回无副作用的 `SESSION_BUSY` 或 `INVALID_POINTER_STATE` 时，允许新的显式 release；提交重试沿用原 transferID，不重复准备。没有自动重试，真实交还回执未完成时也不会声称释放成功。

```sh
SF_RUNTIME="$(mktemp -d "$HOME/sfc-XXXXXXXX")"
chmod 700 "$SF_RUNTIME"
SF_EVIDENCE="$(mktemp -d "$HOME/sf-evidence-XXXXXXXX")"
ctl() { sfa control --runtime "$SF_RUNTIME" "$@"; }
ctl daemon start
ctl connect --profile "$PROFILE_UUID" > "$SF_EVIDENCE/connect.json"
CONNECTION_UUID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"]=="ok"; print(d["connection"])' "$SF_EVIDENCE/connect.json")"
ctl observe --connection "$CONNECTION_UUID" > "$SF_EVIDENCE/observe.json"
```

每步检查退出码和 JSON `status`；失败时不要继续粘贴后续命令。control 默认使用当前实际 bundle，无需手写 `--app`；整轮保持同一 App 选择（不切换 `SF_APP`）与 `--runtime`。
connect 返回 `connection` 与 `viewport`，没有 target；需要比较窗口身份时，`ctl state --connection "$CONNECTION_UUID"` 的 `state.target` 包含 profile/runnerInstance/window/page 四项 identity。
observe 返回 `frame`、`screenshotPath`、`viewport` 和可选 `ocr`。注册会话的截图文件保留最近32张，超出后轮换旧文件。先查看截图；OCR unavailable 不等于截图失效。需保留证据时，在结束控制前复制 PNG 到独立 evidence，artifact 可能随清理删除。
`frame` 绑定这次截图，输入坐标是该图的像素坐标；viewport 提供截图尺寸、页面视口与缩放信息。不要把屏幕全局坐标传入。每个连接保留最近32个 frame，不因导航或文档版本变化立即废弃；坐标按所引用截图的 viewport 换算。agent 自行判断是否需要新截图。未知或已移出保留范围的 frame 返回 `INVALID_FRAME`，没有发送输入。

## 4. 按本轮截图进行原生操作

下面变量取自本轮 observe JSON 与实际截图；按任务选择动作，不要整段盲跑：

```sh
ctl move --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --x "$PIXEL_X" --y "$PIXEL_Y"
ctl click --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --x "$PIXEL_X" --y "$PIXEL_Y" --count 1
ctl type --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --text "$TEXT"
printf '%s' "$TEXT" | ctl type --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --text-stdin
ctl press --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --key Tab
ctl press --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --key PageDown
ctl press --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --key PageUp
ctl press --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --key Enter --wait-navigation
ctl back --connection "$CONNECTION_UUID" --frame "$FRAME_UUID"
ctl observe --connection "$CONNECTION_UUID"
```

`type` 的 `--text` 与 `--text-stdin` 二选一。先通过已支持的原生动作定位输入框；只输入用户授权内容。页面变化后用新截图判断结果，原生回执不等于业务效果成功。
显式导航现有浏览器使用 `ctl navigate --connection "$CONNECTION_UUID" --url "$URL"`。浏览器接受请求后返回 `navigationSubmitted: true`、`effectVerified: false`，不等待页面加载完成、不确认搜索或业务效果。agent 通过 `observe` 自行确认页面。页面重定向、历史变化、加载失败不撤销已提交回执，也不作为关闭控制通道的理由。
普通原生输入返回 `sent: true`、`effectVerified: false`，表示事件已送出。已注册浏览器的 `click ... --wait-navigation` 和 `press ... --key Enter --wait-navigation` 保留命令兼容，只发送一次输入并返回投递事实，不再等待或断言导航发生。真实目标消失、系统调用或通信失败仍如实返回错误，不能据此自动重复动作。

`press --key PageDown` / `PageUp` 向当前焦点发送原生向下/向上翻页键，名称区分大小写。先让需要滚动的正文区域获得焦点；实际是否滚动、滚动哪个容器由浏览器和页面处理，再用 `observe` 确认。两个按键不接受 `--shift` 或 `--wait-navigation`，不增加鼠标滚轮支持。

`back` 是 `press --key Backspace` 的便捷别名，使用同一个按键投递和回执路径。焦点不在可编辑内容中时，由 Safarier 原生 Backspace 行为处理历史后退；输入框或可编辑内容获得焦点时仍执行退格删除。需要后退时，先通过观察确认焦点，必要时点击页面非编辑区域再发送。没有历史记录时不保证发生页面变化。sfa 不判断后退是否成功，agent 应通过后续 `observe`（需要时结合 `state`）确认。`back` 不接受 `--shift` 或 `--wait-navigation`。

```sh
ctl click-target --connection "$CONNECTION_UUID" --target "页面上明确的目标文字"
```

click-target 使用本地 OCR 与真实 JEV 模型选择，再走原 native click；只发送目标与候选 ID/文字，不发送截图或坐标。它不支持 `--wait-navigation`；模型拒绝或候选不确定时不能声称已点击。成功后仍需截图核实效果。
JEV 默认读 `~/.config/mcc/models.toml`，也可由 daemon 启动环境 `MCC_CONFIG_DIR` 指向绝对私有目录（目录0700、文件0600）；不要输出密钥。Manager“设置”/“JEV 模型配置…”使用同一配置。改配置目录需重启对应 daemon；不要为测试通关擅改用户模型设置。

点击网页的“上传”按钮打开原生选档窗口后，用同一连接传入本机绝对文件路径：

```sh
ctl select-file --connection "$CONNECTION_UUID" \
  --path "/绝对路径/封面.png" --path "/绝对路径/内页.png"
ctl observe --connection "$CONNECTION_UUID"
```

`select-file` 不需要截图 `frame`。每个文件使用一个 `--path`，最多 20 个，网页必须允许多选才能一次传入多个文件。仅选择当前连接期间由此网页打开的文件选取面板；目录选择不支持。没有待选面板返回 `FILE_DIALOG_NOT_FOUND`，文件不可读或不是普通文件返回 `FILE_NOT_READABLE`；文件校验失败时保留面板，可修正路径后再次调用。回执 `filesSelected` 表示交给网页的文件数，`effectVerified: false` 表示不确认上传或发布结果，由 agent 通过 `observe` 判断。

## 5. 释放控制，保留窗口

操作完成及时交回人工，不关闭浏览器窗口：

```sh
ctl release --connection "$CONNECTION_UUID" > "$SF_EVIDENCE/release.json"
# 核实 status:ok 及下述四项真实证明后，再停止 daemon。
ctl daemon stop
```

release 成功应含 `controlReleased`：`inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 四项均 true，并记录真实 target。保留原始回执；daemon 退出或 socket 消失不能代替这四项证明。

已注册连接完成首次握手后，请求和回执不再重复扫描包资源、复核进程身份及读取绑定配置。普通命令的 Agent 开关由 Manager 检查，Runner 不再重复读取授权；release 不读取业务授权或配置。首次握手校验、连接失效/取消、请求关联与实际执行对象检查仍保留。

已注册浏览器的 release 使用组合预算：等待已接收输入最多 10 秒、prepare 和 commit 各最多 10 秒、最终通道排空最多 4 秒，总预算 34 秒。Runner 的两阶段握手总期限为 20 秒，每个动作仍单独限时 10 秒。AppleEvent 接收端使用同一总预算，发送端另留 10 秒传输余量。这些期限限定执行和通信，不判断页面效果；任何阶段缺少真实确认仍返回失败。
正常确认结束后可人工接续，也可对同一 profile 新 connect 开始新的控制连接；不要重复 launch。旧 connection 不再使用，需要同窗口验收时比较新旧 target。
已有 persistent 环境沿用原 cookie/storage。borrowed cancel/disconnect 的 `retainedBrowser` 与 owned 临时页面的 `cleaned/terminatedOwnedRunner` 是不同证明，不把保留窗口误报为已销毁或已退出。

## 6. 示例：读取“视频号”可见播放量

1. `sfa profile list` 找到用户授权的“视频号”环境并确认 UUID；已有 Runner 直接 connect，未运行才普通 launch，不创建替代副本或更改 cookie/profile。
2. observe 保存截图/OCR，按实际可见页面选用原生导航，进入统计页。登录或验证码交用户处理，由 agent 决定何时继续；完成任务后交还控制。
3. 按用户指定的账号、作品或页面读取实际可见播放量，注明实际可见的标题、发布时间、统计区间及采集时间；未显示的信息注明不可见，不主动扩展到其他指标。未经核图的 OCR 数值标注为候选，无法确认不编造。
4. 保存授权范围内的截图供核对，release 后保留窗口。只读任务不发布、点赞、评论或发送，不访问隐藏 API/凭据。

## 7. 遇到限制时

- 已注册控制没有固定90秒寿命；仍需主动 release 并核对交还回执。单次请求超时或传输中断不等于页面未执行，不自动重放。
- mouseDown/mouseUp 若使用，须在10秒 held 门限内配对；滚轮目前禁用。
- 不全局输入、不 DOM 合成输入、不用 PID 路由。身份拒绝时检查实际 App 路径、唯一 Manager、授权与 workspace/profile 一致性，以实际错误为准，不修改门禁。
- `RUNNER_EXITED` 不能单独证明进程已退出；generation 身份采样失败也可映射为此错误。保存原始结果，结合实际进程状态与本次连接阶段日志定位，不盲重连。
- TIMEOUT、INDETERMINATE 或其他结果不确定时保存原始输出，不盲重试输入或生命周期动作。release 已发出后不再用 disconnect“兜底”。
- daemon 不因历史 `uncertain` 或丢失 ACK 持续拦截后续显式命令或新 connect；原请求仍如实返回错误，不自动重放。普通命令由 Manager 检查 Agent 开关，Runner 复用已认证连接并核验实际执行目标及期限，正在执行或仍待 ACK 的请求仍受并发门禁限制。daemon stop 成功仅表示本地请求已排空，不能代替 release 的四项交还证明。
- 新系统权限提示、验证码或需要人工介入时交用户处理；不擅改权限或抢回前台。记录观察事实，不能仅凭窗口/鼠标没变化就断言用户无干扰。

### 控制请求诊断日志

控制链路使用 macOS 统一日志，子系统 `sh.safarier.testing`、类别 `navigation-trace`。日志仅记录动作固定类别、请求 UUID、固定阶段、已知结果码及单调时间；系统日志自身另带日期时间。`connect`、`observe`、`click`、`type`、`release`、`disconnect`（close）等可按同一个 `request` 关联 CLI、broker、Manager 和 Runner。release 的 `manager.release.child` 将原请求 UUID 放在 `request`，提交子请求 UUID 放在 `related_request`。 `click-target` 的 `broker.screenshot.child` 同样以 `request` 和 `related_request` 关联原请求与内部截图请求。`release.receipt` 的 `manual_interaction_enabled` 是回执中的布尔值，不是对焦点实际变化的观察。其它阶段未必全部出现：请求可能在进入某一层前被拒绝、超时或断开。

在本机查询或导出（日期范围按需缩小，文件存入用户自行选择的安全位置）：

```sh
log show --style compact --last 1h --predicate 'subsystem == "sh.safarier.testing" AND category == "navigation-trace"'
log stream --style compact --level default --predicate 'subsystem == "sh.safarier.testing" AND category == "navigation-trace"'
log show --style compact --last 1h --predicate 'subsystem == "sh.safarier.testing" AND category == "navigation-trace"' > safarier-control-diagnostics.log
```

系统日志由 macOS 管理，保留时间和容量受系统状态与配置控制，不能保证永久保存；需要留存时及时导出。旧版或其它同类别诊断也可能出现在查询中，分享导出文件前应检查其内容。Runner 的传统 stdout/stderr 仍在工作区 `logs/<profile UUID>.log`（同时启用 `SAFARIER_INTERNAL_TEST_APP` 和 `SAFARIER_BOUND_LOCAL_CANDIDATE` 的测试构建默认使用 `~/Library/Application Support/Safarier AI/`；其他构建默认使用 `~/Library/Application Support/Safarier/`。非空 `SAFARIER_HOME` 优先覆盖默认工作区）；该文件不包含所有进程的统一日志。

这些记录表示各层收到、处理或返回响应，`runner.reply.queued` 仅表示响应已排队；发送、入队、系统日志和原生输入回执均不能单独证明网页实际完成或产生预期效果。不要将日志缺失解释为操作没有发生，也不要据此自动重试不确定的操作。
