# 2026-10-29 原页面 UI 边界与异步会话控制器

## 结论与范围

- 仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。Terra worker 实现，主代理执行全部代码/设计 review 和最终独立验证；实际 worker turn_context 均为 `gpt-6.1-terra` / `high`。
- 第五批完成**原拥有者的候选拒绝接线**及**实际消费状态机效果的异步控制器**。不是完整后台浏览器，不是已通过 G1/G2，也不是已经可以用 AppleScript 操作网页。
- 没有运行真实 Safarier App、NSApplication、WKWebView、窗口或 Apple Events；没有接触真实 Profile、授权提示、全局鼠标键盘、光标/输入法或系统配置。执行的程序仅为无 GUI 验证 CLI 和自有 Foundation 进程 fixture。
- 原配置工厂仍无条件拒绝 automationBackground；shipping 脚本开关、Manager 生命周期、Runner unavailable 分支及原输入桥均未修改。新控制器没有在 shipping 服务中实例化，没有默认 native 执行器或进程终止实现。

## 1. 复用原路径的 UI 拒绝接线

### 模式来自工厂，不接收第二个强制开关

`/Volumes/RC500/dev/safarier/Sources/SafarierWebKit/WebViewConfigurationFactory.swift` 的 Output 新增只读 executionPolicy，内部初始化器默认 interactive，make 显式传递其参数。后台硬拒绝仍发生在 WK 配置/DataStore/凭据/adapter 之前，不能用合成 capability、环境变量或 App 层覆写绕过。

`/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserSession.swift` 从 Output 取得只读模式，没有新增任意 mode override 参数。routeUI/allowUI 复用同一个 Core policy；onAutomationUIBlocked 仅传固定请求类别，不回显页面消息、URL 或输入。

`/Volumes/RC500/dev/safarier/Sources/SafarierCore/BackgroundPagePolicy.swift` 只在原 decide 上增加通用 route：恰好执行 perform 或 deny，后台先通知 blocked 再执行否定完成回调。没有新增平行 policy 类或另一套浏览器。

### 已加的候选源码边界

主要拥有者仍是 `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserWindowController.swift`：

| 原入口 | 后台候选分支 |
|---|---|
| target=_blank / window.open | 创建新视图、改标志、开标签/窗口前返回 nil |
| alert / confirm / prompt | 不建 NSAlert；完成回调分别 void / false / nil |
| 文件/目录选择 | 不建 NSOpenPanel，完成回调 nil |
| 媒体许可 | 不建询问 sheet，decision deny；未知类型同样拒绝 |
| 导航下载 / 不支持 MIME / 附件 | policy cancel，不转入原下载路径 |
| WKDownload didBecome | 取消，不交给原 DownloadsController，不保存 resume data |
| HTTP 页面/客户端证书等 challenge | 不建认证 sheet，不把 isProxy/proposedCredential 当授权；后台保守取消 |
| 外部/未知 URL scheme | 分类后拒绝；HTTP(S)/about/data/blob 只被分类为 WebKit 内部 scheme，不代表 G2 已验证 |
| 保存、导出 PDF、打印、错误/下载弹层 | 在面板/打印操作/弹层创建前拒绝 |
| 新建/重复/切换/恢复/关闭窗口标签、源代码窗口 | Void/可选返回入口拒绝，关闭前不遍历 tab group；窗口关闭/WebContent 丢失通知目标失效，后台不自动 reload |
| 分享工具栏 | 后台构造时静默省略，不制造“页面请求交互”；真正 items 请求仍拒绝 |
| 应用层剪贴板写入、地址栏/查找/概览动作 | 后台不执行相应全局剪贴板或 App UI 动作 |
| 自动地址栏聚焦 | 后台静默跳过；排队闭包内再次检查，不报告伪造交互 |

原 nonoptional openWindow/openTab 仍是 interactive-only primitive，未伪造空 controller、改变原返回类型或以 fatalError 代替结构化拒绝。主代理逐条追溯现有调用者，原公开/委托/命令入口在进入这些 primitive 前加门禁；不意味着专属后台窗口的创建已实现。

**普通模式：**新增 route 在 interactive 中只执行原 perform；原对话框、认证、下载、窗口与标签行为保留源码路径。本批完成产品编译，但没有把这个源码审查当作普通 GUI 回归已经通过。

