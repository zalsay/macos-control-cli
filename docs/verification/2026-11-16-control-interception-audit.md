# sfa control 拦截策略梳理

日期：2026-11-16（America/New_York）。主 Agent 独立审查；本轮只增加本记录，没有修改产品源码、运行浏览器或重做搜索。

## 结论与范围

用户要求的契约是：开启目标环境的 Agent 控制后，sfa 接收并执行命令，页面效果由 agent 使用 observe 判断。当前代码尚未实现这一契约。此前修改只取消了 broker 的持久 uncertain 入场门禁，并将显式 navigate 改为提交回执；页面导航代理、后台 UI 策略、输入资格判断、固定会话期限及它们触发的通道关闭都保留着。

本记录覆盖当前安装的 testing/release + registeredInteractive 路径，以及会影响该路径的 CLI、broker、Manager、Runner、Binder、AppKit/WebKit 桥接和释放逻辑。同一规则的重复 guard 合并为一项。非当前编译分支和仅有枚举目录的策略单独标注，不能算成本次真实触发。

调用链：`control CLI → 本地 socket/daemon → ControlBroker → AppleEvent → AutomationManager → 注册 Runner 通道 → RunnerAutomationService/Controller/SessionMachine → OwnedBrowserAutomationPage → NativePageInput/WebKit`。

## 一、浏览器行为与页面内容裁决

| 编号 | 当前条件/策略 | 当前后果 | 源码入口 |
| --- | --- | --- | --- |
| P01 | 主 frame 导航只允许登记的 explicitURL、initialActionPending 或 redirectPending；页面自发导航还要满足 continuation 条件 | 不符合时 cancel，beginClosing，block；可连带丢掉已经排队的命令回执 | `OwnedBrowserAutomationPage.swift:2432,2477` |
| P02 | 页面自发导航必须处于 `!navigating`、无 navigation/permit、主 frame 归属正确、来源 URL 为 registeredURL，且 current 等于来源或目标 | 加载中的后续导航无法经此入口接纳，落入 P01；本轮 Google 故障关联此路径 | `OwnedBrowserAutomationPage.swift:49,1054` |
| P03 | `targetFrame == nil` 仅特殊放行原生点击中的主 frame、无修饰键、左键、无 body 的 HTTP(S) GET | 合格请求被取消原新窗口决策并在同一 WebView load 一次；其他普通请求取消，等待导航 permit 不合格时还会关闭通道 | `OwnedBrowserAutomationPage.swift:32,409,977,1026,2440` |
| P04 | `.backForward` 一律拒绝；macOS 26 `shouldGoTo` 也一律返回 false | 历史前进/后退取消并关闭通道；CLI 本身也没有 back/forward 操作 | `OwnedBrowserAutomationPage.swift:2435,2555`; `ControlCommand.swift:8` |
| P05 | 控制导航只允许合格 HTTP(S)，拒绝 URL 用户名/密码；子 frame 另允许 about:blank | scheme、URL 不合规则拒绝；部分分支关闭通道 | `OwnedBrowserAutomationPage.swift:38,2466`; `ControlCommand.swift:82` |
| P06 | 导航响应必须可显示，主 frame 不能是 attachment，必须匹配允许 URL/重定向状态 | 取消响应并关闭通道；正常下载也可能被当成控制错误 | `OwnedBrowserAutomationPage.swift:2516` |
| P07 | server redirect 必须有 explicitURL、匹配 navigation correlation；pending continuation 还需额外证明 | 不满足时关闭通道 | `OwnedBrowserAutomationPage.swift:2561` |
| P08 | didStart/Commit/Finish/Fail 需要与内部 navigation、epoch、correlation、acceptedResponseURL 一致；same-document 另验类型、同源、当前 URL | 不匹配时 `registeredCallbackRejected → block → beginClosing` | `OwnedBrowserAutomationPage.swift:359,1846,1857`; `NavigationCorrelation.swift` |
| P09 | `checkedObjects` 把当前 URL 与 registeredURL/允许集合绑定 | URL 变化可返回 TARGET_CHANGED；调用方可能关闭会话 | `OwnedBrowserAutomationPage.swift:635` |
| P10 | 页面 `navigating` 时拒绝新的 perform 输入 | SESSION_BUSY，当前修复允许后续观察/释放，但仍替 agent 决定输入时机 | `OwnedBrowserAutomationPage.swift:730` |
| P11 | `click/Enter --wait-navigation` 要求观测到被接受的导航或通过 same-document 验证，且完成输入 activity 关闭/重建 | 点击已送出后，页面未出现预期导航也可能超时并 block | `OwnedBrowserAutomationPage.swift:835` |
| P12 | 输入前通过 DOM 读取 activeElement，只允许未 disabled/readOnly 的 textarea 或 type=text/search 的 input | contenteditable、password、email、number、跨 frame 焦点等不满足谓词，返回 UI_POLICY_UNAVAILABLE；还要求原生 firstResponder 是目标 WebView 内的 NSTextInputClient | `OwnedBrowserAutomationPage.swift:1180,1188` |
| P13 | 文本拒绝控制字符；registered 普通 press 仅允许不带 Shift 的 Backspace/Delete/Left/Right/Home/End | CLI 能解析的部分按键到执行层仍被拒绝；Enter 等另走等待导航入口 | `OwnedBrowserAutomationPage.swift:1221`; `NativeInputPreflight.swift:26` |
| P14 | `click-target` 自己截图、OCR、调用 JEV 选择目标；模型 confidence≥0.9、概率≥0.95、领先≥0.2、OCR confidence≥0.8 | MODEL_NOT_CONFIGURED、OCR_UNAVAILABLE、TARGET_NOT_FOUND、TARGET_AMBIGUOUS 等；属于目标选择裁决，仅该命令启用，普通坐标点击不走它 | `ControlDaemon.swift:232`; `SemanticSelection.swift:24,36,60`; `ControlDecision.swift:83` |
| P15 | background UI policy 除 proxyBoundAuthentication 外统一 cancelAndSuspend | 取消弹窗/新窗口等并触发 onAutomationUIBlocked，可能最终关闭控制；并非“仅记录事件” | `BackgroundPagePolicy.swift:67`; `BrowserSession.swift:89,105`; `OwnedBrowserAutomationPage.swift:2054` |
| P16 | bound 导航认证 challenge 仅允许 serverTrust 走系统默认处理 | HTTP 认证/客户端证书等 challenge 取消并关闭通道 | `OwnedBrowserAutomationPage.swift:2583` |

