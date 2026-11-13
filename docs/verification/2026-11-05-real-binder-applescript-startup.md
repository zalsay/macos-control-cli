# 真实 Binder / AppleScript 启动验证记录

日期：2026-11-05（Asia/Shanghai）  
范围：独立新候选、本地 fixture；不是发布或完整后台自动化验收。

## 最新结论：固定 fixture 的真实 close proof 小闭环已完成

raw-cutoff 候选两次新 session 的原 smoke 均 exit 0／`smoke_complete`；Runner 真实 page／store 清理 proof 在 863／900 ms 被 Manager 接受，最终 receipt 均为 `cleaned=true`、`terminatedOwnedRunner=true`。pointer sequence 1–5、buttons 0／0／1／1／0；原权限、身份、2 秒 deadline 和 cleaned 门禁未放宽。此前 close 失败仍是历史事实，不可追溯改写。此结果仅覆盖本地 candidate 固定 fixture，不等于任意 URL、键盘、人工并发长期不干扰、完整 G1／G5 或发布验收。

完整 proof／数值 RED-GREEN／运行与失败证据：`/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-close-session-proof.md`。

## 历史：当时两次真实 hover ACK 与绿色截图；close 尚未通过

修复候选在两个独占 session 中均取得真实 mouse completion（59／1 ms）、绿色 hover 截图和 sequence 1–5、buttons 0／0／1／1／0 的回执；presentation callback 分别为 64／8 ms，未作为 mouse ACK。两次均在 closeSession 的 `receipt.cleaned` 门禁停止、整体 exit 1；Manager 退出 status 15 已观察，Runner 独立退出未知。`startClose` 固定返回 `cleaned:false` 并不能证明 native 页面／store cleanup，下一阶段应单独解决真实证明传递，不得改成 true 或放宽 host。完整 GUI、G1／G5、shipping 及人工并发键鼠长期不干扰均未验收。

详细 RED、无效试验撤回、修复边界及两次运行证据：`/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-hover-native-ack.md`。

## 历史：静态角色候选跨过唯一路由；当时首 hover 结果不确定

同一外层 App 内静态 Runner 的一次实际 GUI 中，Main 与 Runner 的固定独立 identifier、19／8 精确 namespace 和双端签名经主 Agent 核验。Manager 的真实 owned 快照记录 `matchingCount=1`、`managerRegistered=true`、`originalOwnedRunnerRegistered=false`、`sameEndpointOwnership=true`、`realCoreRoundtripValidated=true`、`otherRegistrationsCount=0`；同一真实控制链的 capabilities、openSession、getState 均成功。原同 BID 唯一路由阻塞在本次运行被跨过；这不构成额外的长期身份授权。

首个 hover move 返回 `INDETERMINATE_RESULT`，副作用可能存在也可能不存在；根因尚未知，不能从该标签断言 native ack 超时、3／5 秒截止、codec／frame 验证或进程崩溃。之后未执行截图、drag 或 closeSession，无 `hover.png`；host／外层 smoke 退出 1。Manager 的原 retained Process 退出 status 15 已观察，Runner 独立退出／清理观察 unknown。不可重发该 hover 或复用旧 session；完整 GUI／shipping／G1／G5 和不干扰用户键鼠均未证明。

## 历史：已取得 owned 注册项佐证，唯一 Manager 路由当时未解决

在一次专门的 Manager 注册快照及随后同一 concrete client 的真实 Core 只读往返中，第二个同 BID 注册项匹配原 owned Runner；`sameEndpointOwnership=true`、`realCoreRoundtripValidated=true`、`otherRegistrationsCount=0`。这是该次快照与往返的证据，不能把较早或后续 Host 快照视为原子持续证明。

