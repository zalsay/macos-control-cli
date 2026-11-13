# Safarier AI CLI 操作指南

用于打开或连接已授权的浏览器环境、观察页面、原生操作及交回窗口。以下是按任务选用的命令示例，不是需要全部执行的测试清单。以当前用户指令和实际 CLI help/错误为准。

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

### 单独查询或申请 AppleEvents 授权

在同一个实际执行宿主（例如 Copis/DSH）的子进程链中使用：

```sh
sfa authorize            # 默认只查，不弹权限提示
sfa authorize --request  # 仅用户明确要求授权时执行一次，由用户本人点系统提示
```

须已有同位置且通过身份校验的唯一 Manager；该命令不启动 App/环境/daemon，不发送 `SFAu/requ` 业务事件，仅向系统查询或申请这个精确事件范围。等待人工提示不套控制代次90秒期限；不要让外部 driver 用短超时反复重试。返回 JSON 的 `status` 为 `allowed`、`consent_required`、`not_permitted`、`target_changed` 或 `unavailable`，含 `statusDescription`、`osStatus`（未调用时可为 null）、`businessEventSent:false`。仅 `allowed` 退出码为0，其他结果为1，参数错误为64。系统未许可不等于已证实用户刚点拒绝；目标变更时不得使用本次授权结果。

权限归属由 macOS TCC 决定，不因 `sfa` 名称固定而跨宿主共享。此前 Copis 缺少 NSAppleEventsUsageDescription 是历史诊断；用户现已在同一 Copis/DSH 宿主实测返回 `allowed`，不再将该缺失描述为当前状态。没有提示或仍未许可时保存结果并停止；不要借 Codex、另一终端或测试 SwiftHost 的授权代替 Copis，也不要重置 TCC。授权成功只证明权限及本次目标身份检查通过，不代表连接、页面控制或业务验收成功。

## 3. 建立短回合，观察页面

先准备好任务与证据保存位置，再 connect。控制代次最多90秒且不可续期；观察和动作都算在内，留出及时 release 的时间，不在连接后等待人工讨论。普通动作预算10秒；代次的剩余时间也可能更短。导航请求在单一60秒导航预算内最多3次尝试，只有初始打开、地址栏打开或已注册页面显式导航的安全 GET，且未重定向的主帧临时网络失败才允许第2、3次尝试，退避分别为0.5秒和1秒；已提交页面、POST、原生 click/Enter 重放、登录/验证码/证书失败、取消、目标或身份变化、以及结果不确定的情况都不重试。

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
observe 返回 `frame`、`screenshotPath`、`viewport` 和可选 `ocr`。先查看截图；OCR unavailable 不等于截图失效。需保留证据时，在结束控制前复制 PNG 到独立 evidence，artifact 可能随清理删除。
`frame` 绑定这次截图，输入坐标是该图的像素坐标；viewport 提供截图尺寸、页面视口与缩放信息。不要猜坐标或把屏幕全局坐标传入；导航后必须重新 observe。

## 4. 按本轮截图进行原生操作

下面变量取自本轮 observe JSON 与实际截图；按任务选择动作，不要整段盲跑：

```sh
ctl move --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --x "$PIXEL_X" --y "$PIXEL_Y"
ctl click --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --x "$PIXEL_X" --y "$PIXEL_Y" --count 1
ctl type --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --text "$TEXT"
printf '%s' "$TEXT" | ctl type --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --text-stdin
ctl press --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --key Tab
ctl press --connection "$CONNECTION_UUID" --frame "$FRAME_UUID" --key Enter --wait-navigation
ctl observe --connection "$CONNECTION_UUID"
```

`type` 的 `--text` 与 `--text-stdin` 二选一。先通过已支持的原生动作定位输入框；只输入用户授权内容。页面变化后用新截图判断结果，原生回执不等于业务效果成功。
链接单击需要等待导航时使用 `click ... --count 1 --wait-navigation`；也可用 `ctl navigate --connection "$CONNECTION_UUID" --url "$URL"`。完成后获取新 frame。动作预算不足时不发新输入。
可选语义点击：

```sh
ctl click-target --connection "$CONNECTION_UUID" --target "页面上明确的目标文字"
```

click-target 使用本地 OCR 与真实 JEV 模型选择，再走原 native click；只发送目标与候选 ID/文字，不发送截图或坐标。它不支持 `--wait-navigation`；模型拒绝或候选不确定时不能声称已点击。成功后仍需截图核实效果。
JEV 默认读 `~/.config/mcc/models.toml`，也可由 daemon 启动环境 `MCC_CONFIG_DIR` 指向绝对私有目录（目录0700、文件0600）；不要输出密钥。Manager“设置”/“JEV 模型配置…”使用同一配置。改配置目录需重启对应 daemon；不要为测试通关擅改用户模型设置。

## 5. 释放控制，保留窗口

操作完成及时交回人工，不关闭浏览器窗口：

```sh
ctl release --connection "$CONNECTION_UUID" > "$SF_EVIDENCE/release.json"
# 核实 status:ok 及下述四项真实证明后，再停止 daemon。
ctl daemon stop
```

release 成功应含 `controlReleased`：`inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 四项均 true，并记录真实 target。保留原始回执；daemon 退出或 socket 消失不能代替这四项证明。
正常确认结束后可人工接续，也可对同一 profile 新 connect 开始独立90秒代次；不要重复 launch。旧 connection 不再使用，需要同窗口验收时比较新旧 target。
已有 persistent 环境沿用原 cookie/storage。borrowed cancel/disconnect 的 `retainedBrowser` 与 owned 临时页面的 `cleaned/terminatedOwnedRunner` 是不同证明，不把保留窗口误报为已销毁或已退出。

## 6. 示例：读取“视频号”可见播放量

1. `sfa profile list` 找到用户授权的“视频号”环境并确认 UUID；已有 Runner 直接 connect，未运行才普通 launch，不创建替代副本或更改 cookie/profile。
2. observe 保存截图/OCR，按实际可见页面选用原生导航，进入统计页。登录或验证码交用户处理，先结束或明确暂停控制，不让90秒代次跨越人工等待。
3. 按用户指定的账号、作品或页面读取实际可见播放量，注明实际可见的标题、发布时间、统计区间及采集时间；未显示的信息注明不可见，不主动扩展到其他指标。未经核图的 OCR 数值标注为候选，无法确认不编造。
4. 保存授权范围内的截图供核对，release 后保留窗口。只读任务不发布、点赞、评论或发送，不访问隐藏 API/凭据。

## 7. 遇到限制时

- 90秒是每代控制期限，不是长期注册窗口的寿命。准备好再连接，正常确认结束后可新连接；不能延长或绕过期限。导航的重试最多两次，退避包含在导航的60秒内；未知输入和不确定结果不回放。
- mouseDown/mouseUp 若使用，须在10秒 held 门限内配对；滚轮目前禁用。
- 不全局输入、不 DOM 合成输入、不用 PID 路由。身份拒绝时检查实际 App 路径、唯一 Manager、授权与 workspace/profile 一致性，以实际错误为准，不修改门禁。
- `RUNNER_EXITED` 不能单独证明进程已退出；generation 身份采样失败也可映射为此错误。保存原始结果，结合实际进程状态与本次连接阶段日志定位，不盲重连。
- TIMEOUT、INDETERMINATE 或其他结果不确定时保存原始输出，不盲重试输入或生命周期动作。release 已发出后不再用 disconnect“兜底”。
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