P15 的已接线入口包括：新窗口/新标签/重开/切换窗口、targetBlank/windowOpen/windowClose、alert/confirm/prompt、文件/目录选择、保存/打印/下载、摄像头/麦克风请求、外部 scheme、HTTP 认证/客户端证书及系统拖动。另一些菜单动作使用 `.unknown`，同样拒绝。`BrowserWindowController.swift:492,504,743,1550,1577,1612,1620,1665,1740` 与 `BrowserSession.swift:827,858` 可追踪到实际调用。控制接管后 navigationDelegate 被替换，导航/response/authentication 主要走 bound delegate；原 UI delegate 仍提供弹窗等入口，不能把两个 delegate 的检查都算作每次同时执行。

`BackgroundUIRequest` 还枚举地理位置、通知、屏幕捕获、剪贴板读取、全屏/PiP、pointer lock、select/date/color/autocomplete/context menu、long press/link preview、HTML drag、WebAuthn/passkey/Apple Pay、音频等。枚举是策略目录；本次没有逐项证实这些目录项都有实际已安装的系统 hook，不能声称全部已拦截到。

## 二、接管、焦点与窗口状态裁决

| 编号 | 当前条件/策略 | 当前后果 | 源码入口 |
| --- | --- | --- | --- |
| U01 | App 必须后台，窗口不能 key/main；需位于当前屏幕、有效 windowNumber，无 sheet、全局鼠标按键已松开 | connect 返回 INTERACTION_REQUIRED；普通动作期间再次校验可能关闭通道 | `BrowserWindowController.swift:359`; `NativePageInput.swift:264` |
| U02 | 接管要求初始显示已确认、页面加载完成；无起始页、地址栏焦点/编辑冲突，delegate 仍属原对象 | 首次加载可等待，后续不满足则拒绝接管 | `BrowserSession.swift:187,202,268`; `BrowserWindowController.swift:369`; `OwnedBrowserAutomationPage.swift:326` |
| U03 | 同一 profile/窗口只能持有既定 control lease；已有 registeredControl、manualHandoffPending 或 boundCleanupUnconfirmed 则拒绝 | INTERACTION_REQUIRED / SESSION_BUSY 等；清理未确认影响后续接管 | `BrowserSession.swift:281`; `BrowserWindowController.swift:386` |
| U04 | 接管改变窗口为不可 key/main、忽略人工鼠标、禁用 tabbing，绑定 presentation lease；每步要求这些状态仍一致 | 状态改变被当作目标改变，可关闭通道 | `BrowserWindowController.swift:386`; `OwnedBrowserAutomationPage.swift:664`; `NativePageInput.swift:253` |
| U05 | tab monitor 绑定选中页、成员集合与 overview；选择切换、增删标签、概览变化会 invalidate | 同步 revoke，再触发关闭；用户操作同一环境确实会影响 agent | `RegisteredTabMonitor.swift:26,42`; `BrowserSession.swift:195,261` |
| U06 | window.frame、WebView bounds、scale、pageZoom 必须与绑定值一致，命中点必须仍属于页面 | 缩放、移动/尺寸变化或命中改变可 TARGET_CHANGED 并关闭通道 | `OwnedBrowserAutomationPage.swift:664`; `NativePageInput.swift:264,276` |
| U07 | ObjC 后台 activity 只接受精确 WebKit build `21624.5.1.11.3`，已有页面 URL、后台非 key、唯一 activity；并核验 selector/ABI/hook owner | 不合则原生 activity 建立失败；既含人工版本白名单，也含真实调用能力检测 | `SafarierObjCSupport/SFRRuntime.m:742` |