尝试在 Runner 中断开并拒绝后续 LaunchServices 连接时，SPI 调用返回 0，但随后的有界观察中 90 次快照均为 2，耗时 2001 ms，原 owned Runner 与 Core 往返仍被观察到；该隔离试验未达到唯一 Manager 接收端条件。临时试验源码已精确撤回，所有 trial App、root 和日志保留。外部 host 原 `count == 1` 门禁、Core 身份及原输入路径保持严格；尚无 getState、鼠标动作或截图验收，完整 G1/G5 与不干扰用户键鼠均未证明。

更早一次加载顺序修正后的运行虽在 openSession 成功后无第三回执，但当时宿主只记录 `smoke_failed`；不能倒推它一定因相同路由条件停止。之前 native open 的 `BACKEND_UNAVAILABLE` 与 Manager 映射、以及随后一次 `INDETERMINATE_RESULT` 均按各自证据保留在下文。

## 历史：首次授权候选 GUI 运行

`runtime-002` 的脱敏状态依次为：一次 `consent_request_start`、literal AppleScript `capabilities` 成功、`openSession` 返回 `RUNNER_EXITED`、`smoke_failed`，随后记录 `owned_manager_exited`。host 和外层运行退出码均为 1。授权请求开始的日志不等于独立观察到了系统授权框或人工点击；这两项本轮均未独立观察。

`openSession` 未成功，未执行 `getState`、hover、截图、mouseDown、按住移动、mouseUp 或 closeSession，也未产生 hover PNG。Manager 的原有 retained Process 记录已退出，termination status 为 15；这不单独证明本轮 Runner 的退出或清理已经被观察到。

Runner 日志中的一条 self 和八条 peer 验证成功记录，只说明对应检查曾到达并成功，不能据此认定完整身份、准备、原生输入或其他全部门禁已通过。现有日志未给出 Runner 失败的具体阶段；`RUNNER_EXITED` 可能是启动链上多种错误经 Manager 汇总后的结果，不能单凭它断定 Runner 真实退出状态。

**首次运行时根因未知。** 当时认为 hello/ready 后首次 WebKit 初始化可能消耗现有 3 秒准备期限只是待测假设，并未证明；后续诊断候选结果见下，不授权扩大期限或跳过校验。

## 历史：诊断源码与候选构建

主 Agent 对本轮 5 文件诊断 diff 的记录及其 before/after 证据位于下述路径。诊断目的仅为在现有调用路径记录固定 phase、单调 elapsed_ms、脱敏结果，以及原 retained Runner 退出观察结果；不是修复、授权绕过或行为门禁变更的证明：

- `Sources/Safarier/RunnerPreparation.swift`
- `Sources/Safarier/RunnerMain.swift`
- `Sources/SafarierWebKit/WebViewConfigurationFactory.swift`
- `Sources/SafarierCore/AutomationRunnerServer.swift`
- `Sources/SafarierCore/AutomationRunnerClient.swift`

随后仅执行一次 normal candidate 构建与打包，退出码 0；源码 before/after 清单一致，包签名 strict verify 退出码 0。该产物在构建当时尚未启动，随后用于下述独立诊断 GUI；它没有替换首次运行的候选 App。

新包的五项 SHA-256：

| 包内文件 | SHA-256 |
| --- | --- |
| `Contents/Info.plist` | `296d9e042cc3a889de6e48f2fdd28eca79de3c74f15e106b39f1f63cd55f1c63` |
| `Contents/MacOS/Safarier` | `a6f86f420521510ec62672ef9011c83b9a6c73ad11f48181b566a653c7e06343` |
| `Contents/Resources/Safarier.sdef` | `0cb1c89e68376982342c0a4821b8f9a719d99e4ceb5b476e5ec748e773b5890c` |
| `Contents/Resources/control-fixture.html` | `45f599bd8d943192d3f93045559a825b8922f5b2df8106393fc896394355edc1` |
| `Contents/_CodeSignature/CodeResources` | `9dae8976d22066948293a51ef324b7e6294054a36e4b71161685b6ef867b3b02` |

## 首次运行及诊断构建证据路径