**未覆盖/未验证：**没有安装 beforeunload 专用 hook，未验证原生 select/date/color/autocomplete、OS drag、PiP/pointer-lock、全屏、静音、屏幕/定位/通知、引擎剪贴板、WebAuthn/Passkey/ApplePay 等完整 UI 阻断。应用 printPage/share 方法门禁不等于网页 window.print/navigator.share 已拦截。后台认证是保守取消，服务端 TLS challenge 与绑定代理的实际非交互行为仍须单独验收；不能宣布真实 HTTPS 浏览已通过。

前批次 53 项真实能力矩阵 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-background-ui-policy-matrix.json` 保持全部 unverified；本批候选代码不把任何一项提升为 active。

## 2. 异步 RunnerAutomationController

`/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/RunnerAutomationController.swift`：Foundation + SafarierCore 的 MainActor 串行拥有者。它依赖已有 AutomationSessionMachine，而不是重写状态机、lease、缓存或输入队列。

必需注入 permissionReader、targetReader、actionSink、cleanupSink；时间默认为 DispatchTime monotonic + Task.sleep，可注入可控 clock/sleeper。没有默认真实驱动、GUI/JS/selector/Process 入口。

- handle 的调用有独立 invocation UUID，Core 的操作/关闭完成仍按完整 ticket 路由，不能只用 requestID 找 continuation。
- 错 token、非法 typed frame 在异步事实读取前拒绝。普通调用读取许可/目标，Core 分派后再次核验；排队 sink 任务在最后一次许可读取后，原子检查取消标志、调用仍存在、ticket、目标状态和**实际当前 deadline**再进入 sink。sinkStarted 只在实际调用时置位。
- cancel/close 是有效 token 的减权操作，绕过等待中的 reader/导航和满额度，作用于不可变的自身目标；不伪造权限去执行其它动作。
- earliest nextDeadline 驱动定时器，generation 忽略取消后的旧 timer；held/lease/cleanup 仍由 Core 的 5/30/2 秒绝对边界判断，不使用固定 sleep 宣告成功。
- 当前 sleeper 出错或提前返回不会留下永久 held/等待，也不重试忙循环。Core 新增明确 schedulingFailed owner 事件，用 false/false 回执关闭；不是把伪造时间交给 replay cache。
- 已授权的自身 cleanup 意图即使回执超时、任务取消或 owner 先释放，仍尝试一次。迟到成功不改变先前 false/false 终态；没有补发 mouseUp/click/drop。
- 调用及卡住的 reader 都有有界额度，取消但未真正返回的 reader 继续占槽；只存 UUID/计数，不因取消再请求而无限创建依赖任务。等待者恰好一次完成，跨注入 await 弱持有 controller，关闭后不再启动事实读取。
- stop/target/许可/WebContent 丢失和 UI blocked 使用原 machine.event。窗口丢失进入 stopping，不是可恢复的 UI block；其它危险 UI 被 blocked 后没有隐式 resume。

Core 只增加拥有者所需的只读 target/ticket/token/deadline 查询与上述 schedulingFailed 事件；原 protocol、replay cache、Profile/Runner 启动与脚本服务未替换。

**限制：**事实 reader 是注入接口，本批没有真实持久权限读取、GUI 撤权订阅、实际对象 UUID 映射、进程退出证明或 native sink。许可读取与跨进程修改不能原子化；未来 sink 必须在入口同步检查实际绑定对象，在任何后续 await 后继续遵守取消契约。这里可以有界完成/忽略回执，不能强制终止无视取消的任意注入代码；“cleanup 已调用一次”不是实际 WebView/Runner 已退出的证明。

## 3. 主代理 review 的修正

1. 取消/到期发生在 sink 排队期间仍可能执行：把 flag/ticket/deadline 检查放在任务内部、实际 sink 调用前，修正未执行却报告 possible 的标志。
2. 最后一次异步 target 读取后许可可能已失效：增加 sink 任务内最终许可重读及再次检查。
3. closed/stopping 请求不能再等卡住的 reader；cancel/close 不能被异步授权或额度挡住。
4. 当前 sleeper 出错/提前返回不能静默丢失期限，也不能产生忙循环；旧 timer 取消与当前失败区分处理。
5. cleanup 在到期前还没开始时不能被取消掉：主代理保留原代码快照，实际 RED 为 cleanup=0、state=closed；修复后同一反例 GREEN，cleanup=1、input=0，迟到成功仍不改变终态。
6. 卡住 reader 取消后仍需保留额度，防止无限重建后台任务。
7. 分享工具栏构造不是交互请求，改为静默省略；关闭目标回调和排队自动聚焦补模式检查。

主代理读取实际 worker RED/GREEN 日志，并独立编译最终源码验证；未交子代理 review。worker 测试早期的 Gate actor 隔离失败日志保留，不以修正 fixture 后的一轮结果替代最终重复验证。

## 4. 最终验证

主代理证据目录 `/Volumes/RC500/dev/safarier/.build/automation-stage5-main-review/`。真实全部 Core 静态编译，控制器使用实际 App 源文件；独立脚本只通过测试 define 省略模块 import，没有 fake XCTest 或替换生产类型。

| 验证 | 本轮结果 |
|---|---|
| 联合共享 cases，3 轮 | 每轮 protocol 340 + channel 28 + wire 117 + controlled 56 + script 59 + launch 64 + policy 117 + session 354 + UI boundary 395 + controller 317 = **1,847 项**，均 exit 0 |
| 主代理独立异步 controller，3 轮 | 每轮 **67 项**；每轮 20 个 queued-cancel 竞争、300 个 pending-call 容量、权限变化、stale timer、hold/cleanup、owner 生命周期反例 |
| 主代理独立 UI boundary，3 轮 | 每轮 **225 项**；泛型 nil/值返回、恰好一个分支、回调顺序、重入、外部 scheme；无 WebKit 对象 |
| 独立过期 cleanup RED/GREEN | 原快照失败，最终同一反例通过；非实际 OS 销毁测试 |
| 前批独立反例，3 轮 | 每轮 session 356 + policy 1,001 + script 281 + passive caller 39 全部通过 |
| 真实产品库对象链接的工厂，3 轮 | 每轮 8 类后台配置均提前 UI_POLICY_UNAVAILABLE，credential/privacy 调用为 0；无 GUI |
| 协议/进程回归 | request 71、reply 47、roundtrip 28、握手/持续连接 16、自有 Foundation 坏握手子进程 5 全通过 |
| 启动/元数据 | reducer 299,592 transitions、metadata/sdef 32 项通过，不等于真实启动验收 |
| 单独脚本 | UI boundary 395、controller 317 通过；XCTest wrappers 仅语法检查 |
| 实际产品 | 冻结后全产品 debug 编译/链接 exit 0，无 warning；未执行产物 |
| 工具链限制 | 当前默认 Manifest 仍存在 CLT PackageDescription ABI 故障；主代理用已有命令级 VFS overlay 构建，不改系统；本轮 XCTest 探针仍 no such module XCTest |

UI helper 的计数测试和对实际委托源码的接线审查，不等于已通过真实 WKUIDelegate/WindowServer/权限 UI 负例。真实事件、普通 GUI 与完整原 XCTest 本轮均未运行。

## 5. 门禁、尚未接线与下一步

- G0 正规测试/release/打包验收仍未全量通过；G1 冷热 AppleScript、唯一 Manager 路由及焦点仍未验证；G2 完整 UI/输入能力仍全部不放行。
- BrowserSession 的拒绝通知和异步 controller 的事件入口都已具备，但 shipping unavailable 服务**未装配二者**；没有真实背景窗口、控制器、native 输入或目标销毁。
- 下一步仍按原 Task 5/6 抽取并复用唯一 native driver、真实专属目标/通道接线和进程级收尾，再在隔离图形环境执行完整 G1/G2/正式闭环。不能只删工厂 guard、改 capabilities=active 或用全局输入弥补。
- 最终检查 **107/107** 通过：批次前 175 个文件中只修改约定的 5 个源码文件和 2 份设计/进度文档，另外 168 个保持 hash；新增 10 个代码/测试/脚本文件和本报告，共 11 个。源码冻结、系统工具链 hash、全局 developer directory 和邻接仓库 Git 状态均保持一致，自有 helper 遗留 0，staging 为空。完整证据见上述目录 final-review.json。
- 本轮不提交、推送、安装或发布，不授权运行候选 App 或扩大后台白名单。