## 三、时限、会话与输入编排限制

| 编号 | 当前条件/策略 | 当前后果 | 源码入口 |
| --- | --- | --- | --- |
| S01 | 注册 generation 固定 90 秒且不能续期；底层 frame 默认 6 秒，受 generation 截止约束 | 超时撤销绑定/关闭通道；不是网页结果失败 | `AutomationProtocol.swift:5`; `FrameDeadline.swift:7`; `AutomationRunnerServer.swift:1372` |
| S02 | idle 60 秒；Manager 在 min(idle,lifetime) 前 5 秒开始自动清理 | 与正在执行或返回的动作竞争；旧多步骤 B 已证实发生过此竞争 | `AutomationManager.swift:258`; `AutomationSessionMachine.swift:165` |
| S03 | Manager 普通动作10秒、registered navigate20秒、等待导航54秒；Runner 状态机导航仍60秒 | 新动作预算不足提前 SESSION_EXPIRED；超时后可能关闭会话；本轮 Google 4.69秒失败不是这项耗尽 | `AutomationManager.swift:239,584,616`; `AutomationSessionMachine.swift:319` |
| S04 | held 鼠标10秒截止；down/up/click 状态必须匹配，held 时导航会 stop | INVALID_POINTER_STATE、停止会话；原生 pending/uncertain 还会要求清理/销毁目标路径 | `AutomationSessionMachine.swift:178,284`; `NativeInputPreflight.swift:7,23`; `NativePageInput.swift:689` |
| S05 | 一次只允许一个普通 action；broker active/awaitingAck、machine flight、release 中间态及各层并发/容量限制 | SESSION_BUSY / REPLAY_WINDOW_FULL；取消/关闭部分预留容量，release 也有自己的空闲要求 | `ControlDaemon.swift:34,137,226`; `AutomationManager.swift:341,707`; `AutomationSessionMachine.swift:261,282` |
| S06 | 所有坐标、输入绑定最近 frame/viewVersion；页面 commit/history 会递增版本，旧 frame 作废；几何必须一致 | INVALID_FRAME / TARGET_CHANGED / OUT_OF_BOUNDS；部分版本竞态已改成可恢复返回，但门禁保留 | `ControlDaemon.swift:108,118,270`; `AutomationSessionMachine.swift:295`; `OwnedBrowserAutomationPage.swift:1404` |
| S07 | blocked 状态只允许 getState/screenshot/cancel/close；held 或有在途动作遇 blocked/geometryChanged 则 stop | SESSION_BLOCKED；通用 block 甚至直接先关闭 Binder 通道，观察/释放未必能留下来 | `AutomationSessionMachine.swift:194,247`; `OwnedBrowserAutomationPage.swift:2054` |
| S08 | 截图最多8次、最长边4096、PNG≤32MiB、存储期限600秒，加目录/文件完整性限制 | observe 可因配额、格式或存储失败；不是页面不可访问 | `AutomationProtocol.swift:10`; `AutomationSnapshotStore.swift:19,252,272` |
| S09 | 相同 requestID 必须同参数，完成后复用回执；在途同ID返回忙；缓存/发送ID上限256 | REQUEST_ID_REUSED / SESSION_BUSY / REPLAY_WINDOW_FULL；属于命令投递管理 | `ControlDaemon.swift:141`; `AutomationReplayCache.swift:48`; `AutomationRunnerClient.swift:292` |
| S10 | release 要无在途 worker、正确 target、无 held/pending permit，先 prepare 再 commit，再交还 owner；各层要求对应布尔项全 true | SESSION_BUSY、SESSION_EXPIRED、INVALID_REPLY、CLEANUP_UNCONFIRMED；失败分支可能开始关闭，不能只依赖页面截图证明已交还 | `AutomationManager.swift:329`; `OwnedBrowserAutomationPage.swift:2095`; `ControlDaemon.swift:324`; `AutomationRunnerClient.swift:570,705` |
| S11 | daemon stop 要 session 表为空、没有等待ACK、没有在途请求 | 即使旧浏览器已退出，broker 残留 session 仍可使 stop 返回 SESSION_BUSY；上轮安装实际遇到 | `ControlDaemon.swift:183` |