- 主 Agent 的实际运行记录：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/main-runtime-002-review.json`
- 外层运行记录：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runtime-002/`
- host 脱敏结果：`/Users/yingzhang/.safarier-bound-control-20261105-2355558ee31d44f392404b60900dd1d9/consent-smoke-001/results/stdout.jsonl`
- Manager stderr：`/Users/yingzhang/.safarier-bound-control-20261105-2355558ee31d44f392404b60900dd1d9/consent-smoke-001/results/manager.stderr`
- Runner 日志：`/Users/yingzhang/.safarier-bound-control-20261105-2355558ee31d44f392404b60900dd1d9/consent-smoke-001/workspace/logs/1B4D57B1-6B9F-49A1-8F1C-6504D7C22FDA.log`
- 本轮诊断源码 before/after 与逐文件 diff：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-exit-diagnostics-001/`
- 主 Agent 源码复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-exit-diagnostics-001/main-source-review.json`
- 新构建包与源码、命令、签名收据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/worker-tools/attempt-20261105-084747-bb7f870195e1401e9343aa3f4aa648f9/`
- 新构建外层记录：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-exit-diagnostics-001/build-launch-001/`

上述首次运行证据属于首次候选包；后续诊断候选的实际运行另见下节。构建成功本身不能推断运行结果。

## 后续第一轮 GUI：诊断候选的 WebKit 初始化崩溃

诊断候选的一次 GUI 运行中，`capabilities` 成功，`openSession` 返回 `RUNNER_EXITED`；Manager 记录 retained Runner 已观察退出、status 5，Manager 自身退出 status 15。Runner 最后阶段为 `factory.configuration.before`。匹配该候选二进制 UUID **`80628900-b309-365e-99c3-73c829678143`** 的 macOS 报告记录 `EXC_BREAKPOINT`／`SIGTRAP`，faulting thread 4 位于 `com.apple.main-thread` 队列，堆栈经过 WebKit 初始化、`WKWebViewConfiguration` 和 `makeBoundLocal`；主线程 0 的栈处于 `dispatch_main`／`pthread_exit` 路径。系统隐去了报告中的 procPath；UUID 与 code-signing ID 匹配仅用于诊断相关性，不能作为控制身份授权依据。

这一后续证据定位到 WebKit 初始化崩溃；并未观察到初始化消耗 3 秒。完整系统 crash 内容不在本记录复制。主 Agent 的诊断复核：

`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-exit-diagnostics-001/gui-001/main-runtime-review.json`

## 纯 Foundation 异步对照与主线程修正

首次无 await 对照（`runner-mainthread-fix-001`）的 dispatch 入口为 `Thread.isMainThread=true`，但它只观察同步首次进入，未覆盖真实异步挂起路径，**不作为通过或实际崩溃负例**。随后一次必要的两模式异步对照（`runner-mainthread-fix-002`）在挂起后得到：

| 模式 | 入口 | await 后 | 退出码 |
| --- | --- | --- | --- |
| `dispatchMain` | true | false | 1（RED） |
| `CFRunLoopRun` | true | true | 0（GREEN） |

沿原后台入口，将 `dispatchMain` 替换为 `CFRunLoopRun`，未提前创建 `NSApplication`；candidate factory 在 WebKit 配置创建前使用 `pthread_main_np()` 检查物理主线程，若为 false 则 fail closed。此对照支持该入口修正，但不能替代实际 App 行为验证。

修正后一次 normal candidate build／package／strict verify 均成功，构建前后 96 项源码清单一致。构建与复验对象经主 Agent 复核：

- 无 await 对照：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-mainthread-fix-001/`
- 异步对照、源码 before/after 和 diff：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-mainthread-fix-002/`
- 主 Agent 源码与产物复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-mainthread-fix-002/main-source-artifact-review.json`
- 修正后构建 receipts：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/worker-tools/attempt-20261105-085932-5ff8e4e4d5bb497a831bf08ac57dcada/`

## 后续第二轮 GUI：修正候选定点验证