## 四、授权、身份、传输和执行事实检查

这些也可能拒绝命令，必须列出，但其语义与“判断网页效果”不同。重构不能把它们的失败全部写成操作成功。

| 编号 | 当前条件/策略 | 当前后果 | 源码入口 |
| --- | --- | --- | --- |
| T01 | 环境 allowsAgentAccess、profile 存在、caller role/UID/token、session ownership 一致；前后多次重读 permission/target | PROFILE_NOT_ALLOWED、UNAUTHORIZED、TARGET_CHANGED；可能关闭现有 session | `AutomationManager.swift:445,463,564`; `RunnerAutomationController.swift:132,162,193` |
| T02 | 本地 socket 私有权限、owner、inode/路径、peer identity；Manager 必须唯一且安装路径/进程身份一致 | UNAVAILABLE、协议错误或连接拒绝；本地传输层校验 | `ControlRuntime.swift:20,138,170,239`; `ControlAppleEventClient.swift:69,98` |
| T03 | macOS AppleEvents/TCC 权限查询及发送结果；查询有界等待 | 无权限或系统 API 挂起返回 unavailable/timeout；是 OS 执行条件 | `ControlAuthorization.swift`; `SafarierControlSupport/ControlSupport.c:160,178,219` |
| T04 | Binder 多检查点重复核验 bundle 清单/签名、进程 birth/code/audit token、socket、profile repo/依赖与锁 | 任一失败可 beginClosing 并撤销 generation/root；祖先目录误报曾出现在这里，本轮 Google 所取日志未出现 BB_CHANGED | `AutomationRunnerServer.swift:1379`; `RepositoryBindingProvider.swift:101,121`; `BundleInventory.c:211`; `BinderIdentity.c` |
| T05 | 发前、发后、收前、收后、回复入队和真正写出前后都有 Binder/deadline/revocation 检查 | 业务 sink 已返回成功也不保证回执能离开 Runner；后续页面 block 可撤销正在发送的回执 | `AutomationRunnerServer.swift:266,395,455,498`; `AutomationRunnerClient.swift:550` |
| T06 | RunnerClient 已尝试请求在超时/通道断开后统一走 failConnection；Manager 对 runnerExited/indeterminate 启动关闭 | 将局部异常扩大成整条 session 终止；后续 observe/release 无法继续 | `AutomationRunnerClient.swift:655,660`; `AutomationManager.swift:676` |
| T07 | CLI/JSON 编码要求固定schema、UUID、操作枚举、参数类型、有限数值、长度、正确reply类型/requestID | INVALID_REQUEST / INVALID_REPLY 等；其中 back/forward/scroll 未暴露为当前 control 操作，属于能力缺口 | `ControlCommand.swift:8,30`; `ControlProtocol.swift:69`; `AutomationProtocol.swift` |
| T08 | native recipient、实际WebView/window存在、方法ABI、原生投递异常、进程/通道是否真实存在 | 可执行性失败应如实报告；当前代码经常将其和页面策略失败一起触发关闭 | `NativePageInput.swift:230,309,533`; `SafarierObjCSupport/SFRRuntime.m:537` |

## 五、已经放开的部分及非当前分支