修正候选的一次 GUI 运行没有请求新的 consent：`capabilities` 成功，`openSession` 返回 `INVALID_REQUEST`，host 和外层 smoke 均退出 1。Runner 记录 `factory.configuration.is_main_thread=true`，随后 `configuration.after`、`nonpersistent.after`、prepare callback 和 service create 均完成；这证明本次跨过了旧的配置初始化崩溃点，而不是证明完整会话或页面输入成功。

Manager 的 retained Process 退出已观察、termination status 15；Runner 日志记录 `serve.app_bound.after` 返回状态为 0，但本轮没有独立的 retained Runner 退出观察记录，不能从日志推断 Runner 清理成功。没有 hover PNG，也未执行 pointer 动作。完整 G1/G5 和不干扰用户键鼠均未证明。

- 本轮外层运行：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-mainthread-fix-002/gui-001/runtime-001/`
- host 脱敏结果：`/Users/yingzhang/safarier-bound-control-20261105-55c81f981c494a89866c1dacd1913ddf/fixed-smoke-001/results/stdout.jsonl`
- Manager stderr：`/Users/yingzhang/safarier-bound-control-20261105-55c81f981c494a89866c1dacd1913ddf/fixed-smoke-001/results/manager.stderr`
- Runner 日志：`/Users/yingzhang/safarier-bound-control-20261105-55c81f981c494a89866c1dacd1913ddf/fixed-smoke-001/workspace/logs/A3A38369-D932-4AAE-8C5E-4CBAB0B5B4BD.log`

## 历史：定位 INVALID_REQUEST 的原 guard

沿实际 Manager → client → Runner 会话与 codec 路径定位。`Sources/Safarier/Automation/AutomationManager.swift` 的 open 路径约第 417–424 行有合并 guard：检查 reply codec roundtrip、结果必须为 `sessionOpened`、token canonical、profile 与 runnerInstanceID 匹配、endpoint pid 为正、viewport 有效且 `sessions[token]` 尚未占用；任一不符，包括 Runner 回复 failure outcome，都会 close 并映射为 `INVALID_REQUEST`。因此外层状态本身不能区分请求格式、Runner 业务拒绝或 Manager 的结果校验。

## 后续诊断：Runner failure 与原 native activity 前提

一次增加脱敏阶段日志的诊断 GUI 中，Manager 记录 `kind=failure code=BACKEND_UNAVAILABLE`，原 guard 将其映射为外层 `INVALID_REQUEST`。Runner 日志依次记录 `page_factory.before`、`native_open.before`、`page_factory.failure code=BACKEND_UNAVAILABLE`，没有 `native_open.after`；可见失败发生在原 `NativePageInput.open` 开始后、返回前，而非由外层结果本身证明请求编码错误。

主 Agent 沿原实现确认：`SFRBeginBackgroundPageActivity` 保留既有 WebKit 版本检查，并要求 webView 已有 URL；原 candidate `attachBound` 则先开启 activity、后加载 fixture，新建 webView 当时尚未加载 URL。原 probe 先加载固定 fixture 并等待 ready，后创建 native events。该顺序差异是针对性修复的依据；日志本身并未单独暴露 SFR 内部哪一项检查的返回细节。

后续修正沿同一个私有 page、原 navigation delegate、binder context 与原 `NativePageInput.open`：先完成固定 fixture 的加载、相关性和确切 URL 校验，再开启并等待 native activity，ready 后才返回 page。SFR C／headers 及原有版本、身份、输入和 cleanup 门禁未移除；未引入替代输入执行器。原调用顺序的真实失败是本次 RED，不能以伪造 activity lease 或 binder 代替实际验证。

本次诊断运行与修正候选运行分别经主 Agent 记录：

- 原 native open 失败复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/open-session-diagnostic-001/gui-001/main-runtime-review.json`
- 加载顺序修正后复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/bound-page-load-order-fix-001/gui-001/main-runtime-review.json`

## 后续验证：真实 openSession 成功，但 getState 未获回执

加载顺序修正后的候选完成一次 GUI 定点运行；没有请求新的 consent。Runner 记录 `fixture_load.before` 在 `native_open.before` 前，随后 `urlPresent=true activityStatus=0 hasLease=true`、`native_open.after`、page/store factory 完成及 `finish_opening.success`。同一 smoke host 获得 `capabilities` 与 `openSession` 成功回执；openSession viewport 为 1280 × 772 points、version 1。

随后仅有 `smoke_failed`，没有第三个请求回执。不能确定 getState 是未发送、被前置条件阻止、解析失败还是其他原因；没有观察到 hover、截图、mouseDown、held move、mouseUp 或 closeSession。Manager 的原 retained Process 退出已观察，status 15；本轮没有独立 retained Runner 退出观察记录，不能由 service 返回推断其清理完成。完整 smoke 退出 1，不等于完整 G1/G5 或键鼠不受干扰的验收。

- host 脱敏状态：`/Users/yingzhang/safarier-bound-control-20261105-c61f80b8410040218a21ca3f0ebb5229/fixed-open-smoke-001/results/stdout.jsonl`
- Runner 日志：`/Users/yingzhang/safarier-bound-control-20261105-c61f80b8410040218a21ca3f0ebb5229/fixed-open-smoke-001/workspace/logs/60360B35-DA00-4553-B6A2-6853B4555DE5.log`

## 历史：helper 停止原因诊断准备

经主 Agent 审阅，Terra worker 仅离线编译了 helper 诊断，用于在下一次定位固定 smoke phase、严格 owner／同 BID 路由失败原因及 reply decode／ID 布尔；既有唯一 Manager 路由条件未删除，发送 mode、调用方和清理规则未放宽。该 helper 在本段所述准备时尚未运行；此后已用于下文两次不同候选验证：先是外部 `INDETERMINATE_RESULT` 的候选，后是恢复 controller 预算的候选。它不再处于待首次运行状态：

- 路径：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/worker-tools/host-fd219074b3bc474ab55d45beed0d9aca/smoke-host`
- SHA-256：`a74b22216d18c9327628a4fa7ef7c9572fb44dcbab7e773323bec792b960a00e`
- 受审源码 diff：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/host-stop-diagnostic-001/change.diff`

## 后续新 helper 运行：外部 INDETERMINATE，原因未由单码证明

新 helper 的一次运行中，Runner 内部日志记录 native activity 成功及 `finish_opening.success`，外部 openSession 则返回 `INDETERMINATE_RESULT`，总 smoke 退出 1；该次没有 route／decode 失败诊断。不能将这个单一返回码当成路由或解析错误的证据，也不能将 Runner 内部开成等同于外部 session 成功。主 Agent 的本轮复核：

`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/host-stop-diagnostic-001/gui-001/main-runtime-review.json`

## Controller 截止时间源码对照与纯时钟回归

主 Agent 对照已批准的 `automation-binder-controller-adversarial-20261104/worker/attempt-016/src/FrameDeadline.swift` 发现，移植后的 controller initializer 额外加入了 3 秒上限；这与原实现及 `docs/verification/2026-11-04-binder-controller-repository-offline-implementation.md` 第 4 点规定的 caller 绝对预算及 45 秒寿命上限不一致。恢复后整份 `FrameDeadline.swift` 与 attempt-016 baseline **逐字节一致**，SHA-256 为：

```text
68e76b4050fa382097c759ce3c14a72b331a9c5fa87eac64ad11da90a299678e
```

未修改 Client 原有回包检查、原默认参数、Runner 3 秒 frame、45 秒寿命或 caller 绝对 deadline。使用编辑前后实际源码前缀的纯时钟 RED／GREEN 回归中，RED 仅 controller +10 秒预算断言失败，其余 Runner 3 秒、已过 caller cutoff 拒绝和 45 秒寿命边界均通过；GREEN 四项全部通过。该回归不创建 Binder／lease／context，**不是 Binder 身份或完整 GUI 测试**；源码偏差也不能单凭前一轮 `INDETERMINATE_RESULT` 证明为该次失败的唯一原因。

- Terra worker 的源码前后、实际截取 harness 与命令 receipts：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/controller-deadline-restore-001/`
- 主 Agent 的源码／时钟复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/controller-deadline-restore-001/main-source-review.json`

## 历史：恢复预算候选的单次 GUI

恢复预算后的候选一次运行中，外部 `capabilities` 与 `openSession` 成功。四条入站诊断均显示 outbound cutoff 和 pending deadline 未过期，pending 分别余约 28.031 秒和 27.964 秒；这是本次快照，不是所有时序的证明。getState 在 `before_permission` 被严格同 BID 唯一注册检查阻止：匹配数 2，原 Manager 存在，唯一匹配条件为 false；第二项的 actual owned 身份没有从该轮日志建立；后续独立 owned 证明见下，不能追溯视作该轮快照的原子证明。

本次未发送 getState，也没有 hover、drag、截图或 closeSession；host／外层退出 1，没有新 consent 或全局输入 fallback。原 retained Manager 退出已观察、status 15；Runner 没有独立 retained exit 观察记录，不能由 service 返回推断清理成功。

主 Agent 对本次状态、四条入站诊断和 Runner 日志的复核：

`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/controller-deadline-restore-001/gui-001/main-runtime-review.json`

## 后续 owned 证据与注册隔离试验

经主 Agent 审阅，Terra worker 执行的一次 owned 观察记录 `matchingCount=2`、`managerRegistered=true`、`originalOwnedRunnerRegistered=true`、`sameEndpointOwnership=true`、`realCoreRoundtripValidated=true`、`otherRegistrationsCount=0`。这是 Manager 原注册快照与同一 concrete client 原 channel／Core owned、birth、peer、repository 往返结合的证据，并非将 PID 或 role label 当作路由授权。后续 Host 自己的快照仍为 2，但该 Host 快照没有独立输出第二项身份，不能与前一快照当作原子持续证明。

随后仅试验原 Runner 已初始化页面后的本进程 LaunchServices 连接隔离；调用返回状态 0，首次快照仍记录原 owned Runner 已登记。最后一次有界 readiness 观察在 2001 ms 内取得 90 个 `matchingCount=2` 快照，最终 `originalOwnedRunnerRegistered=true`、`sameEndpointOwnership=true`、`realCoreRoundtripValidated=true`、`otherRegistrationsCount=0`。因此本轮实际没有满足唯一 Manager 条件，**SPI 返回 0 不是注册消失或授权成功证明**；本 SPI 路线停止，不再调整 flags、daemon 或 WindowServer 机制。

最后一轮外部 `openSession` 返回 `RUNNER_EXITED`，只表明该次请求的结果，不能由此断定 Runner 实际退出；未发送 getState，也未执行 hover、drag、截图或 closeSession。原 retained Manager 退出已观察、status 15；本轮没有独立 retained Runner 退出观察，清理结果仍为 unknown。

- owned 证明的主 Agent 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/owned-registration-proof-001/gui-001/main-runtime-review.json`
- 首轮隔离试验主 Agent 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/runner-registration-isolation-001/gui-001/main-runtime-review.json`
- 2 秒观察主 Agent 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/registration-settle-observation-001/gui-001/main-runtime-review.json`

## 无效试验源码撤回与证据边界

经主 Agent 复核并指示，Terra worker 仅撤回临时 2 秒观察、Runner 私有 LaunchServices 适配及其调用／声明，保留真实 owned 观察与原 fixture／native／Core 校验；唯一试验新增的 `.m` 文件在归档和校验后移除。回退后现有 build 输入 **96／96 项 SHA** 与曾构建并实际进行 owned 证明的 `attempt-20261105-100425-c1eec0d3106c4b029fa2ba745d12d6c6/source-after.json` 一致。本次回退后未再次构建或运行 GUI；该对比不替代新的运行验收。

全部旧／新 candidate App、root、日志与试验证据保留。源码撤回的 before、after、diff、移除标记及逐项比较：

`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/consent-20261105/registration-experiment-revert-001/`

## 历史：当时待批准的架构方向（后续已批准实施，见最新结论）

以下保留撤回试验时的原始历史表述；用户其后已批准该方向，静态角色候选的实施及实测结果见本记录最新结论与后续小节。

可供主 Agent 与用户讨论的方向仍是一个 `Safarier.app`，沿用现有 Runner 进程、输入器和 socket 通道，仅将原 Runner 静态打包为 App 内独立签名 bundle，并固定独立 BID，使 Manager 成为其控制 BID 的唯一接收端。此方向需要改变包结构及角色预期 pin 对象，两端必须各自精确固定 code／resource pin，原 owned、birth、peer 校验不得减弱；不能仅信 TeamID、BID 或 role。