- `ControlBroker.Session.uncertain` 仍在记录 ACK 丢失、错误回执等历史事实，但当前入场 guard 只判断 active/awaitingAck，不再因 uncertain 拒绝新请求。删掉这个字段并不会移除下层拦截。
- registered 显式 navigate 在 WebView 接受 load 后返回 `navigationSubmitted`、`effectVerified:false`，不等待 didFinish。但其后 callback、URL、Binder、回执写出检查仍与同一通道耦合。Google 失败正好证明这一改动尚不充分。
- loading 拒绝已可恢复为 SESSION_BUSY；commit/history 的版本变化已有局部兼容；这些都是原策略内补分支，尚未取消裁决架构。
- `NativeInputPreflight.shippingAdmissionAvailable == false` 是普通 shipping 分支门禁；本次 testing candidate 有独立 admission 路径，不是本次连接失败的原因。
- `BoundFixtureFormPolicy` 的固定坐标/固定字符串白名单和 fixture DOM 结果比对在非 INTERNAL_TEST_APP 分支，本次 installed testing/registered 操作不走它。不能拿这组死于当前配置的规则解释本次 Google 故障。
- `scroll` 在 bound service/action 层不放行，NativePageInput 非 observer 构建也拒绝；当前 control CLI 也没有 scroll 操作。这是实际能力限制，不是 Google 回执故障的触发点。
- `BackgroundSafetyControl` 的完整目录与 proof gate 不等于本次已安装完整 hooks。需要区分目录、编译分支、实际接线和运行时证据。

## 六、反复失败的结构原因

现有 registered 浏览器复用了带强约束的 fixture/background 控制架构。页面自身的加载、重定向、history、弹窗、焦点等状态参与“通道是否仍有效”的裁决。核心路径是：

`页面事件不匹配预期 → policy cancel / block → Binder.beginClosing → generation/root 关闭 → 已发送请求回执失去确认 → INDETERMINATE_RESULT → Manager.startClose → observe/release 过期 → reconnect BACKEND_UNAVAILABLE`。

最新 Test 证据：NY 07:22:59.681769 sink success；59.832796 handler success；07:23:00.159689 reply queued；随后 mainExplicitURL 拒绝与通道关闭；00.939651 Manager endpoint 返回 INDETERMINATE_RESULT。证据在 `google-multistep-after-fixes-20261116/main-search-unified.ndjson` 和 `runner-through-search.log`。这些证明提交回执被通道故障截断，未证明页面业务结果成功。

之前按 URL/回调类型逐条补允许分支，仍保留“行为不符合预期就关闭执行通道”这一结构，所以不断遇到下一种页面行为。前一轮增加的预算门禁也是新拦截，不符合把生命周期交给执行会话管理的简化目标。

## 七、按用户要求调整的执行契约

以下是后续实现范围，尚未修改：

1. 移除 sfa 自设的页面行为裁决：导航/跳转/历史/新窗口白名单、DOM 输入资格、后台 UI blanket deny。复用浏览器现有正常导航、表单和 UI 功能；agent 决定操作对象和操作顺序。2026-11-17 对照 MCC 后补充：click-target 是可选的语义选点，不是操作后结果确认；普通坐标执行不得依赖它，其独立功能不能与核心拦截混为一谈。详见 [MCC 执行语义对齐](2026-11-17-mcc-execution-alignment.md)。
2. 移除由页面结果触发的通道撤销：页面 load/commit/finish/fail、URL 或文档变化只更新 observe/state；不得撤回已经接受的动作回执，也不得让观察和释放随页面策略一起失效。
3. 清理固定时限与前后台/几何/标签状态的额外自动封锁。命令超时只返回该命令的投递事实和已知原因；正常页面变化、人工切换和会话空闲不应自动认定动作失败。实现时同时处理底层 activity 的实际能力，不能只删上层 guard 而留下 C/ObjC 同样拒绝。
4. 统一回执：只描述未送达、已提交或投递状态未知，以及实际 OS/IPC 错误；不宣称网页效果成功，不根据页面行为判失败，不自动重放。observe 返回可取得的页面状态、截图和错误事实，由 agent 判断下一步。
5. 环境 Agent 开关作为授权入口；命令仍需能被解析、目标仍需存在、实际系统调用错误如实返回。协议关联和同 requestID 不重复投递属于执行事实管理。重复验包和身份核验应与页面事件解绑，并明确哪些只需连接时执行，避免继续把它们混称为网页“结果确认”。
6. 释放走独立的输入停止/资源交还路径，不要求网页达到预期 URL、导航完成或 DOM 状态正确；各项交还结果如实报告。测试需覆盖页面报错、重定向、用户切页之后仍能 observe/release。

这需要沿现有功能统一收缩策略，不能继续针对 Google 加一个例外或只删除 INDETERMINATE_RESULT 字符串。此次没有新增替代执行框架，也没有把上述实现范围标成已完成。