这只是待用户批准的架构方向，尚未实施，也不保证成功。本记录不授权创建 bundle、改变身份校验或启动运行；仍不得删除 `count == 1`、按注册顺序挑选、增加 PID 路由 fallback，或使用全局输入。需 consent 时停止并另行裁定。

## 静态角色构建与真实 C 定向负例

经主 Agent 审阅并冻结源码，Terra worker 执行一次 normal candidate build／package／两端 strict verify 与一次 host 离线编译，构建源码前后分别为 97／97 和 8／8 项一致；Main 19／Runner 8 namespace、两端独立签名、九项 artifact SHA 及 sender 经主 Agent 独立核验。主 Agent 审阅的实际 C 定向负例四项按预期拒绝：Main 错 BID、Runner 错 leaf、父 pin 后的 Runner fixture 修改、父 namespace 中额外文件。helper Info 篡改和重签未覆盖，因此不是完整负例矩阵。

- 主 Agent 的静态产物复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/static-role-20261105/main-artifact-review-001/result.json`
- 实际 C 负例结果：`/Users/yingzhang/safarier-static-role-negative-20261105-52455065c29140b399c9a8953d4d53ba/summary.json`
- 本次 GUI 外层 receipts：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/static-role-20261105/worker-tools/gui-001/runtime-001/`
- Host 脱敏状态：`/Users/yingzhang/safarier-bound-control-staticrole-20261105-963c66d9453f4f2293a00b609bdb951c/static-role-smoke-001/results/stdout.jsonl`
- Manager stderr：`/Users/yingzhang/safarier-bound-control-staticrole-20261105-963c66d9453f4f2293a00b609bdb951c/static-role-smoke-001/results/manager.stderr`
- Runner 日志目录：`/Users/yingzhang/safarier-bound-control-staticrole-20261105-963c66d9453f4f2293a00b609bdb951c/static-role-smoke-001/workspace/logs/`

历史：在后续 native 诊断前，本轮只读源码定位：`NativePageInput.perform` 的 move 经原 scoped mouse delivery，随后 `drain` 等待原有最多 3 秒的 pending-mouse 回调；Runner action sink、Client 已 attempted 的非只读 Pending、Manager 请求超时／异常及 script coordinator 的特定失败分支均可能将不同结果映射为 `INDETERMINATE_RESULT`。日志没有记录 hover 到达 native／回调／响应各节点或首个 channel 关闭原因；Runner 的 9892 ms 是 serve 全程，不是 hover 耗时。因此 native ack 超时、原 3／5 秒边界、codec／frame 拒绝或崩溃均未证实。

历史准备：此后已授权并实施诊断，结果见最新结论；当时建议如经主 Agent 单独授权，可只在原 NativePageInput、RunnerAutomationController、AutomationRunnerServer、AutomationRunnerClient 和 AutomationManager 的对应边界添加固定 phase／脱敏 code，区分实际 dispatch、ack、server 帧及 client／manager 首个失败；不修改 SFR C、身份、门禁、路径或期限。本轮不重发旧 hover、不复用旧 session，也不使用全局输入兜底；本记录不授权新 GUI。
