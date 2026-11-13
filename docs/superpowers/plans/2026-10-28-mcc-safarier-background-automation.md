# MCC–Safarier Background Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task with terra-worker implementers. Steps use checkbox syntax for tracking. 用户明确规定：开发由 terra-worker 执行，所有设计/代码 review 只能由主代理执行，不分派 reviewer 子代理；按任务边界顺序推进。

**Goal:** 在一个 Safarier.app 内完成 AppleScript → Manager → 专属后台 Runner → 原生页面操作与结果的闭环，不干扰用户其它 App 的鼠标键盘。

**Architecture:** 保留同一二进制的 Manager/CLI/Runner 角色，复用 Profile、flock、代理与 DataStore。Manager 通过继承 socketpair 连接只控制自己启动的后台 Runner；输入仅经过已核验的 SafarierObjCSupport 局部后端。安全能力、冷启动、目标/状态和清理任何一项不满足就拒绝。

**Tech Stack:** Swift/SwiftPM、Foundation、AppKit、SwiftUI 现有管理内容、系统 WebKit、Objective-C runtime bridge、Cocoa Scripting/sdef、socketpair；Python/bash 只用于测试编排，不新增运行时依赖。

**Spec:** `/Volumes/RC500/dev/safarier/docs/superpowers/specs/2026-10-28-mcc-safarier-background-automation-design.md`。

## Global Constraints

- **C1**：禁止全局输入兜底：不投递全局 CGEvent，不移动/回移系统鼠标，不调用 System Events、辅助功能点击、全局按键或抢焦点重试。
- **C2**：禁止生产网页 JS 注入、DOM click/dispatchEvent、任意脚本执行或任意 selector 执行接口。
- **C3**：后台任务不得激活 Manager/Runner、设置真实 key window、隐藏/改变系统光标、改变全局修饰键、Secure Input 或用户输入法状态。
- **C4**：缺少已验证的输入能力、UI 逃逸拦截能力、目标身份或后台状态时明确拒绝；不把 unavailable/degraded 当作自动化成功。
- **C5**：复用 Profile、ProfileLock、代理、DataStore、RunnerLauncher 与原生桥；不增加第二套浏览器、独立常驻 daemon 或默认监听端口。
- **C6**：首版只控制专属后台 Runner 的单窗口/单 WebView；不接管已在运行的人工 Profile，不支持会话中自动切换前台。
- **C7**：临时按钮/页面活动状态必须有界收尾；光标写入保护允许仅在专属 Runner 内常驻至进程退出，不能宣称所有 hook 都在 close 时卸载。
- **C8**：代码与设计审查只由主代理执行；不交子代理 review。未经用户要求不提交、推送、合并、安装或发布。

**执行状态（2026-10-29）：用户已确认设计/计划，并指定 terra-worker 开发、主代理全部复核。** 已完成六批候选/离线代码：Task 3 协议/重放/许可、Task 4 私有通道/受控启动/RPC、Task 1 单一 Manager 候选生命周期、Task 7 脚本薄入口/默认关闭的打包元数据，以及 Task 2 策略/构造前拒绝/原 UI 边界和 Task 6 会话效果核心/异步 owner，以及 Task 5 唯一 native 路径抽取/私有截图存储；均有主代理独立验证。正式产品仅以命令级诊断 overlay 编译链接通过，未运行。真实 XCTest 缺失，G0 未全量通过；G1 冷启动/唯一接收者/GUI、G2 完整后台输入安全门禁均未通过。Task 2/5/6 与 Task 8 正式闭环尚未完成；默认脚本入口关闭，所有页面动作拒绝。各 Task 原验收清单不因离线验证而自动通过，实际接口以源码和分批报告为准。

- 仓库：`/Volumes/RC500/dev/safarier`，分支：`mcc-safarier`，当前 HEAD：`2f32d21248deaffd8c8c1152a39912aa46350c7e`。
- 复用当前工作区原生修复；不得 reset/覆盖已有 dirty files。执行前重查实际 diff；相邻 `chrome-control-cli` 仓库不在修改范围。
- 原项目 macOS 最低版本仍为 14；后台输入首个候选验证组合仅 macOS 26.6.2/arm64/WebKit `21624.5.1.11.3`，G1/G2 通过前仍不可用。其它版本正常浏览照旧、自动化 unavailable。
- 原仓库完整 `swift test` 包含会显示/激活窗口的 AppKit 测试，须在隔离图形环境执行；当前用户桌面仅编译/纯逻辑测试，不运行旧 GUI 路径。
- 2026-10-28 选中 CLT 时记录了 PackageDescription ABI 问题；2026-10-30 用户安装并许可 Xcode 27.2 后默认 manifest 与正确平台路径下 XCTest 已复核通过。手工 probe 仍不是 G0 替代；本轮不改全局 xcode-select 或系统 SDK。
- 用户已同意不安装完整 Xcode 的替代调查：G0 不以 Xcode.app 是否存在作判据；需要匹配的编译器/SDK/真实测试组件及可重复证据。临时 interface overlay 目前仅是诊断路径；不能因编译成功跳过原 XCTest 或 GUI 安全验收。
- 每个任务按 RED → 最小实现 → GREEN → 主代理 review；提交只是未来可选检查点，本计划不授权执行 git commit/push。

## 文件职责与复用图

下表列的是计划文件；已有模块不因本功能整体重写。

| 路径（仓库根为 `/Volumes/RC500/dev/safarier`） | 责任/变更 |
|---|---|
| `Sources/SafarierCore/AutomationProtocol.swift`（新） | 强类型动作/回执/错误/限额、严格 JSON codec、幂等缓存 |
| `Sources/SafarierCore/AutomationChannel.swift`（新） | socketpair、长度帧、生命周期、背压；不依赖 AppKit |
| `Sources/SafarierCore/Profile.swift`、`RunnerLaunchSpec.swift`、`RunnerLauncher.swift`、`SafarierWorkspace.swift` | opt-in、后台参数、继承 stdin、沿用原启动约束 |
| `Sources/Safarier/ManagerGUI/ManagerApp.swift`、`ManagerMenu.swift`（新） | 单一非激活启动生命周期；复用原 SwiftUI 内容/Model；仅人工打开才建窗口/菜单 |
| `Sources/Safarier/ManagerGUI/ProfileEditorView.swift`、`ManagerModel.swift` | Profile 许可开关、撤权；原创建/复制逻辑保留 |
| `Sources/Safarier/Automation/AutomationManager.swift`（新） | Apple Event caller 校验、会话/Runner 所有权、路由/去重/关闭 |
| `Sources/Safarier/Automation/RunnerAutomationController.swift`（新） | 主线程队列、精确目标、lease/hold deadline、回执/终止 |
| `Sources/Safarier/Automation/NativePageInput.swift`（新） | 从 probe 抽取唯一局部输入驱动；快照、局部输入/活动收尾 |
| `Sources/Safarier/Automation/BackgroundPagePolicy.swift`（新） | 人工/自动化策略、UI 入口枚举、能力门禁；无任意 selector |
| `Sources/Safarier/Automation/AutomationRequestCommand.swift`（新） | 薄 NSScriptCommand JSON 适配与一次性异步回复 |
| `Sources/Safarier/Resources/Safarier.sdef`（新） | 唯一正式 AppleScript 命令词典 |
| `Sources/Safarier/RunnerMain.swift`、`Browser/BrowserSession.swift`、`Browser/BrowserWindowController.swift`、`Browser/BrowserViews.swift`、`Browser/DownloadsController.swift` | 原拥有者内接入策略；禁止第二套窗口/下载生命周期 |
| `Sources/SafarierWebKit/WebViewConfigurationFactory.swift`、`SPIRuntimeBridge.swift`，`Sources/SafarierObjCSupport/SFRRuntime.m` 及头文件 | 按 G2 核验结果在既有桥增加固定能力，不从 Swift 裸调未知 ABI |
| `Package.swift`、`scripts/build-app.sh` | 资源声明/打包 sdef/最早期 LSUIElement；不降低测试或签名要求 |
| 原有 `scripts/background-input-probe/*`、`scripts/test-native-background-input.sh` | 探针复用生产驱动，继续保留 30 项/9×25 原检查与无输入对照 |
| 新 `Tests/SafarierCoreTests/AutomationProtocolTests.swift`、`AutomationChannelTests.swift` | wire/IPC/严格拒绝/去重测试 |
| 新 `Tests/SafarierAppTests/ManagerLaunchTests.swift`、`BackgroundPagePolicyTests.swift`、`AutomationSessionTests.swift`、`NativePageInputTests.swift`、`AutomationRequestCommandTests.swift` | 启动、策略、状态、路由与脚本单测 |
| 新 `scripts/verify-applescript-background-input.sh`、`Tests/Fixtures/BackgroundAutomation/`、`docs/verification/2026-10-28-applescript-background-automation.md` | 正式包入口与隔离场景验收/证据 |

## 共享接口与确定的常量

以下定义在对应任务落地；后续任务必须用这些名字，不自行新增同义协议：

```swift
// AutomationProtocol.swift；各 associated value 的 wire 编码由 codec 显式完成。
public struct ViewportPoint: Equatable, Sendable { public let x: Double; public let y: Double }
public enum AutomationKey: String, Codable, Sendable {
    case backspace = "Backspace", delete = "Delete", enter = "Enter", tab = "Tab", escape = "Escape"
    case left = "Left", right = "Right", up = "Up", down = "Down", home = "Home", end = "End"
}
public enum AutomationAction: Equatable, Sendable {
    case capabilities, openSession(profileID: UUID), getState, navigate(url: URL), screenshot
    case move(point: ViewportPoint, viewVersion: UInt64)
    case mouseDown(point: ViewportPoint, viewVersion: UInt64)
    case mouseUp(point: ViewportPoint, viewVersion: UInt64)
    case click(point: ViewportPoint, viewVersion: UInt64, count: Int)
    case scroll(point: ViewportPoint, viewVersion: UInt64, deltaX: Double, deltaY: Double)
    case insertText(String), key(name: AutomationKey, shift: Bool), cancel, closeSession
}
public struct AutomationRequest: Equatable, Sendable {
    public let version: Int; public let requestID: UUID
    public let sessionID: String?; public let action: AutomationAction
}
public enum AutomationLimits {
    public static let frameBytes = 65_536, textBytes = 16_384, replayEntries = 256
    public static let startupSeconds = 30.0, navigationSeconds = 30.0
    public static let actionSeconds = 5.0, idleSeconds = 30.0, heldSeconds = 5.0, cleanupSeconds = 2.0
    public static let screenshotMaxEdge = 4_096, screenshotMaxBytes = 33_554_432, screenshotCount = 8
}
// API 契约：实现返回类型的字段必须与设计第 6/7/9 节逐项对应。
// AutomationCodec.decode(_ data: Data) throws -> AutomationRequest
// AutomationCodec.encode(_ reply: AutomationReply) throws -> Data
// AutomationChannel.makePair() throws -> (parent: AutomationChannel, child: FileHandle)
// AutomationChannel.send(_ frame: Data) async throws
// AutomationChannel.receive() async throws -> Data?  // nil=EOF
// AutomationChannel.close()
// @MainActor AutomationManager.handle(_ request: AutomationRequest, caller: AutomationCaller) async -> AutomationReply
// @MainActor NativePageInput.open(controller: BrowserWindowController) async throws -> NativePageInput
// @MainActor NativePageInput.perform(_ action: AutomationAction) async throws -> NativeInputReceipt
// @MainActor NativePageInput.close(reason: AutomationCloseReason) async -> CleanupReceipt
```

`AutomationReply` 必填 version/requestID/status（requestID 无法安全解析时为 nil 编码为 null）；成功含 effect/result，失败含 error，互斥且省略不适用字段。内部 `AutomationOutcome` 只能 success(effect:result:) 或 failure(error:)；result 用按 effect 区分的强类型，error 含 code/retryable/sideEffects；不能用任意 Any 值实现业务接口。`AutomationCaller` 只由可信 Apple Event audit 信息构造。`AutomationCloseReason` 至少含 requested/cancelled/expired/heldDeadline/channelClosed/targetChanged/permissionRevoked/runnerExited。`CleanupReceipt` 必须区分 cleaned 与 terminatedOwnedRunner，不能隐藏未恢复的临时状态。

---

### Task 0：G0 工具链与原工作区基线

**Files:** 读取 `Package.swift`、既有测试/打包脚本与 `.build/mcc-safarier-probe/` 证据；诊断报告为 `docs/verification/2026-10-28-automation-build-baseline.md` 与用户批准的 `docs/verification/2026-10-28-automation-clt-alternative.md`；运行代码/原测试不在本任务修改范围。

**Interfaces:** 输入为现有 checkout/工具链；产出明确 developer directory、版本、基线日志与 G0 pass/blocked，不提供“临时删除测试”的替代方案。

**2026-10-30 最新结论：manifest / XCTest 阻塞已解除，原 Debug/Release 与全部四个测试目标已编译通过，但完整 G0 仍 unverified，Task 0 未全量验收。** 以下为此前 CLT/诊断 overlay 的历史记录，不冒充当前 Xcode 结果： terra-worker（实际模型 `gpt-6.1-terra`，high）完成基线与替代调查；主代理独立确认：默认 manifest 仍 exit 1；本机 interface overlay + 全新独立缓存可使原 manifest 和正式 Safarier debug 产品编译/链接 exit 0。真实 XCTest 编译仍 exit 1，未运行测试、产物或 GUI，未改系统或原源码。两份报告分别保存原始失败与后续替代证据。

- [x] 记录 `git status --short --branch`、`git rev-parse HEAD`、`git diff --stat`、`xcrun swift --version`、`xcode-select -p`；保存已有改动哈希。
- [x] 重现 RED：运行 `swift package dump-package`，保存 stdout/stderr 和退出码；确认与当前 PackageDescription 缺符号一致，而非业务测试失败。
- [x] 只读列出已安装的 Xcode/CLT；完整 Xcode 仅为候选，缺失不直接否定 CLT。命令级替代诊断已执行且复核；不得全局切换/修改系统；没有满足编译与原测试要求的配套环境仍停在 G0。
**已验证的局部结果（不勾选下方完整基线）：** 原 manifest 在诊断 overlay 下 exit 0；真正 Safarier 产品 debug 编译/链接 exit 0，worker 与主代理各一组独立缓存；最小 import XCTest exit 1。未进行 release、App 打包、原测试或 GUI 验收。实验与日志全在 `.build/automation-clt-alternative/`、`.build/automation-main-review/clt-repeat/`，不是新生产构建入口。

- [ ] 在 G0 可用后执行以下基线；缺 sing-box 的测试跳过要单列，不冒充全覆盖：

```sh
cd /Volumes/RC500/dev/safarier
swift package dump-package
# 当前桌面只编译全部测试，不运行 GUI：
swift build --build-tests
swift test --filter 'SafarierCoreTests|SafarierNetworkTests'
swift build -c release --product Safarier
scripts/test-native-background-input.sh
# 仅在已有依赖齐全时，构建不安装，不启动 GUI：
SAFARIER_ARCH=arm64 scripts/build-app.sh
```

- [ ] 在隔离图形会话执行完整 `swift test`，主代理检查原 Profile/代理/锁及人工窗口测试基线；未具备隔离环境时 G0 的完整测试验收仍 blocked。G0 未通过时不可交付正式 App 或在用户桌面试验新入口；按用户后续明确授权可先开发并独立验证不接入桌面的纯 Core 功能，不把它当作 G0 全量通过。

### Task 1：G1 单一 Manager 非激活生命周期

**Files:** 修改 `Sources/Safarier/ManagerGUI/ManagerApp.swift`、`scripts/build-app.sh`；新建 `Sources/Safarier/ManagerGUI/ManagerMenu.swift`、`Sources/SafarierCore/ManagerLaunchPolicy.swift`、`Tests/SafarierCoreTests/ManagerLaunchCases.swift` / `ManagerLaunchTests.swift` 与 `Tests/SafarierAppTests/ManagerLifecycleTests.swift`；G1 记录进正式验证报告。

**Interfaces:** 新 `ManagerLaunchIntent`（automation/interactive/undetermined）与 `ManagerLaunchDecision`（stayAccessory/showManager/rejectUnverified）；`ManagerLaunchPolicy.decide(intent:)` 是纯函数。生产只保留一个 Manager 生命周期。`SafarierAppView`、`ManagerModel` 原接口保留。

- [ ] 写并运行 RED 测试：

```swift
func testAutomationAndUnknownIntentNeverShowManager() {
    XCTAssertEqual(ManagerLaunchPolicy.decide(intent: .automation), .stayAccessory)
    XCTAssertEqual(ManagerLaunchPolicy.decide(intent: .undetermined), .rejectUnverified)
}
func testExplicitInteractiveIntentShowsExistingManager() {
    XCTAssertEqual(ManagerLaunchPolicy.decide(intent: .interactive), .showManager)
}
```

Run: `swift test --filter ManagerLaunchTests`；首次应因尚无策略类型失败，而不是跳过。

- [ ] 先在独立 fixture .app/隔离图形会话验证 `launch`、首条自定义事件、oapp/rapp 的实际顺序，验证最早期 `LSUIElement`、accessory 与延迟窗口创建；记录 `BACKGROUND_LAUNCH_UNVERIFIED` 拒绝分支。再测仅人工 Runner 存活、Manager + 多 Runner、Runner 前台和旧 App 副本，Apple Event 必须唯一到预期 Manager；若同 Bundle 多实例不能可靠区分就 G1 blocked，向用户另提内部 helper 身份/打包方案，不能擅自叠加服务。不在用户桌面试激活再隐藏。
- [ ] 用 NSApplication 单一生命周期替换旧 `ManagerApp.main()` 所有者，原 SwiftUI view 放入 NSHostingController；迁移已有中文菜单/快捷键，删除被替代的 SwiftUI Scene/commands 路径，不做第二套 Manager。`showManager` 仅供可信的人工打开意图使用。
- [ ] build-app 加入 `LSUIElement=true`；后台默认不 regular、不 activate；人工打开才显式呈现；关窗口但有会话不退出，显式 quit 留给 Task 6 统一取消。正常 CLI 与普通 Runner 的角色分派不变。
- [ ] GREEN：上面的纯策略单测；原 ManagerFixesTests/菜单回归仅在隔离图形会话执行；冷启动/热启动/双击/reopen 各 3 轮记录无激活/真实 key/空间切换。隔离验收 G1 不过就阻止正式入口接通。
- [ ] 主代理 review 生命周期是否有 implicit window、启动时 Dock 瞬变、晚到事件或两套菜单；超出设计的 UI 重构需另报，不顺手扩大范围。

### Task 2：G2 完整安全能力门禁，不先开放输入

**Files:** 新 `Sources/Safarier/Automation/BackgroundPagePolicy.swift`、`Tests/SafarierAppTests/BackgroundPagePolicyTests.swift`；修改原 `BrowserSession.swift`、`BrowserWindowController.swift`、`BrowserViews.swift`、`DownloadsController.swift`、`WebViewConfigurationFactory.swift`；必要固定 bridge 扩展只入 `SFRRuntime.m`/头文件及 `SPIRuntimeBridge.swift`。新建 `docs/verification/2026-10-28-background-ui-policy.md`。

**Interfaces:** `BrowserExecutionPolicy` = interactive/automationBackground；`BackgroundUIRequest` 一一覆盖设计第 8 节的入口；`BackgroundPagePolicy.decide(_:) -> BackgroundUIDecision`，自动化危险入口为 cancelAndSuspend；`BackgroundSafetyCapabilities.isComplete: Bool`，未验证项一律 false。配置工厂增加默认 interactive 参数。

- [ ] 写 RED：每种危险入口在自动化中拒绝，人工模式维持现有策略。测试列表不是随意抽样，必须枚举第 8 节全部入口：

```swift
func testAutomationRejectsEveryEscapingUIRequest() {
    let policy = BackgroundPagePolicy(mode: .automationBackground)
    for request in BackgroundUIRequest.escapingCases {
        XCTAssertEqual(policy.decide(request), .cancelAndSuspend(request.blockReason))
    }
}
func testUnknownSafetyCapabilityBlocksAutomation() {
    XCTAssertFalse(BackgroundSafetyCapabilities.unverified.isComplete)
}
```

Run: `swift test --filter BackgroundPagePolicyTests`，确认 RED。

- [ ] 在原拥有者入口加前置分支：createWebView=nil、openPanel=nil、confirm=false、prompt=nil、媒体权限 deny、download cancel、网页认证 cancel、外部 URL scheme cancel；beforeunload 保证一次完成。保留原绑定代理的自动认证，不落入网页密码 UI。
- [ ] 建 WebView 前关元素/视频全屏、PiP、系统 drag、pointer lock、平台 popup、敏感 API/外部认证与有声输出；每项先确认公开/私有接口、类型编码、设置与回读。不臆造 selector，不把 willOpenMenu 或事后 orderOut 视为提前拦截。
- [ ] 将 G2 矩阵写实：每行标 runtime signature、readback、隔离图形负例证据和结论；没有安全入口则记录 unavailable，并令 `isComplete=false`。不靠“测试页面暂时不用该功能”放行通用网页输入。
- [ ] GREEN：单测使用调用计数 spy 证明禁用路径没有创建 sheet/window/menu/drag session，没有调用系统权限/光标方法；异常/缺签名/hook 冲突均拒绝。`swift test --filter 'BackgroundPagePolicyTests|SafariBehaviorTests|BrowserFixesTests'` 与原生桥严格测试。
- [ ] 在可丢弃、同构建图形桌面跑第 8 节所有危险 fixture；未准备环境就标 G2 blocked，不在当前桌面补试。主代理评审 capability bundle 完整性后才允许后续 native perform 真执行。

### Task 3：强类型 wire、幂等与安全默认的 Profile opt-in

**Files:** 新 `Sources/SafarierCore/AutomationProtocol.swift`、`Tests/SafarierCoreTests/AutomationProtocolTests.swift`；修改 `Profile.swift`、`ManagerGUI/ProfileEditorView.swift`、`ManagerModel.swift` 与 `Tests/SafarierCoreTests/ProfileTests.swift`。

**Interfaces:** 实现“共享接口”中的动作/请求/回执/codec/限额；新增 `Profile.allowsBackgroundAutomation=false`，旧记录 decodeIfPresent 默认 false；GUI 许可不能由 automation action 自行开启。去重按设计第 6.2 节，非透明重试。

- [x] 先补 RED：合法 openSession 解码、未知 action/未知字段/重复键/错误类型/超限拒绝、未知版本；旧 Profile JSON 无许可字段时 false。

```swift
func testUnknownActionIsRejectedInsteadOfEvaluated() {
    let data = Data(#"{"version":1,"requestID":"00000000-0000-4000-8000-000000000001","action":"evaluateJavaScript","parameters":{}}"#.utf8)
    XCTAssertThrowsError(try AutomationCodec.decode(data))
}
func testOpenSessionDecodesTypedProfileID() throws {
    let id = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    let data = Data(#"{"version":1,"requestID":"00000000-0000-4000-8000-000000000002","action":"openSession","parameters":{"profileID":"00000000-0000-4000-8000-000000000003"}}"#.utf8)
    XCTAssertEqual(try AutomationCodec.decode(data).action, .openSession(profileID: id))
}
```

Run: `swift test --filter 'AutomationProtocolTests|ProfileTests'`；缺类型 RED，保留原 profile 兼容断言。

- [x] 按 action 显式解码/编码并校验 key 集；在 JSONDecoder 前做结构化 duplicate-key 检测，不用 regex 扫描或接受后值覆盖。`http/https` URL 校验不做任何代理绕行解析。
- [x] 对每个设计错误码、effect 与 sideEffects 定义稳定枚举/结果类型；缓存相同 requestID 且相同 payload 的回执，不再次 dispatch；不同 payload 返回 REQUEST_ID_REUSED；256 上限满时拒绝，closed tombstone 保持到 lease 窗口结束。
- [ ] 在原 Profile 构造/自定义 decoder/CodingKeys 内接入默认 false；GUI 原 editor 保存开关；在原 `Profile.duplicated(name:id:createdAt:)` 内显式不复制自动化许可（置 false），保留其它原字段；原编辑器“修改在下次启动生效”的提示补充“撤销后台自动化许可立即停止会话”，不改变其它配置的原生效时机。
- [ ] GREEN：协议、旧 JSON、创建/编辑/复制/重读与脱敏测试；错误 message 只放固定文案，不回显原参数。主代理 review 兼容性与是否意外改写真实 profiles.json；测试只能用临时 workspace。

### Task 4：继承 socketpair 与原有 Runner 启动协议

**Files:** 新 `Sources/SafarierCore/AutomationChannel.swift`、`Tests/SafarierCoreTests/AutomationChannelTests.swift`；修改 `RunnerLaunchSpec.swift`、`RunnerLauncher.swift`、`SafarierWorkspace.swift`、`RunnerMain.swift` 与原有 RunnerLaunchSpecTests/RunnerLauncherTests/WorkspaceLaunchTests 的 recording spawner。

**当前范围：通道、受控启动、双向 codec、身份握手、Core client 和 Runner 早拒绝分支已实现并经主代理 review。** Foundation fixture 已验证 stdin 双向继承、execv、未指定 FD 不继承及断连退出；真实 App/代理完整初始化/页面后台运行仍未验收。

**Interfaces:** `AutomationChannel.makePair/send/receive/close` 如共享接口；ProcessSpawning 保留旧 spawn，增加带 `standardInput: FileHandle` 的 overload；旧实现默认明确拒绝受控输入，Foundation 实现复用同一内部 spawnProcess。RunnerLauncher.launch 增加可选 controlInput 默认 nil；`RunnerLaunchSpec.backgroundAutomation=false`，`--background-automation`；workspace launch 传递 mode 和受控 stdin，仍检查锁。握手包括 version/profileID/runnerInstanceID/nonce。

- [x] 写并运行 RED：分片帧重新拼接、超长长度立即拒绝、不完整 EOF 不执行；旧 launch 不传通道且参数与原测试一致；后台标志与 probe 组合拒绝。

```swift
func testChannelRoundTripAndEOF() async throws {
    let pair = try AutomationChannel.makePair()
    let child = try AutomationChannel(adopting: pair.child)
    let payload = Data("fixture-frame".utf8)
    try await pair.parent.send(payload)
    let received = try await child.receive()
    XCTAssertEqual(received, payload)
    pair.parent.close()
    let eof = try await child.receive()
    XCTAssertNil(eof)
}
```

Run: `swift test --filter 'AutomationChannelTests|RunnerLaunchSpecTests|RunnerLauncherTests|WorkspaceLaunchTests'`。

- [x] 实现有界 framing、partial read/write、SO_NOSIGPIPE、IO 线程/背压/关闭；加入 `init(adopting: FileHandle) throws` 并检查 AF_UNIX/SOCK_STREAM 类型。send/receive 不在主线程阻塞。
- [x] 在原 Process spawner 内将受控 FileHandle 接到 stdin；普通路径保留 nullDevice；通过显式 overload 保持旧 conformer/recording 调用兼容，未实现新能力必须报错而非丢弃通道，不另写启动器。
- [ ] 真正可操作页面的 Runner 在原 ProfileLock/代理初始化后握手（当前仅在锁后、代理和 NSApplication 前运行 unavailable 服务，不能据此勾选完整链路）；语言跟随 execv 前后连接不断，完成自重启再设 FD_CLOEXEC；排查所有 helper stdin，保留 curl 凭据 pipe 与 sing-box null，不让它们持有控制 fd。
- [x] 用无 GUI 子进程 fixture 验证：parent 关闭后 child 收 EOF、child 退出 parent 得到确定错误、execv 后 fd0双向可用、其它 helper 不保留 fd；nonce/Profile/版本不符在原生 UI 创建前拒绝。
- [ ] GREEN：上述测试、锁竞争双启动、原普通 launch/probe 回归；主代理检查没有 listen/connect 公共服务、argv token、日志文字或泄漏的父子描述符。

### Task 5：唯一生产原生输入驱动、视口与安全收尾

**Files:** 新 `Sources/Safarier/Automation/NativePageInput.swift`、`Tests/SafarierAppTests/NativePageInputTests.swift`；修改 `scripts/background-input-probe/NativeEvents.swift`、`build-probe.sh`、`Package.swift`（可执行目标显式依赖 ObjCSupport），必要原生测试只入既有 `Tests/NativeInput/ScopedMouseStateTests.m`。

**Interfaces:** NativePageInput.open/perform/close 如共享接口；`NativeInputReceipt` 含 sequence/buttons/viewVersion；`CleanupReceipt` 含清理/需终止信息；NativePageInput 只接受固定 action 集，拥有精确 controller/WebView 引用和 expected geometry。生产无 stub、无测试 trace。

- [ ] 写 RED：idle 下 mouseUp、held 下 click、超界/非有限坐标、viewVersion 变化都在送入前拒绝；取消 held 不补 click/drop；非后台或原生门禁未完成不创建 lease。

```swift
func testPointerValidationDoesNotClipCoordinates() {
    let viewport = AutomationViewport(viewportWidthPoints: 1280, viewportHeightPoints: 800,
        pixelWidth: 2560, pixelHeight: 1600, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
    XCTAssertFalse(viewport.contains(ViewportPoint(x: 1280, y: 10)))
    XCTAssertFalse(viewport.contains(ViewportPoint(x: .infinity, y: 10)))
    XCTAssertTrue(viewport.contains(ViewportPoint(x: 1279, y: 799)))
}
```

`AutomationViewport` 已由协议核心定义完整 metadata；本任务在 `Sources/SafarierCore/AutomationProtocol.swift` 的该类型补 contains（用 viewportWidthPoints/viewportHeightPoints、finite 与半开边界），不重定义或叠加同名模型。后续截图必须使用同一几何来源。

- [ ] 从现有 NativeEvents 抽取既有事件构建、hitTest、TLS 按钮、页面活动和 pending-mouse completion，不重新实现另一条 driver。`stub` 留在测试适配层，probe 真实模式直接用生产类。
- [ ] 实现固定键集合/Unicode 输入与局部 hitTest 路由；没有真实 key window、没有 NSApp.sendEvent 扫过 App 菜单、没有持久 modifiers；先验证动作/focus/target 再送入，回执只宣称 nativeDelivered。
- [ ] 快照使用目标 WebView 原生 API；返回设计第 7 节完整 metadata；按 0700/0600、O_EXCL/不跟随 symlink、8 份/32MiB/4096 边限额写在自有目录，失败不自动截图。close 清登记文件，不扫任意目录。
- [ ] close 时执行已验证 local cancellation；不能安全取消时回 `terminatedOwnedRunner` 需求交 Task 6，绝不模拟一次 mouseUp；恢复临时按钮/逻辑 key 查询，保留 Runner 常驻 cursor guard。所有晚到回调按 epoch 拒绝。
- [ ] GREEN：`swift test --filter NativePageInputTests`、`scripts/test-native-background-input.sh`；G0/G2 通过且在批准的隔离环境时再跑原 `scripts/verify-background-input.sh --prefix formal-driver --rounds 3`。主代理检查 probe 不再保留第二份真实 driver、未删旧红测与输入栅栏。

### Task 6：Manager/Runner 会话所有权、lease 与取消优先级

**Files:** 新 `AutomationManager.swift`、`RunnerAutomationController.swift`、`Tests/SafarierAppTests/AutomationSessionTests.swift`；修改原 `RunnerMain.swift`、`BrowserSession.swift`、`BrowserWindowController.swift`、`ManagerApp.swift`、`ManagerModel.swift`。

**Interfaces:** AutomationManager.handle(request,caller) 返回 AutomationReply；RunnerAutomationController 持有一个目标和串行队列；TargetIdentity 的字段为 profileID/runnerInstanceID/windowID/pageID；session state = opening/ready/held/blocked/stopping/closed。Manager 的测试依赖使用现有 ProcessSpawning 与注入 monotonic clock/native-action sink，不走真实 GUI。

- [ ] 写 RED：已运行人工 Profile 拒绝且 spawn/activate 计数均 0；错 token/撤权/错 nonce 不 dispatch；同 requestID 点击 sink 只调用一次；close 两次结果稳定。
- [ ] 写 fake clock RED：29 秒有效、30 秒 lease 关闭；hold 5 秒绝对到期；命令续期不延长旧 hold；cancel 越过正在等导航的队列；迟到 completion 不恢复 ready。
- [ ] 生产 openSession 先权限/锁/版本门禁，再走 workspace/RunnerLauncher；首次用显式 `startURL=about:blank` 覆盖 workspace 的 Profile.startURL 默认值，完成 UI policy/输入准备后方可导航。保留 Profile 语言/时区/代理/机型/数据存储配置。
- [ ] BrowserSession(.automationBackground) 的专属窗口 orderOut、非 key/main、ignoresMouseEvents；不 activate/makeKey/tab merge。人工默认路径完整保留。所有导航/几何变化令 viewVersion 失效并触发安全取消。
- [ ] 实现 EOF、撤权（ManagerModel.save/reload 对许可 true→false 立即通知；每次操作前另读持久记录，外部文件修改受 lease/hold 上限约束）、Manager quit、WebContent crash、超时、不可安全取消的有界关闭；仅保存的 Process/握手身份匹配才允许终止；不按名字 kill，不复用旧 PID。sing-box 保持原 Runner cleanup 责任。
- [ ] GREEN：`swift test --filter 'AutomationSessionTests|BrowserWindowTests|SafariBehaviorTests|WorkspaceLaunchTests'`；主代理 review 所有状态转换/定时器/一次回复与清理。held cancel fixture 的 click/drop 计数必须为 0，而不是只看按钮变量归零。

### Task 7：AppleScript 正式入口与 App 资源

**Files:** 新 `AutomationRequestCommand.swift`、`Sources/Safarier/Resources/Safarier.sdef`、`Tests/SafarierAppTests/AutomationRequestCommandTests.swift`；修改 `Package.swift`、`scripts/build-app.sh`、`ManagerApp.swift` 的脚本服务装配。

**Interfaces:** 脚本类 `@objc(SFRAutomationRequestCommand)`；入口 `automation request`，event `SFAu/requ`，direct parameter/result 均 text；运行错误统一 JSON，系统 TCC 错误不吞。只复制可信 sender descriptor 所需内容，不能长期保留 current appleEvent 对象。

- [ ] 写 RED：invalid JSON/超长 frame 不进 Manager；无可信 sender 拒绝；请求一次 suspend → success/error/timeout 各一次 resume；cancel 与 late reply 竞争不双回调；日志不含原输入/session token。
- [ ] 加词典：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<dictionary title="Safarier">
  <suite name="Safarier Automation" code="SFAu" description="Background page automation">
    <command name="automation request" code="SFAurequ" description="Submit a versioned JSON request">
      <cocoa class="SFRAutomationRequestCommand"/>
      <direct-parameter type="text" description="JSON request"/>
      <result type="text" description="JSON reply"/>
    </command>
  </suite>
</dictionary>
```

- [ ] NSScriptCommand 使用 `suspendExecution()` 后交 AutomationManager，`resumeExecution(withResult:)` 恰好一次；禁止主线程 semaphore.wait/sleep。超时仍触发会话收尾，不能让脚本超时后后台继续按住。
- [ ] SwiftPM 注册资源且 build-app 显式复制 sdef 到 Contents/Resources；Info.plist 写 NSAppleScriptEnabled/OSAScriptingDefinition；维持 G1 最早期启动配置、原 Bundle ID 和 macOS14 普通浏览要求。
- [ ] GREEN：`swift test --filter AutomationRequestCommandTests`；正式包跑 `plutil -lint`、`sdef` 词典读取、`codesign --verify --deep --strict`；在隔离图形环境通过真实 osascript 的 capabilities/open/getState/close，验证返回的 role/Manager PID/构建来自预期 App 而不是某个 Runner 或已安装旧版；非 Manager 接收端明确拒绝，不能执行输入。
- [ ] 主代理 review：只有这一入口，没有隐式 activate、GUI scripting、任意 eval/selector/路径出口。未完成 G1/G2 时 openSession 硬拒绝，capabilities 可以如实返回 unavailable。

### Task 8：正式闭环、多轮不干扰验证与交付边界

**Files:** 新 `scripts/verify-applescript-background-input.sh`、`Tests/Fixtures/BackgroundAutomation/`、`docs/verification/2026-10-28-applescript-background-automation.md`；只在验收通过后同步 README.md/README.zh-CN.md 的实际已交付命令，不提前宣传支持。

**Interfaces:** 测试脚本必须接受明确 `--app /absolute/path/Safarier.app`、`--prefix`、`--rounds 3`、独立 `SAFARIER_HOME` 与测试进程登记；默认不安装、不覆盖系统 App、不触摸真实 Profile，不删除其它任务进程。

- [ ] RED/阴性对照：错误 session/profile/viewVersion、unknown build、未授权、已有人工 Profile、故意无输入 driver、断连中途 held、无安全 UI hook，必须触发明确拒绝/失败；不能只看命令退出 0。
- [ ] 先在隔离桌面跑 G1/G2/G3：原生 `<select>`/date/color/menu、fullscreen/PiP、pointer lock、系统 drag、文件/权限/认证/下载/外部 URL 等所有第 8 节入口都不能创建平台 UI/外部进程/下载/声音。
- [ ] 正式 AppleScript 入口重复 background/occluded/orderOut 各 3 轮：hover 与 CSS 下拉、离开、单/双击、checkbox 默认行为、Unicode、退格、密码/global Secure Input、range/text/custom-pointer drag、滚动、快照坐标、down/drag/up 按钮语义、cancel 不额外 click/drop。原 25 项不能删掉换成较弱检查。
- [ ] 隔离桌面用独立前台编辑器接收可预知输入；记录输入串等价性/无漏键/修饰键/输入法状态，观测物理鼠标位置和光标写入来源。生产输入零全局事件；观测器只读，不安装吞键 tap，不向当前用户前台 App 注入测试按键。
- [ ] 门禁通过后才做日常桌面补充验收：用户继续用自己的鼠标键盘，只有已验证安全 fixture 执行动作。未观察到实际外部键盘活动时该项记未覆盖，不推断“持续打字不受影响”；真实中文 IME 另列人工记录，不用 Unicode 测试替代。
- [ ] 报告列源文件哈希、App/Bundle 版本、WebKit、完整命令与退出码、每轮动作/不干扰检查、失败对照、时间上限、残余限制；退出后核对自有 Runner/通道/窗口/按住状态均已清理，截图按策略清除。主代理执行最终 source/diff review。

正式执行时的验证顺序（以下为**将来命令**，不是本轮已运行结果）：

```sh
cd /Volumes/RC500/dev/safarier
# 以下完整测试及两个 GUI 矩阵仅在隔离图形会话运行：
swift test
scripts/test-native-background-input.sh
scripts/verify-background-input.sh --prefix formal-native --rounds 3
# 在 G0 依赖已齐全的前提下构建；不执行安装：
SAFARIER_ARCH=arm64 scripts/build-app.sh
codesign --verify --deep --strict /Volumes/RC500/dev/safarier/dist/Safarier.app
# 新脚本必须先在隔离图形环境验证；未具备环境不在用户桌面强行执行：
scripts/verify-applescript-background-input.sh \
  --app /Volumes/RC500/dev/safarier/dist/Safarier.app --prefix formal-applescript --rounds 3
git diff --check
```

## 需求覆盖与停止点

| 设计要求 | 任务 | 不通过时 |
|---|---|---|
| 已有源代码/不叠加第二套实现 | 0、1、4、5、6 | 先缩小/重提设计，不覆盖原功能 |
| 一个 App、唯一 Manager 接收、冷启动不抢焦点、人工界面不回归 | 1、7、8 | G1 不放行 |
| 所有 UI 逃逸在展示前拒绝、无全局输入 | 2、5、8 | G2 不放行，未知版本 unavailable |
| Profile opt-in、精确目标、单实例代理隔离 | 3、4、6 | 关闭会话，不接管人工 Runner |
| lease/hold/EOF/cancel/重放安全 | 3、4、5、6 | 停送并只终止自有 Runner |
| 原生输入/截图/坐标/结果语义 | 3、5、7、8 | 报明确效果/错误，不谎报业务成功 |
| 脱敏与最小数据、私有截图清理 | 3、5、7、8 | 拒绝存储/请求，保留脱敏诊断 |
| 真正重复验证与其它 App 输入体验 | 0、8 | 不发布，不把静态检查当验收 |
| 只有主代理 review、不擅自交付 | 每任务 | 不分配 reviewer，不 commit/push/install/release |

主代理文档自检：C1–C8 与设计逐字一致；以上每项有落地任务；代码片段属于未来计划，不是新增运行实现；G0/G1/G2 的未知项是必须产出证据的停止门禁，不是允许落空的待补占位符。

**下一步：继续受阻的 Task 0。** 评估命令级诊断方案的正式支持边界，并准备兼容的真实 XCTest/链接环境；完整 Xcode 是候选，不是唯一前置要求。本轮没有验证独立 XCTest 的取得方式。下载/安装/修复全局工具链须用户另行批准，完整 GUI 基线仍需隔离图形环境。由 terra-worker 执行、主代理复核；不能跳过原测试或在用户桌面试危险 UI。

## 当前执行批次：先开发离线核心（2026-10-28）

用户明确要求“继续开发功能代码”。将 Task 3 的纯核心部分和 Task 4 的传输部分提前实施，不再等待完整 XCTest 环境才能写任何源码；不修改 C1–C8，不将 G0/G1/G2 标绿，不接入实际页面/系统输入。

- 已实现并复核：Task 3-core，强类型协议/严格校验/回执/幂等缓存与 Profile 默认关闭许可；GUI 编辑器或 Manager 装配未改。
- 已实现并复核：Task 4-channel，socketpair 私有数据通道、framing、有限背压、close/cancel；ProcessSpawning/RunnerMain/实际启动协议未改，尚未实际继承到 Runner。
- 测试：保留/补充原 XCTest 测试；另加直接运行真实 Core 代码的纯 Foundation 校验脚本，记录 RED/GREEN。它们不替代原 XCTest，全量回归/真实 GUI/发布验收仍未执行。
- 执行者仅 terra-worker；并行任务写集分离，主代理负责所有 review、组合构建和进度记录。禁止任何 GUI/App/全局输入、真实 Profile 数据访问、安装/下载或系统工具链改动。

### 本批次复核与验证记录

主代理独立组合真实全部 Core 源码，以静态模块跑 3 轮联合验收：每轮 340 项共享纯核心 checks、28 项共享通道 checks、71 条独立协议样例及协议/通道/许可组合检查全部通过。另单独重复通道脚本 3 轮通过。原 XCTest 框架没有被替换；正规 XCTest 仅保留并做语法检查，未运行或类型检查通过。

主代理发现并由 terra-worker 修复两项回归：success 回执不能 requestID=null；insertText/URL 重放身份不能误用 Swift String 的 Unicode 规范等价。修复前后 RED/GREEN 证据均保留。最终实际 Safarier main.swift 编译/链接通过（命令级诊断 overlay），未运行 App、未打包/安装/提交。详细报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-automation-core-implementation.md`。

下一批次继续原设计的启动协议/私有握手与安全策略接入；真正启动/页面输入前必须验证唯一 Manager 路由、UI 逃逸拦截和不干扰门禁。本批次没有授予全局输入或跳过旧测试的许可。

## 第二批：受控子进程与双向 RPC（2026-10-28，代码完成／真实 App 验收未完成）

用户同意继续下一阶段。继续使用 terra-worker 实现、主代理全部 review。

- 接入已有 RunnerLaunchSpec/RunnerLauncher/Workspace 的显式 backgroundAutomation 标志与私有 stdin；普通启动 API/参数/日志语义保留，旧 spawner 不支持受控 stdin 时必须明确报错，不能忽略通道降级启动。
- 在现有 codec/重复 key 预检上补 encodeRequest/decodeReply 与单独的严格握手 envelope；握手绑定 version、Profile、随机 nonce、Runner instance UUID 与实际子进程 PID。
- Manager 侧 pure Core client 使用已有 launcher/channel，限制单个在途 RPC，校验回复 requestID；断连/超时关闭自己的连接，不按进程名杀进程。
- 真实 Runner background 分支在 Profile/锁检查后、创建 NSApplication/WebView/代理之前进入明确 unavailable 的 Foundation 服务，只允许能力查询、所有页面动作拒绝；普通 GUI 分支不变。此时不承诺真实 App 冷启动已无焦点影响，不能在用户桌面运行该 App 验收。
- 用独立 Foundation 子进程 fixture 测 stdin 双向继承、execv、nonce/身份/版本错误、超时、EOF、回执关联与原启动兼容，不启动真实 App/GUI、不访问真实 Profile。
- AppleScript shipping 入口、sdef 打包与 Manager 激活生命周期本批次不启用，避免旧启动路径抢焦点；先提供可复用的 typed RPC 接口。

实现边界是原设计 Task 4/6 的无 GUI 通信部分，不放行 G0/G1/G2，不弱化旧测试，不新增全局输入或 JS fallback。

### 第二批完成与验证

- 双向 codec、nonce/Profile/Runner UUID/PID 握手、受控 stdin、背景启动标志、独立 Core client 和实际 Runner 的 unavailable 早分支已实现。普通启动路径保留；旧 spawner 不支持受控输入时拒绝，不会静默降级。
- 主代理复核发现并由 Terra 修复：回复按钮/viewport 值域、非法启动 deadline 先 spawn、变更动作结果不明却标 none；并将 busy 测试改为 helper 明确收帧标记，不靠固定 sleep。
- 主代理独立静态链接全部最终 Core 与 Foundation helper，3 轮联合均通过：340 protocol + 28 channel + 117 wire + 56 controlled-process checks。另 47 条回复样例、28 请求 roundtrip、16 握手/持续连接检查、5 个真实子进程坏握手拒绝和旧 71 条协议样例全部通过。
- 正式 main.swift/RunnerMain 编译链接通过（命令级临时 overlay）；未运行真实 App、GUI、原 XCTest、release 或安装。真实窗口/输入门禁保持关闭。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-controlled-runner-rpc.md`。

下一阶段接入 Manager 的非激活生命周期与 AppleScript 薄入口，并继续原 UI 逃逸/目标授权策略；不得将本批次 Foundation 进程验证替代真实 App 冷启动/唯一 Apple Event 接收者和页面验收。

## 第三批：单一 Manager 生命周期与脚本薄入口（2026-10-28，候选代码完成／真实 App 验收未完成）

- 将旧 ManagerApp.swift 的唯一启动所有者重构为 AppKit 延迟窗口生命周期，复用 ManagerModel/SafarierAppView；旧 SwiftUI App/Scene 启动所有者被替换，不保留双 Manager。原菜单动作/快捷键/禁用规则保留。
- 首次启动 accessory，不因 automation/unknown 意图建窗口或 activate；明确人工 open/reopen 才展示。自动化请求到达已显示的人工作业窗口时，不隐藏/降级现有 GUI。
- 启动状态机/菜单定义可用无 GUI spy 验证；不在用户桌面运行新的 Manager 或真实 Apple Events。实际事件顺序/冷启动/多实例接收仍为 G1 未验证。
- 新增严格 caller 证明、只读能力服务与 NSScriptCommand 薄适配、一次回复/超时/取消协调。生产只从当前 Cocoa Apple Event 的系统只读 sender EUID/PID/audit 属性复制身份，不信请求 JSON，不缺省信任。
- sdef 词典随源码/SwiftPM resource 注册；默认 build 不启用 NSAppleScriptEnabled，只有显式 scripting candidate 元数据模式才装配词典，且所有页面动作仍拒绝。Info 最早期 LSUIElement=true，不等于 G1 已通过。
- 新增 metadata-only 打包检查模式，只写明确指定的测试目录，不启动App、编完整包或覆盖dist。

执行仍为 terra-worker，主代理全部 review。任何对真实 App/GUI/AppleScript 冷启动的验收、安装或发布均不在本轮执行；完成代码不等于可以交付实际输入功能。

### 第三批复核与验证结果

- 主代理 review 后由 Terra 修复 caller audit 类型/EUID 高位、挂起命令退出回复、最后窗口自然排空退出以及 metadata-only 非法参数落入普通构建问题；RED/GREEN 证据保留。只有主代理执行 review。
- 最终全部 Core 静态组合连续 3 轮：每轮 340 protocol + 28 channel + 117 wire + 56 controlled-process + 59 script + 64 manager launch/menu，共 664 项通过。独立 coordinator 281 项和被动属性解析 39 项也各 3 轮通过；生命周期遍历 299,592 个 transition、metadata/sdef 32 项及旧 request/reply/握手反例全部通过。
- 实际新 Manager、脚本 adapter、资源以及原 main/RunnerMain 编译链接 exit 0，无 warning（命令级诊断 overlay）。未执行正式 App、Apple Events、GUI、输入或原完整 XCTest；XCTest 编译探针仍缺框架，sdp shim 也不可用。
- 正式报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-manager-script-entry.md`。Task 1/7 的源码落地不表示 G1/正式入口验收通过；默认 NSAppleScriptEnabled 不启用，候选 capabilities 仍 unavailable/unverified，其余页面操作全部拒绝。
- 下一批沿 Task 2/6 推进可注入的 UI 逃逸能力与目标/会话状态机，随后才是 Task 5 原生 driver 接入；未获隔离 GUI 证据前不放行输入，不用全局输入补偿。


## 第四批：UI 安全能力与会话状态核心（2026-10-29，离线核心完成／真实 UI 与进程接线未完成）

用户要求继续下一阶段，仍由 Terra worker 实现、主代理全部 review。先沿现有 Task 2/6 实现可注入、无 GUI 的策略与会话核心，不另起浏览器/服务/输入执行器。

Ruling: UI 策略/完整能力清单置于 SafarierCore，以供原 WebKit 配置工厂和后续原 BrowserSession 共用，并能不建 App/窗口地测试；不在 App 层复制同一策略。真正 WebKit/系统 UI hooks 的实测仍是 G2，未完成不可报告 active。

Ruling: 本批在原 WebViewConfigurationFactory 的新增显式 automationBackground 模式入口先硬拒绝，且必须发生在 WKWebViewConfiguration、DataStore、凭据及适配器调用之前；默认 interactive 路径保留。通用后台 UI 能力未验证，不能靠完整清单或测试注入的能力值创建真实 WebView。

Ruling: 会话机先复用现有 request/replay/token/target/viewport/error/limits 类型，实现串行调用者持有的纯状态与效果，不接入 AppleScript/真实 Manager/Runner、不启动进程、不真实读写 Profile。权限/目标事实和 monotonic time 由未来拥有者注入；测试中的授权事实不代表 OS/磁盘身份已证明。所有 actual page actions 仍拒绝。

本批主代理验证旧行为调用链、公开接口与能力缺口；编写独立状态/边界反例、重复组合验证、正式产品编译及范围检查。禁止 GUI/Apple Events/全局输入/真实 Profile、工具链变更、提交/安装/发布。

### 第四批复核与验证结果

- 完成 Core 共用的 47 类 UI 请求/53 项 capability 记录模型；原配置工厂新增默认 interactive 参数，automationBackground 在配置、DataStore、凭据和 adapter 前硬拒绝。普通路径内容保留；没有新浏览器或后台窗口。
- 完成串行拥有者的 SessionMachine：复用原 codec/token/replay/target/viewport/limits，lease/hold/cleanup 期限、优先取消、跨会话操作/清理 ticket、终态有界回执和完整坐标检查。仍无 native scheduler、实际权限重读或 Manager/Runner 接线。
- 主代理 review 后由 Terra 修复 unknown capability 被视为已知、跨会话票据碰撞、终态 ID/回复路由、截图坐标/状态不一致、无归属清理回执和冻结 replay 时钟。主代理独立行为 RED/GREEN 已保存。
- 最终全部 Core 联合连续 3 轮，每轮 1,135 checks；独立 session 356、policy 1,001、旧 coordinator 281、被动 adapter 39 各 3 轮通过。实际产品库对象链接的配置工厂每轮 8 类拒绝、凭据/adapter 0 调用，3 轮通过；旧 corpus/握手/metadata/生命周期反例也通过。
- 实际产品源码冻结后编译链接 exit 0，无 warning，未执行 App/GUI/Apple Events/输入。正规 XCTest 仍缺框架，wrappers 只语法检查；G0/G1/G2 不放行。默认脚本与全部真实页面控制继续拒绝。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-background-policy-session-core.md`；53 项真实 UI 证据均 unverified 的矩阵：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-background-ui-policy-matrix.json`。

Ruling: 终态稳定关闭回执只保留有界 UUID/close-kind/共享 Receipt；不冻结时钟、不延长活跃 replay lease，关闭时释放活跃 payload。允许已撤权、但 token/目标仍匹配的终态调用取回清理回执，不执行任何动作。后续拥有者需限制终态对象保留期。

下一批继续原 Task 2 展示前 UI 拦截和 Task 6 专属目标/受控链路的生产接线；不能因纯效果模型测试通过而声称真实 5 秒松手/退出或清理已生效，不能补发 mouseUp/click/drop 来伪造安全收尾。


## 第五批：原页面 UI 边界与异步会话控制器（2026-10-29，候选代码完成／真实页面与服务装配未完成）

用户要求继续，仍由 Terra worker 实现、主代理全部复核。复用原 BrowserSession/BrowserWindowController、Core policy/session machine 和现有 typed 协议，不新增浏览器、常驻进程或输入执行器。

Ruling: 本批将已有可安全表达的 JS 对话框/文件选择/媒体/新视图/下载/认证/外部协议等拒绝分支接到原拥有者，策略模式只从配置 Output 传递，默认 interactive；原工厂 automationBackground 硬拒绝保留，不提供 force/Boolean 绕过。未知的系统 UI/SPI、真实非激活窗口和原生完成栅栏仍不能据源码分支当作已验证。

Ruling: 沿 Task 6 新建 Foundation-only 的 RunnerAutomationController，实际消费既有 Machine effects，提供单在途异步分派、每请求授权/目标重核、独立 callback 路由、monotonic deadline 定时与有界 cleanup。驱动/授权读取/销毁均是必需的注入接口；不另写 native 事件引擎，不在 shipping unavailable 服务中实例化或放行。用无 GUI 调度器和 fixture 验证，不伪造真实权限、窗口或退出证明。

Ruling: 有效 token 的 cancel/close 为减权操作，可越过正在等待的异步授权/导航而请求自身目标收尾；不允许旧授权、旧回调、取消任务或失效 timer 触发新的 native dispatch。所有真实页面功能与脚本默认开关保持关闭，G0/G1/G2 不变。

本批不执行真实 App/GUI/Apple Events/权限提示/全局输入/JS 注入，不读真实 Profile 或改系统工具链，不提交/安装/发布。所有代码审查由主代理执行。

### 第五批复核与验证结果

- 原配置 Output 的只读模式传到 BrowserSession；在原委托/窗口/下载/认证/保存打印等拥有者接入拒绝。普通逻辑保留；分享/自动焦点的构造期静默抑制不制造交互事件。后台工厂 guard 未放行。
- RunnerAutomationController 实际消费原 session machine effects：异步事实重读/末次权限复核、ticket 与 invocation 路由、monotonic earliest deadline、失败关闭、有界 reader/call 额度、自身 cleanup 一次尝试。没有真实 native sink、Profile 读取或服务接线。
- 主代理 review 发现并由 Terra 修复排队取消/过期仍执行、末次许可过早读取、关闭后 reader 卡住、当前 sleeper 故障、过期未尝试 cleanup、取消 reader 无限占任务等问题。主代理原快照的 cleanup=0 RED 与最终 cleanup=1 GREEN 已保存。
- 最终源码 3 轮联合每轮 1,847 checks；独立 controller 67、boundary 225 各 3 轮通过，前批独立 session/policy/script/caller、工厂、旧协议/进程/metadata 反例均通过。正式产品冻结后编译链接 exit 0 无 warning（命令级诊断 overlay），未运行 App/GUI/Apple Events 或真实输入。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-background-ui-controller.md`。XCTest/默认工具链限制仍在，G0/G1/G2、默认脚本入口和真实页面服务均保持关闭；候选 UI guards 不等于 53 项真实能力已验证。

Ruling: 当前调度器失效是明确的 owner fault，允许 Core 新增 schedulingFailed 事件，保留原正常状态/重放语义；不伪造 monotonic clock，不静默丢 timer 或无限重试。已授权的自身销毁即使回执截止/owner 释放也尝试一次，迟到成功不修改既有 false 终态。

尚未完成真实窗口/对象 UUID、跨 Profile 注册/持久权限撤销订阅、native driver 和 own-process 退出证明。应用打印/分享/剪贴板门禁不代表对应网页引擎 API 已安全封住；不得因此移除 factory/服务硬拒绝。


## 第六批：唯一原生输入实现与安全截图存储（2026-10-29，候选代码完成／真实输入与服务接线未完成）

用户要求继续，仍由 Terra worker 开发、主代理全部 review。沿 Task 5 从原 NativeEvents 抽取原生事件/TLS/活动/completion 实现，probe real 模式复用，stub 与 trace 只在诊断适配层；不重写第二条真实事件执行路径。

Ruling: shipping NativePageInput 的生产 admission 保持 unavailable，与原 UI 工厂/服务门禁叠加拒绝。诊断探针只在显式 SAFARIER_NATIVE_PROBE 编译定义下获得构造入口，普通产品无诊断/force/stub 入口或 trace。该定义不是 G2，原探针此轮仅编译不执行。

Ruling: 原 probe.closeActivity 在 held 时补 mouseUp 的行为不符合正式取消设计，必须移除；不安全收尾报告需销毁自身目标，探针适配层处理自己的窗口，不能通过补 up 假装清理成功。真实 click/drop 负例仍待隔离图形验收。

Ruling: 截图编码与存储分离；原生 snapshot 只返回目标 PNG+既有 viewport metadata，Core 的私有文件存储使用受控目录描述符/0700/0600/O_EXCL/no-follow、8份/32MiB/4096边限额，只清登记且身份匹配的文件。无任意输出路径命令，不扫描删除陌生文件。

本批只跑无 GUI preflight、文件系统私有 fixture、旧 Foundation 流程和编译；不运行真实 App/探针/Apple Events/native event/cursor 测试，不读真实 Profile、不改工具链、不提交安装发布。G0/G1/G2 和实际页面控制保持关闭。

### 第六批复核与验证结果

- 原 NativeEvents 真实事件实现抽到 NativePageInput；probe fixed 转发、stub 留在适配层，诊断构造/trace 只在专用编译定义下出现。普通产品 admission 始终 UI_POLICY_UNAVAILABLE，实际静态门禁 CLI 已确认；普通/诊断全链接均通过，正常诊断符号0/探针9，未运行探针。
- Viewport.contains 只补在原类型上；固定输入、几何、按钮、文本/shift/滚动与完成门由真实路径复用。原 held close 的补 mouseUp 已移除，未知/未栅栏/按住保持自身销毁需求，不冒充已销毁。内存 snapshot 有有界一次完成/epoch，未实测实际像素。
- Core SnapshotStore 使用私有 UUID 子目录、0700/0600、descriptor/identity/no-follow/exclusive、ACL清除回读、有限 quota/TTL/重试与登记清理；partial retained 对象计入额度。不得对任意同UID并发路径篡改作绝对原子保证。
- 最终联合3轮每轮1,976 checks；主代理独立 native133/文件系统88各3轮，前批反例及旧RPC/metadata/启动检查均通过。正规XCTest仍缺框架，native/cursor/GUI/AppleEvents/输入矩阵未运行，G0/G1/G2不放行。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-native-input-snapshot-store.md`。下一步仍为真实专属目标/driver/store/通道接线与 own-process 收尾，再到隔离图形验收，不删除门禁模拟可用。

## 第七批：受控 RPC 取消通道与自身子进程退出观察（2026-10-29，候选代码完成／真实页面服务未接线）

本批沿 Task 4/6 补齐已有受控 Runner 连接，不引入第二套协议、session reducer 或输入执行器。源码基线为 mcc-safarier / 2f32d21248deaffd8c8c1152a39912aa46350c7e，199 个已有文件，保留前六批未提交工作及稀疏检出状态。

- A：既有 Client 的有界多请求/唯一 reader/requestID 关联，保留 cancel/close 容量；提取唯一受控 Runner server，原 unavailable bootstrap 复用。乱序回包、错误关联、取消和超时失效关闭；不能把取消请求排在已卡住的动作后等待。
- B：既有 Foundation Process 创建路径增加只能从本次真实 spawn 得到的 owned handle，串接原 onExit，拒绝 legacy spawner 降级；复用 Workspace 原参数/权限/锁/SAFARIER_HOME 规则。只观察退出，不按 PID/名称发送信号，不用旧锁/PID 文件认领进程。
- Main：独立分析/代码复核、故障反例、重复组合测试、普通产品编译和原 gate 回归。生产实现仍由 Terra worker 执行；无 reviewer 子代理。

Ruling: close channel 只是请求自身 Runner 停止的条件，不是 exit/目标销毁证明。退出回执仅来自被捕获的真实 Process 的 terminationHandler；超时/未观察退出保留未知，不返回 cleaned=true。失败握手也仅清理自己拥有的端点并有界观察该 child，不触碰其他 Runner。

Ruling: 所有并发额度有界，cancel/close 保留独立 admission；客户端只接受本连接/请求对应的已验证结果，不透明重试可能执行过的动作。服务 handler 为将来既有 controller 的接线点，当前生产 unavailable handler 不创建 WebView/NSApplication。

本批无实际页面执行、原生输入、App/GUI/Apple Events、真实 Profile 或安装发布；native admission、UI factory、Manager ScriptService 的原始硬拒绝均保持不变。实际目标/driver/store/Manager 接线及 G0/G1/G2 图形验收仍未完成。


### 第七批主代理复核与验证结果

- Client 单 reader、8+2 pending、分级 2+2 writer、requestID/结果/目标关联、取消标记与绝对 deadline 末次检查；4096 correlation tombstones，普通保留两个 cleanup ID，硬上限关闭自身通道。没有重试或替代原 replay/session scheduler。
- unavailable bootstrap 实际复用新 server；有界 handler/写队列和独立控制容量，EOF/取消不等待不配合取消的 handler，shutdown hook 一次调度不冒充清理完成。
- Foundation Process 原创建路径复用 owned handle/一次退出记录，原 onExit 保留；普通与 owned 共用 validation/Workspace prepare，旧 spawner 显式拒绝，无信号或 PID 文件认领。
- 主代理独立复现并修复 client 释放未关通道与 wire 坏包固定回复回归；另修取消/过期排队发送和关联预算拦住 cleanup。RED 日志保留，未弱化旧断言。测试驱动漏传 policy inventory 的错误已纠正并重跑，不是产品问题。
- 最终冻结源码联合三轮每轮 2,115 checks；主代理新独立 client/server/owned 每轮 52 checks、旧独立 controller/boundary/session/policy/script/native-preflight/snapshot/caller 各三轮通过。普通产品编译链接 exit 0 无 warning，实际普通产品早期拒绝 CLI 三轮通过，无 NSApplication/WebView/window。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-controlled-rpc-owned-lifecycle.md`。未运行实际 App/GUI/原生输入/Apple Events/正规 XCTest；未提交安装发布。真实 Manager/owned target/driver/store 接线及 G0/G1/G2 图形验收仍未完成，三个原生产硬拒绝不移除。

## 第八批：Runner 页面适配器与控制器／通道／截图组合（2026-10-29，候选接线完成／生产入口仍拒绝）

沿 Task 5/6 推进真实对象接线，不另造输入引擎、协议、重放缓存或 session reducer。基线 211 个已有文件，HEAD 仍 2f32d21248deaffd8c8c1152a39912aa46350c7e，保留前七批 dirty work。

- A：OwnedBrowserAutomationPage 将原 BrowserSession/BrowserWindowController/BrowserWebView/NSWindow 固定绑定；通过原 WKNavigationDelegate 的可选后台回调接收导航完成／失败／对象丢失，复用 NativePageInput 唯一输入与截图。专属背景对象创建先过原固定拒绝，再复用原 controller 创建，不调用交互 open/show/activate/makeKey。原普通浏览行为保留。
- B：Foundation-only RunnerAutomationPage contract、RunnerAutomationService 与 snapshot I/O owner，组合原 SessionMachine/RunnerAutomationController/AutomationRunnerServer/AutomationSnapshotStore；每请求真实权限重读、exact target/viewport、nonce instance 一致、取消/EOF/晚到结果收尾。Machine 仅补 readonly boundViewport，不修改状态语义。
- Main：所有设计和 code review、独立验证、失败反例、普通产品构建、原 gate 回归。生产代码 Terra 实现；不使用 reviewer 子代理。

Ruling: 导航在原 machine.begin 时已增加 viewVersion；页面适配器必须使用该同一 metadata，不能在另一处再加一次。匹配实际 WKNavigation 对象，不能劫持 navigationDelegate/UI delegate 或用固定等待伪造完成。

Ruling: NSWindow.close、detach、activity finish 不等于已销毁 WebView 或按住取消零 click/drop。当前无这类实证时 destroy 结果保留 false；Runner 不宣称已终止自身，进程退出仍由 Manager 的实际 owned Process 观察。

Ruling: 真实页面对象、原生活动、Profile/代理/数据存储创建都不得越过现有 gate。App background entry 在任何页面／artifact／额外权限读取前，仍先按固定 false admission 返回原 unavailable 服务。当前批可完成对象适配与组合候选代码，但不得将 injected Foundation fixture 视作 production 可用；未来许可/原 Profile proxy/config preparation 与完整 Manager 接线另行核验。

无 App/GUI/probe/native/cursor/Apple Events 执行，无真实 Profile、系统工具链或权限变更；不提交安装发布。NativeInputPreflight、WebViewConfigurationFactory、Manager ScriptService 三个原始硬拒绝保持关闭，G0/G1/G2 和非干扰图形验收不放行。


### 第八批主代理复核与验证结果

- 实际 OwnedBrowserAutomationPage 固定对象/UUID/几何，复用原 delegate 与唯一 NativePageInput；BrowserSession 专属创建和 service helper 接入原权限 repository/私有 store。创建前 gate 不变、无 key/activate，先隐藏 overlay/layout 再 attach；正常交互方法保持原路径。
- 初始 Opening 的取消/期限与晚到 factory 失败关闭；导航不丢失 sticky 销毁需求，等待真实旧 activity finish ack，重复 close 不伪造 ack，本地 deadline 覆盖整个导航且发布前重核。真实 destroy 永远保守 false，未补 up/click/drop。
- 联合回归发现 controller 完成竞态，授权最小扩展 RunnerAutomationController 的 CancellationFlag/最终 ticket claim 及对应旧 cases：主代理 RED100/100 stale success，最终100/100拒绝。open receipt ID 跨动作别名由服务单条 ledger 拦住，错误 token 优先，RED4/9→GREEN9/9，无第二套 cache。
- 最终 200 个 code files 冻结，联合三轮每轮 2,168 checks；主代理独立服务35/open races6/alias9/完成取消100次/关联9000次及前批回归各三轮通过。普通产品和诊断 probe 均编译链接 exit0 无 warning，probe 不运行；实际产品早拒绝/Entry 三轮通过且 NSApplication=nil。正规 XCTest 当前 CLT 仍缺模块，未执行。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-runner-page-composition.md`。真实 Profile/proxy/config/0700 artifactbase 准备、Manager registry/撤权通知/ScriptCommand 真路由仍未完成；Entry 两个分支都 unavailable，原 factory/native/Manager 三硬拒绝和默认脚本状态不变。
- 本轮无实际 App/GUI/probe/cursor/键鼠/Apple Events、真实 Profile、系统工具链或权限变更，无提交推送安装发布。G0/G1/G2 和非干扰图形验收不放行。

## 第九批：Manager 会话归属、撤权接线与可信 artifact base（2026-10-29，候选代码完成／默认拒绝与图形门禁不变）

沿已批准 Task 6/7 接入 Manager，并复用现有 SnapshotStore 路径验证准备固定目录；不引入新输入器、协议或物理状态机。基线为 mcc-safarier / 2f32d21248deaffd8c8c1152a39912aa46350c7e，224 个已有文件，保留全部前八批 dirty work。

- A：Foundation-only AutomationManager，复用既有 RunnerClient/owned Process、CallerProof、ReplayCache。caller UID/PID/opaque audit token 与 session/runner instance/完整 target 绑定；拒绝人工已运行 Profile，授权前和动作前持久权限重读。公开脚本路径的默认 admission 继续 false，capabilities 仍 unavailable，不能先读 Profile/spawn 再拒绝。
- B：SnapshotStore 增加 workspaceRoot 构造，在固定 automation-artifacts 子目录使用原有 descriptor/no-follow/identity 路径链。只对本次新建对象设置私有权限/清 ACL；既有不安全目录、ACL、文件、symlink 原样拒绝，不修改。Session builder 复用该构造，所有文件 I/O 仍在后台；固定 base 保留，多 session 只清各自已登记 UUID artifacts。
- C：原 ManagerApp/Model/Command/Hook 接线。保存/重载按完整 allowed-ID snapshot 通知 owned registry；Profile 读取失败 fail closed，其他数据读取失败不掩盖已读出的撤权。quit/pending 计入自有打开/活跃/收尾工作，不等待 terminal 历史；仍先向系统返回 terminateLater 再异步取消和收尾。脚本 intake 与未返回 handler 额度有界，保持一次 suspend/resume 和原 human UI 路径。
- Main：所有设计和 code review、独立反例、组合三轮、真实产品编译和实际 early-gate CLI。生产实现 Terra worker；不委托 reviewer。

Ruling: Manager 的 registry 仅认本次实际创建并握手的 endpoint/ownershipID，不认旧 PID 文件或按名称查找。cancel/close/撤权/quit 只关自己的通道、有界观察实际 owned Process；nil/迟到结果不冒充 cleaned 或重新修改已给出的 false receipt。没有进程信号、全局输入或补 mouseUp 的兜底。

Ruling: Manager 使用原 ReplayCache 避免因 Apple Event 重试再次发送动作（Client 原 tombstone 不允许重发），原生 lease/held 状态仍由 Runner machine 管理。历史回执重播不得使已经失效的远端 lease 永久存活；新 request ID 的有效状态查询才是可续期的真实 Runner 请求。初始 open 记录逐条有界，不能在 Manager 启动时建一份 30 秒后永久失效的全局 open cache。

Ruling: 初始身份比较只比较复制的私有 audit bytes，不解析或暴露其内部字段；测试 proof 为 synthetic，不等于真实 OS Apple Event 已验收。Wrong caller/token 不得读 Profile、转发或收尾他人的 session。

本批不启动 GUI、真实 App/探针/native/cursor/Apple Events，不读取真实 Profile，不变更系统权限/工具链，不提交推送安装发布。NativeInputPreflight、WebView factory、AutomationScriptService、Runner Entry 和默认脚本启用状态的原硬拒绝保留；实际后台 Profile/proxy/config 启动以及 G0/G1/G2/非干扰图形验收仍是后续门禁。


### 第九批主代理复核与验证结果

- AutomationManager 复用原 RunnerClient/owned Process/ReplayCache，绑定 caller opaque身份及 endpoint PID/instance/ownership；有界 opening/active/cleanup、截止时间、一次终态与迟到清理。正常 action 错误保留 possible，缓存前重读权限，关闭/过期不复活。绑定后才启 session cache，replay 满或过期不阻止授权收尾，未加第二物理 reducer。
- Command/Hook 到唯一 shipping Manager；Profile 保存/重载的完整 allowed-ID 快照在代理/订阅错误之前通知。Quit 合计自有工作且先 terminateLater 再取消，正常 human 路径保留。两层 intake254普通+2控制，取消未返回 handler 仍占容量，绝对 receipt deadline 不因调度延后重计。
- 固定 artifact base 由原 SnapshotStore descriptor walker 准备，只修饰本次新建对象；已存在不安全对象拒绝且不修改，支持安全只读 root ACL 并清新 base 继承 ACL。Session helper 改用 workspaceRoot 构造，legacybaseAPI仍兼容。
- 最终215 code files冻结；联合三轮每轮2,228 checks，主代理新 Manager11/目录29/scheduler4/真实 Foundation IPC8、实际 Model/Hook/shipping12及既有回归各三轮通过。产品/probe编译链接exit0无warning，probe不运行；CLI NSApplication=nil，正规XCTest当前CLT仍缺模块。C的4项延迟用例在私有副本插入调度延迟，不作为GUI/原生验收。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-manager-ownership-artifact-base.md`。独立cold=false与原native/Factory/ScriptService/RunnerEntry硬拒绝及默认脚本状态保留；实际后台配置准备/G0/G1/G2和53项真实UI/非干扰验收仍未完成。
- 保留224基线文件，215原文件不变，9限定修改，新增16（含报告）。无真实App/GUI/native/AppleEvents/真实Profile、系统权限或工具链变更，无提交推送安装发布。所有设计/code review主代理执行，三名worker实际Terra/high。


## 第十批执行契约（2026-10-29）：复用 Runner 配置准备，保持后台关闭

目标：从既有 RunnerMain 抽取唯一共享准备流程，正常人工/probe 也使用它；将 Profile/出站选择与运行时准备拆开以便无 GUI 验证，不创建第二套 Repository、代理解析或执行器。保留当前 mcc-safarier / 2f32d21248deaffd8c8c1152a39912aa46350c7e 与240文件dirty baseline。

- A（Terra）：Foundation-only RunnerPreparationPlan，注入已有 proxy/boundNode reader，验证身份和启动参数；缺失/不符代理不退直连，订阅优先规则复用原代码，synthetic测试不读真实工作区。
- B（Terra）：RunnerMain 原配置准备抽取并复用；factory 原 interactive-only 拒绝抽为共享 early guard，make 自身仍最早检查。背景入口复用准备与服务但 Native/Factory 各自硬门禁不变；NSApp 在门禁之后。控制 fd0 在可能自重启前只验证，不提前被 adopting 关闭；完成准备后才接管。
- Main：独立语义/实际链接门禁反例、全量既有纯逻辑回归三轮、产品/诊断编译（不运行），所有设计与 code review 由主代理执行。

Ruling: 既有 SingboxProcessManager.start 会 reapOrphan、修改 quarantine，不能直接给后台自动化使用。本批不新增第二套 sing-box owner 或修改正常人工行为；后台 subscriptionID 非空明确 BACKEND_UNAVAILABLE，禁止隐式直连。后台 follow-proxy geo（可能 execv/联网）与认证 Keychain（可能出现系统 UI）也在共享 plan 明确拒绝。它们属于尚未完成的后台启动功能，不以候选准备流程冒充支持。

Ruling: 不开放 NativeInputPreflight、WebViewConfigurationFactory、Manager coldLaunch、默认脚本门禁；原 profileID/channel Entry 的 unavailable 兼容接口保留。实际 Profile/proxy/config/GUI/AppleEvents/输入/游标不执行，不安装工具链、不修改权限、不提交推送安装发布；只在私有 synthetic 文件和 Foundation 子进程验证。正式 G0/G1/G2 与53项真实UI仍未通过。

验证范围：启动参数/读取顺序/失败传播/不降级直连/普通路径兼容；实际链接 prepare 与 Entry 早期拒绝且 NSApplication=nil；冻结源码后既有联合/独立用例三轮；普通产品与诊断产品编译及符号隔离；baseline/sibling/稀疏文件保全。

### 第十批主代理复核与验证结果

- 原 RunnerMain runtime preparation 抽为唯一 RunnerPreparation，人工/probe与后台候选都复用；Core plan只注入原Repository/boundNode，丢失代理/错身份不降级直连。保留原人工Geo/订阅和cleanup实现，旧Foundation Service字节不变。
- 主代理复核要求恢复后台授权guard、给服务构造自身加Native/policy/许可guard、绑定spec与执行policy，并通过独立RED发现空username仍会触发原factory凭据读取；Terra修为后台任何非nil username均拒绝。背景订阅和followGeo明确不支持，未偷用旧PID reap/凭据弹窗/直连。
- 冻结222 code files；联合三轮每轮2,276 checks，新共享48，主代理独立20/真实Repository10/实际链接准备与丰富Entry28各三轮通过，NSApplication均nil。产品/诊断编译无warning，诊断不运行，正常诊断符号0 vs诊断5。既有逻辑/IPC反例三轮通过，metadata32，source15。完整XCTest仍因当前CLT缺模块未执行。
- 如实保留一次独立service fixture异步storage完成观察不正确的失败及一次新fixture编译错误；只修证据fixture，产品Service不改。原1秒有界条件同时观察page/storage后，三轮+20次通过。
- 本批240基线文件237不变、3限定修改，新增7代码测试脚本+报告。工具链5保护hash、xcode-select、相邻checkout、10缺失资源保全；未运行真实App/GUI/native/probe/AppleEvents/真实Profile/Keychain/网络，无系统权限变更/提交推送安装发布。实际worker仍Terra/high；review仅主agent。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-runner-shared-preparation.md`。Native/Factory/Manager cold-launch/default scripting门禁保持；候选成功分支的AppKit事件循环与真实G0/G1/G2/非干扰验收未通过。下一步只在原模块完善后台安全代理/凭据/Geo准备，不另起平行执行器。


## 第十一批执行契约（2026-10-29）：无交互凭据派发与 Geo 总预算

范围：沿用已批准设计与第十批共享准备；本批在原CredentialStore/KeychainCredentialStore、WebViewConfigurationFactory、ProxyGeoResolver内实施，不另建凭据或网络管理器。基线 mcc-safarier / 2f32d21248deaffd8c8c1152a39912aa46350c7e，248个已有文件。

- A（Terra）：CredentialStore增加passwordWithoutInteraction协议能力，默认拒绝且不fallback普通getter。Keychain仅Data Protection查询、每次新LAContext禁止交互，内部注入Security read供无真实Keychain测试；原普通read/write/delete保持。
- B（Terra）：原Geo解析顺序提取共同内核，保持旧API/旧curl行为，新增absolute monotonic deadline预算重载，逐次削减fetch预算并拒绝迟到success/nil/时钟异常/取消；显式fetch参数，不能默认旧curl假称严格wall-clock中断。
- C（Terra）：原factory唯一proxy凭据派发helper，人工沿用旧getter，后台只新getter、缺失/不支持均INTERACTION_REQUIRED，不把nil当密码继续。Core plan允许只规划认证代理元数据（不读取凭据），后台订阅与followGeo仍拒绝。Factory原hard gate不放开。
- Main：全部设计与代码复核、独立counterexamples、实际对象链接无GUI派发、既有联合与独立回归三轮、产品/诊断编译与源码/工具链保全。无reviewer子代理。

Ruling: 本地SDK SecItem.h1016-1020明确legacy Keychain项即使no-auth-UI也可能出现UI；LAContext.h343-346的noninteractive效果须结合Data Protection域。因此禁止无交互方法回落旧域；不自动迁移/复制/写入用户密码。已存在普通钥匙串凭据不能据此宣称后台可用；DataProtection项缺失明确失败，后续迁移需单独人工授权流程。

Ruling: Geo新API只提供合作fetch预算记账和迟到结果拒绝，不能强制中断任意同步函数。本批不改/不跑真实curl，不声称已完成后台Geo进程/execv总墙钟上限。旧sing-box按PID/quarantine操作仍仅人工路径，后台订阅仍不支持，不暗增owned-only第二套owner。

Native/Factory/Manager cold-launch/default script所有门禁保留。真实App/GUI/native/probe/cursor/AppleEvents/真实Profile/Keychain/网络不执行，不改系统权限工具链，不提交推送安装发布。

Ruling: 首次联合回归在旧OwnedRunnerCases的before-first-waiter setup失败，原case只poll500次1ms且未记录首次snapshot，不能断言单次原因已复原。生产OwnedRunner/Launcher不改；独立12次自然退出观察成功。测试改用已有真实onExit Observer做同步，在绝对monotonic3秒setup预算内收到实际退出后，再原样验证首次owned waiter前缓存status7。没有延长任何产品超时或把断言改为skip；此最小测试同步修正交原Terra B实施，主agent复核，并完整重跑三轮。

### 第十一批主代理复核与验证结果

- 复用原CredentialStore新增无交互requirement且default failclosed；Keychain仅DataProtection+每query新禁交互LAContext，结束invalidate，不回退旧域、不迁移写入；原人工read/set/remove函数不变。真实Keychain未执行，现有legacy凭据不因此变得可用，供给流程仍须人工授权。
- 原Factory唯一proxyPassword派发：人工非nil username仍旧getter，后台非空username仅安全getter；缺失/不支持INTERACTION_REQUIRED。按原ProxyConfigurationBuilder无认证语义，后台nil/empty username均零查询，代理仍保留。Core plan允许认证元数据但未放行实际配置，订阅/followGeo guard保留。
- Geo原解析/locale/hint/curl不变，共享kernel添加绝对monotonic总预算重载，显式fetch、迟到/取消/异常时钟拒绝。不能强制中断不合作同步fetch，不声称旧curl已有严格墙钟/真实后台exec支持。
- 首次联合旧Owned测试before-first-waiter失败，原输出无snapshot，单次原因不能确认。仅测试setup改为等实际Observer回调（3秒绝对上限），保留原断言，不改产品预算。生产退出源码不变、独立12次自然退出成功；失败/旧hash/调查记录均保留，修正后完整三轮通过。
- 冻结233 code files，联合三轮每轮2,340 checks（preparation46、新credential27、新Geo39），独立query43/Geo30/prep20/Repository10各三轮。实际产品链接helper30、共享Core27+WebKit18、旧prepare/Entry/Model/Factory等各三轮通过且NSApp=nil。正常/诊断编译无warning，诊断不运行，正常诊断符号0 vs诊断5。XCTest当前仍缺module，仅wrapper parse与standalone cases验证。
- 248基线中241不变，7限定修改，新增11测试脚本+报告，零新增生产实现文件。原10缺失资源/sibling/工具链5hash/DeveloperDir保全；未读真实Keychain/网络/Profile或运行GUI/native/probe/AppleEvents，未提交推送安装发布，未改权限/门禁。三名worker实际Terra/high，review仅主agent。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-noninteractive-credentials-geo-budget.md`。后续仍需原模块内owned代理生命周期/安全凭据供给/真实Geo与重启，再做隔离GUI输入非干扰验收；不能以本批查询构造/派发通过替代真实OS门禁。


## 第十二批执行契约（2026-10-29）：既有网络 owner 的后台安全启动候选

基线 mcc-safarier / 2f32d21248deaffd8c8c1152a39912aa46350c7e，260个已有文件。沿用用户确认的后台启动/收尾方向；不新增第二套管理器或生产helper。实现由Terra，所有设计与code review主agent独立完成。

- A：原OwnedRunnerProcess添加只针对retained Process的一次termination request、真实isRunning与仅该child的loopback TCP LISTEN只读核验；原FoundationProcessSpawner复用spawnProcess增加显式stdio owned overload，旧API语义保留。无PID重建/进程名/全局扫描/SIGKILL。
- B：原SingboxProcessManager增加owned路径，复用原ConfigBuilder/port及Core真实Process handle。专属匿名pipe stdin传配置，stdout/stderr null、最小env；不写state/config/pid、不clearQuarantine/reap、不动旧state。monotonic启动预算、部分write/背压/取消、actual owned listener归属、身份绑定与有界观察退出；未观察退出不假cleaned，不释放仍占用的profile。旧人工路径保留且不能通过旧stop对owned走PID终止。
- C：原RunnerPreparation拆共享配置组装供正常与async背景候选，禁止背景误走同步legacy startSingbox；资源聚合持有manager/完整owned identity，准备失败/取消/EOF/退出有界close，nil不冒充退出。Core plan允许正确订阅元数据但验证binding/节点归属，不对缺失/错误binding回退直连；followGeo仍拒绝。rich Entry复用原service并在返回前关闭本次资源。
- Main：先读原实现、上游固定v1.14.4与SDK libproc契约；独立实际Foundation子进程/错身份/foreign port/取消/超时反例、实际产品链接early gates、全既有逻辑回归三轮与正常/诊断编译。

Ruling: 固定上游cmd_run.go readConfigAt支持配置路径stdin；背景用专属配置pipe代替旧秘密文件，从根源避免新目录/ACL清理与密码落盘。规格“子进程stdin=null”的安全目的为不继承自动化控制连接；已有curl本就使用专属stdin配置pipe，此处同样显式替换stdin，记录这一限定，不传原控制fd。原控制fd只在可能重启前validate，之后adopt；本批followGeo仍不启用。

Ruling: 仅能connect到本地端口不构成归属证据。Core只对本次retained child PID查询有界FD socket信息，检查IPv4 127.0.0.1/TCP/LISTEN与端口并复查child仍running；查询失败/未知拒绝。不全局扫描PID/名称，不收养。

Ruling: Termination request不是已退出证明；有界观察nil保持未知。SIGKILL/父崩溃后的child存活不能靠本实现自动保证，因此仍需隔离G3实测，不准借旧PID或SIGKILL兜底。所有Native/Factory/Manager cold/defaultscript门禁保留，不因owned管道用例通过而宣布订阅/后台输入已经可用。

仅运行新编译且本次创建的CLI fixture子进程与localhost监听；不运行真实singbox/代理外联/Keychain/Profile/App/GUI/native/probe/AppleEvents/光标或按键操作，不改系统工具链/权限，不提交推送安装发布。配套工具链与隔离图形环境仍是后续真实最小闭环的前置条件，本轮不拿日常桌面替代。

### 第十二批最终收口（2026-10-30）

- 中断前冻结248 code files，联合3轮每轮2,429 checks；本轮重新核对hash和保存退出码，未冒称重跑。新owned child26/proxy55与preparation54已纳入；主代理独立proxy18、实际App链接startup80/shared watcher70各3轮通过且NSApp=nil。正常/诊断编译无warning，诊断未运行；XCTest仍缺模块，完整GUI未验收。
- 原owner内实现独立stdin配置、真实child监听归属、全identity、starting取消、共同绝对收尾预算、稳定未知回执；原人工生命周期恢复兼容。私有控制HUP在prepare期间取消且不消费hello。Native/Factory/Manager/defaultscript不放开，未跑真singbox/用户Profile/Keychain/GUI/真实输入。
- 初次actual harness先shutdown再要求connected watcher构造成功而invalidSocket；阶段标识确认后只修fixture，生产不放宽检查。失败、诊断与修正记录保留。owned wildcard监听负例为本次自建fixture，不是隔离图形验收；父崩溃/ignoreTERM/真正代理功能仍未被证明。
- 收口审计154项通过，260baseline有251不变/9限定修改；15新测试脚本+报告，零新生产文件。5工具链hash/DeveloperDir/sibling/10缺失资源保全，无提交推送安装发布。详细报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-owned-background-startup.md`。


## 第十三批执行契约（2026-10-30）：先封住误运行图形验收入口，再做 G0 预检

基线276已有文件，包含已收口第十二批。主agent已确认原verify入口在参数解析前运行native/build，matrix/run也能直接打开probe。复用原三脚本：默认拒绝GUI，无副作用help；预检只探测默认manifest/XCTest与工具路径版本，真正UI需操作员explicit隔离确认，但flag不构成环境/门禁证明。实现Terra，code review仅主agent。

范围：scripts/verify-background-input.sh、scripts/background-input-probe/matrix.py、run.py；新增脚本安全测试。无新验证框架，不改生产Sources/Package/原App打包或admission，不装Xcode/SDK/虚拟机、不修改系统权限。旧诊断run的LaunchServices/PID清理未改，须标注非正式G1/G3证据，不能当成owned生产退出验收。

主agent并行真实无GUI检查默认swift package dump-package、typecheck import XCTest、DeveloperDir/sdk/compiler。--preflight不能执行swift test/发现测试/运行任何probe/打包签名；全部预检绿也至多unverified，不授予完整G0/正式接收者/UI/noninterference。不得用manifest overlay假称系统已修好。

TDD使用私有mirror与stub/mock拦截native/build/open，禁止为获得RED实际跑旧GUI入口。invalid/noargs/help在所有mkdir/subprocess前决定；UI授权路径只以stub验证forward，当前桌面绝不运行。新report须保留diagnosticOnly/formalAcceptance=false/shippingAdmission=false；isolation确认不是自动验证。


### 第十三批最终收口（2026-10-30）

- 复用原 verify/matrix/run：无参数/非法参数/help先决定，无隐式native/build/open；新增非GUI `--preflight` 与显式 `--isolated-ui`，后者仅操作员确认、不是隔离证明。原LaunchServices/PID清理保持diagnostic，不授予正式G1/G3或G2/G5。
- Terra/high实现、主agent两轮code review；冻结249 code files，主agent三轮各10方法 + 独立40检查通过，UI/native/build在私有mirror中全部stub或拦截。bash/AST检查通过。第十二批2429×3为已保存历史证据，本轮未重跑。
- 实际新preflight退出1：当前CLT Swift6.3.3默认manifest PackageDescription链接缺符号，import XCTest缺模块；四项工具路径/版本探测通过。未使用用户manifest override，未跑swift test/App/probe/真实输入；G0仍blocked，G1-G5未验收，全部shipping门禁关闭。
- 276baseline保留、仅3入口与计划4处已有修改，新增安全测试+报告2处，生产Sources/Tests/Package/打包脚本不变。工具链5hash/DeveloperDir/sibling/10缺失资源保全，无提交推送安装发布。下一步先配套工具链及隔离macOS，不在日常桌面运行UI旗标。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-background-verification-preflight.md`。


## Xcode 安装后本机 G0 复核执行契约（2026-10-30）

用户已取消虚拟机并自行安装/接受 Xcode 27.2（27B52）许可。以安装后的279文件为新基线，系统已选Xcode由用户安装改变，本轮不得改回CLT或继续VM。主agent只执行无GUI预检及build-only，限定2 jobs/独立scratch-cache，不运行swift test/发现测试/App/probe/AppleEvents/真实输入，不动任何Native/Factory/Manager/defaultscript门禁。

实际发现默认manifest已pass；旧预检bare swiftc误报XCTest不存在。相同Xcode编译器追加由MacOSX平台取得的-F Developer/Library/Frameworks与-I Developer/usr/lib，import XCTest已exit0。Terra只修原matrix预检并补原entry-safety回归（先RED再GREEN），不能替换XCTest、硬编码本机路径、用overlay或放宽状态。平台解析/路径缺失/错误或CLT不完整必须fail-closed，不接受任意相对/多行stdout为搜索目录。

限定已有实现修改：scripts/background-input-probe/matrix.py 与 scripts/automation-core-tests/test-verification-entry-safety.py；主agent负责code review和独立实测/文档。不新增生产模块或验证框架；compile测试目标不等于运行测试。checkFirstLaunchStatus实测exit69且无输出须如实记录，不宣称整套Xcode初始化完成。G0完整测试/打包签名与G1-G5仍待独立证据。


### Xcode 本机 G0 复核收口（2026-10-30）

- 用户已取消VM并自行安装/许可Xcode27.2，当前Swift6.4.2；默认manifest通过。发现旧bare swiftc缺测试框架路径而误报XCTest，主agent独立追加平台-F/-I实测通过，Terra在原matrix内修正并扩充原测试，主agent两轮review。
- 冻结249 code files；主agent三轮各15方法+独立42检查通过；真实preflight三轮每轮7探测exit0、状态仍unverified，GUI/fulltests/formal/shipping均false。无overlay/伪造组件/新框架。
- 原Debug/Release和全部4 XCTest targets均build-only通过，2jobs/私有scratch-cache，无warning/error；裸产品arm64签名校验通过。没有执行任何Swift测试本体或产品、原App打包签名链、GUI、真实输入。177 Sources/Tests与Package/打包/门禁不变，未提交推送安装发布。
- checkFirstLaunchStatus初末均69且无输出，已更正初次无stderr即当作通过的口头表述，不宣称整套Xcode初始化完成，未代执行sudo/runFirstLaunch。下一步需用户允许出现测试窗口的时间段，再进行完整测试和正式页面无干扰验收；不再要求VM，也不在日常操作时强行跑旧GUI测试。
- 报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-xcode-g0-build-only.md`。历史CLT报告保留，不改写先前失败证据。


## 本机原完整测试执行契约（2026-10-30）

用户已明确允许本轮出现/激活测试窗口；该许可不等于授权全局输入、真实Profile、凭据或恢复VM，也不自动证明隔离门禁。以280已有文件为基线，主agent先核对原测试仅自有临时workspace/随机DataStore与InMemory凭据，无全局输入调用；使用私有短路径fixture、显式配置原standalone helpers，执行原swift test（不filter/删测试换绿），2jobs/不并行。保留真实跳过/失败与原因，ManagerLifecycle显式Skip及OS/SPI条件Skip不能冒充验收。

仅依据实际失败在原模块内修复，由Terra实现、主agent独立review；不新增输入兜底或改变shipping门禁。若原测试/页面探针挂起，仅终止本次创建并持有的进程，不按名称清理他人进程。原打包若执行仅写独立App路径、不安装不覆盖旧产物；诊断bundle和正式receiver验收必须分开，当前专用测试时段不冒充隔离桌面与持续人工输入证据。


### 本轮已定位失败与限定修正范围补充

首次337 tests失败中的ArtifactBase/RunnerService来自本次测试夹具/tmp符号链接，不改生产SnapshotStore；改用本次创建的/private/tmp真实短路径后2定向tests已通过。字体原test的no-op假设由Terra仅在FontAllowlistPlannerTests.swift修正并补确定性fixture，生产planner不改。

复跑一轮338 tests通过、第二轮捕获BrowserFixesTests的真实.invalid DNS加载超时抖动；限定Terra仅修该测试的失败来源为自有、保留绑定且不监听的127.0.0.1端口，保留真实WebKit导航/错误页/后退断言，不skip或改生产导航。原vendor脚本已在私有镜像抓到Mac Bash3的$arch后紧随全角括号、$VERSION后紧随全角逗号被误作变量名；限定在原scripts/build-singbox.sh加变量边界，并新增离线stub shell回归，不改版本/依赖/flags/许可证/输出协议。源依赖只在私有目录编译，不安装或启动真实代理。


### 本机原完整测试与安全诊断结果（2026-10-30）

- 用户批准本机测试窗口时间，不恢复VM。修正自有/tmp夹具为/private/tmp真实路径，未放宽SnapshotStore。Terra仅修两个原测试（Font合法no-op分支、Browser真实DNS改自有TCP reset且CLOEXEC），原断言保留；bind但不listen在Darwin超时的失败尝试已撤回留档。原vendor脚本仅四处变量边界修复，新增离线shell回归2方法3轮通过。
- 原全量XCTest最终三轮每轮339 entries=336pass/3原条件skip/0fail；四个目标均真实执行，原helper全部配置，真实固定v1.14.4 vendor也已编译并跑config/lifecycle本机测试。原App打包脚本在源码hash镜像执行、arm64包及helper签名验证通过，默认脚本metadata关闭，未启动/安装正常App。初始失败、一次旧DNS flaky失败均保留，不用Swift Testing 0tests/XML空结果冒充XCTest。
- 原fixed/background页面诊断24/25功能检查通过，安全项单帧cursor TIFF hash变化未归因（208样本1帧，初末同、位置/前台不变、自身全局事件0、激活false、外部输入0），后续正向矩阵停止。额外只读observer+原判断不变的保存TIFF副本一次对照25/25，外部1200样本NSApp nil/单hash，但未重现不等于已解决；原guard/checker与生产门禁均未改，safety仍blocked。
- 不声明G1-G5通过或持续人工输入无干扰，FirstLaunch最终69未代sudo初始化。下一步只先归因cursor异常，不能忽略它去开放控制。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-full-xctest-native-safety.md`。


### 本机 cursor 异常归因结果与下一修复边界（2026-10-30）

- 本轮捕获与旧异常相同 hash 的原 TIFF，实际是带绿色加号的复制拖拽 cursor；共同尺寸非透明像素确实不同，不允许忽略 metadata/坏帧放行。独立原逻辑按钮查询 10 轮/50 样本未复现，不能简单归咎查询本身。
- Terra 仅在私有证据目录实现 pre-App、固定公开 drag selectors 的 fail-closed 诊断 helper/原 probe 副本；主 agent 全部 review、逆变换校验、编译/签名及 dummy 回归三轮通过。没有产品源代码修改、没有全局输入或光标恢复。
- 主 agent 连续三个自有后台 probe 都捕获 WebKit::startDrag → legacy dragImage，receiver=BrowserWebView、appActive=0，发生于 held_state_is_process_local 后 11.74–22.46ms；原方法前主动 exit71。每轮只完成前15检查，不是25/25或完整矩阵通过。外部每轮1200采样NSApp=nil，其中两轮全部14类×2状态计数零变化、32按钮未按住、cursor基线稳定仍触发此入口。
- 已确认真实系统拖拽逃逸缺口；旧帧没有原调用栈，不冒称直接回溯了全部因果。原systemDrag仅catalogue、NSCursor保护不足；人工输入存在时原oracle允许cursor变化，也不能据25/25放行。
- 下一批沿原Task2/5/8实现专属后台目标的drag-source展示前拒绝和既有cancelAndSuspend/owned lifecycle接线，不把诊断_exit直接复制为产品补丁；legacy/modern均需证明，nonnull不能nil/fake，不能安全取消则保留能力false。先负例/人工模式回归，再原25项/矩阵/真实并行输入；Native/Factory/defaultscript仍不开放。
- 证据与具体边界：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-cursor-drag-attribution.md`。归因与正式修复分开，无提交、推送、安装或发布。


### Legacy 系统拖拽拒绝执行契约（2026-10-30）

用户继续后，在现有Task2/5/8内修复已复现的legacy void入口，不增加另一套输入器。基线283已有文件，Terra实现、主agent唯一code review。复用BrowserWebView/BrowserWindowController的原session UI策略：legacy drag先查询session.allowUI(.systemDrag)，后台deny不调用super，人工模式保持原实现；弱owner丢失deny。OwnedBrowserAutomationPage.block先同步closeActivity，再通知既有controller/cleanup，避免异步取消前继续送入。

严格范围：BrowserViews.swift、BrowserWindowController.swift、OwnedBrowserAutomationPage.swift及定向回归；不改Factory/Native/defaultscript准入、不增加进程swizzle或直接_exit产品路径、不补mouseUp/drop、不注入网页脚本/DOM事件。modern nonnull session入口本批未获得安全取消证明，不以legacy局部修复声明systemDrag能力完整。

先RED/GREEN与主agent定向/全量原测试，再以保留原25判断的私有diagnostic probe做enabled负例/disabled对照，外加pre-App入口tripwire和外部只读observer。enabled允许用私有callback注入现有BackgroundPagePolicy，仅证明真实legacy override拒绝与原Native driver静止；不能冒充Factory/OwnedPage/AppleScript正式闭环。原25若提前终止明确记未完成，不删除或换绿；现代入口若命中仍由诊断tripwire安全退出而非生产支持。

本批实现中发现SDK将legacy方法标为Swift unavailable，直接override/super不可编译，失败已留档；按Task2既有“必要固定bridge扩展”范围，限定授权SFRRuntime.m/头文件及原NativeInput回归。使用typed fixed-selector bridge仅class_addMethod至BrowserWebView自有类、完整ABI与owner检查，缓存继承原IMP；后台permission false不调用原方法，人工permission true沿原IMP，不改NSView/NSWindow方法、不加新输入路径。Swift只提供固定@objc许可方法。安装/回读失败不开放后台，人工不因候选能力缺失而abort。


### Legacy 拒绝候选收口（2026-10-30）

- 已在原ObjCbridge只对BrowserWebView本类安装固定typed legacy void入口，完整ABI/own与permission/继承IMP校验；不替换NSView/NSWindow。Controller弱绑定原session.allowUI(.systemDrag)，owner丢失deny；原OwnedPage.block先closeActivity再通知既有owner。不复制诊断_exit、不加执行器。modern nonnull仍未解决，systemDrag能力不完整。
- Terra实现、主agent独立复核。原native bridge最终58checks主agent三轮通过，保留原30项与新增typed参数转发/拒绝/owner漂移等负例。新增4项XCTest、原全量三轮各343entries=340pass/3原skip/0fail。x86_64 ObjC仅编译、不运行；无VM。
- 私有原判断不变probe的disabled对照仍命中外层tripwire exit71；enabled连续3轮本类先拒绝真实legacy调用、原driver停止，未触发外层方法、无后续up/drop，原allPassed=false且只完成15功能项。不是25/25或完整矩阵通过；同步ready=false不冒充finish ack，诊断policy注入不冒充正式Factory/OwnedPage闭环。各轮外部活动存在，cursor变化保留，不宣称G5。
- Factory/Native/defaultscript门禁未改，无提交推送正常App安装或发布。下一批继续现代源入口安全取消与正式会话收尾闭环、完整页面矩阵和真实并行输入，不依赖全局输入/光标恢复。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-legacy-system-drag-guard.md`。


### 现代 drag-source 与断链静止执行契约（2026-10-30）

基线285文件，继续原Task2/5/8，Terra实现、主agent唯一review。主agent读取Apple官方event/gesture Doc JSON并存入本批modern-api证据目录：event Swift签名非可选但Return Value明确无法启动可返回nil；gesture同样允许nil且签名nullable。故此前“event非空标注意味着连ObjC拒绝也不能nil”的推断过强，本批在ObjC id层使用文档约定的启动失败nil，不造session、不通过Swift非可选返回、不放宽发布门禁；不以文档代替本机ABI/调用验证。

沿既有单一class drag bridge扩充固定event与runtime存在时gesture入口，统一完整ABI/owner预检、后台permission拒绝不calloriginal、人工精确转发；不加第二套hook/owner或改NSView/NSWindow。正式service增mandatory同步quiesceInput委托原closeActivity，按full identity fenced，对active/已采用opening页在shutdown与serve返回前先stop，原cleanup仍不等于销毁证明/finish ack；保留原绝对预算和原控制器。

先行为RED/GREEN及主agent独立原service/native/fullXCTest，再有外层固定入口tripwire的私有ObjC现代调用负例，nil仅转BOOL给Swift；原25/allPassed保留，组件否决不冒充完整网页矩阵。gesture本机若缺失明确未运行，不造host能力。Factory/Native/defaultscript仍关闭；无VM、全局输入、假session、_exit产品补丁或提交发布。


### 现代event拒绝与断链同步静止收口（2026-10-30）

- 根据Apple官方event Return Value明确允许无法启动时nil，纠正先前仅按Swift非可选签名判断不能ObjC拒绝的过强假设；沿原单类bridge加入modern event与runtime可选gesture，固定完整ABI/own/permission/继承IMP统一校验，nil只在ObjC、Swift只接BOOL，无假session/_exit/平行执行器。gesture公开selector由主复核纠正为gesture:，独立RED/GREEN防自洽假绿。
- 原service增加mandatory同步quiesceInput→原Native.closeActivity，active/已采用opening页full identity fenced，在shutdown及serve返回前停止，原cleanup预算不变。行为RED复现同步stop缺失；real AF_UNIX EOF与fake pending action等保留原检查，停止不冒充destroy/finish ack。
- 主agent独立native三轮93checks、service三轮63checks、原完整XCTest三轮各343entries=340pass/3原skip/0fail，helper27类型用例和x86 ObjC仅编译通过。新增native隔离fixture用posix_spawn/exec，未关fork safety。
- 实际event组件enabled连续3轮返回nil且先policy拒绝、不call原系统方法，停止后无新native事件；disabled对照仍外层tripwire exit71。原WebKit legacy另1轮拒绝回归。原25均只完成15功能项/allPassed=false，组件调用不冒充现代WebKit正式闭环；本机gesture缺失未GUI验证。
- 外部采样读数保留，enabled外部活动存在不宣称G5。Factory/Native/defaultscript保持关闭，无VM/全局输入/恢复鼠标焦点/提交发布。下一批处理允许的页面内drag/held原矩阵及正式会话收尾/AppleScript与真实并行输入；报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-modern-drag-and-quiescent-shutdown.md`。


### 页面内拖动夹具归因与原矩阵恢复契约（2026-10-30）

基线286已有文件，Terra实现、主agent唯一review。本轮先用原NativePageInput/原SFRRuntime与未改变原25判断的只读fixture观测；连续2轮确认宿主WebKit不支持user-select:none、仅prefixed支持，customdrag实际computed -webkit-user-select=text。首次drag把节点1→12的11字符选中，后续出现trusted dragstart(text/html,text/plain)，产品guard正确拒绝，非执行器误升级的证据。未发送CGE全局事件，未读取CG getter的新观测副本实际未链接。

限定修正仅原fixture #customdrag补-webkit-user-select:none并保留原声明，不加user-drag:none/preventDefault/清选区；原custom-pointer检查保留moves>0并加强custom内selectedLength==0，原25名称/动作/其它断言不变，textarea合法选区保留。原LegacySystemDragBoundaryTests中新增真实WebKit只读computed-style回归，先行为RED再GREEN。不改任何生产Sources/Package/gates/原输入执行器。

主agent将先同可执行代码、仅CSS资源不同的因果对照，再同步原严格oracle、执行原3可见状态各3轮x25与原全量XCTest；保留bare-CSS反向负例和失败，不以弱化/忽略选区/放开系统drag换绿。所有native运行继续产品deny+外层public tripwire与外部只读observer，实机诊断不冒充隔离环境或正式Factory/AppleScript验收，门禁不开放。


### 原页面拖动诊断矩阵恢复收口（2026-10-30）

- 两轮只读baseline实际确认：host不支持原unprefixed user-select:none，computedpref=text，customdrag被选中1→12共11字符；下次按住点在选区内、trusted dragstart携带text/html/plain。是夹具未禁选导致真实selection-drag，不应改生产输入或清选区掩盖。
- Terra仅修原fixture兼容前缀并加custom选择长度只读计数，原custom case保留moves>0且加强selectedLength==0，原25名称/动作不变；原测试类新增真实WebKit只读style RED(text)→GREEN(none)。主review修OR端点避免漏计，不改生产Sources/Package/gates。
- 主agent同__TEXT代码、只CSS资产变化的对照先恢复25项；严格oracle反向去prefix又明确失败custom case/selection11，原allPassed=false且原系统方法仍被guard挡住，证明不删断言换绿。当前Root严格oracle安全观测副本后台/遮挡/隐藏各3轮全部9x25=225通过，custom选择0/无drag deny/无tripwire。
- 每轮外部1500样本NSApp=nil，覆盖整个probe；计数常量/单cursor基线/self激活false/globalpointer0。无外部键盘活动，非持续打字/IME验收。原全量XCTest三轮每轮344entries=341pass/3原skip/0fail，原native93checks三轮通过。仅自有fixture/诊断，无VM/全局输入/恢复光标/提交发布。
- 这是原生诊断矩阵恢复，不冒充正式Factory/Runner/AppleScript/recipient/销毁回执或G1–G5；门禁不开放，下一步走正式链路与真实并行输入。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-custom-drag-fixture-matrix.md`。


### 打包 Manager 启动事件与 TCC 预检收口（2026-10-30）

- Terra/high 仅实现私有诊断工具，主 agent 唯一review并独立编译/运行。基线287已有文件在记录前哈希不变；生产Sources/Package/原夹具测试与正式gates未动；本轮只新增报告和本节记录。正常已安装App、相邻工作区、原10个缺失assets及skip-worktree保持。
- 当前源码debug候选使用独立BID sh.safarier.g1probe，私有pre-main固定身份/workspace/trace验证和七个AppKit显示/激活拒绝保护；只包装原Manager已有handler，不增服务或接收器，无全局输入/VM/焦点IME回位。实际Class元数据证明诊断器mangled-name假设错误，精确修复demangled名，ABI/own/映像检查不放宽。
- 最终同构建三轮进程重启均真实收到ascr/noop且先于DidFinish，inactive/accessory/0窗口/无key，普通终止观察完成。它们不是三个全新构建首次冷启动；cold-final-1仍30秒回调且无prelude/trace、需forceTerminate，未定位；有界late采样后续未复现所以没取得失败现场栈，不称RunLoop或缓存问题已修复。G1不通过。
- capabilities-1只做到真实Manager启动与askUserIfNeeded=false权限预检，实际-1744需要用户同意，立即停止自定义发送；未弹授权框/无AESendMessage/无能力回复，非AppleScript语言或唯一Manager路由闭环。后续授权须用户另行同意，不能绕过。
- 主独立原七方法headless预检、私有路径/日志/身份/handler转发/driver纯测试和当前App debug构建通过。最终两段只读observer各3000样本覆盖成功轮及预检，存在外部键鼠活动和cursor变化，不称鼠标静止；无RunLoop observer的frontPID可能陈旧，不能拿常量值证明焦点。无页面输入，非G5持续打字/中文IME验收；原344项/9x25没有本轮重跑。
- Factory/Native/defaultscript与coldLaunchVerified保持关闭，无安装/提交/push/发布；下一步分别定位首次启动、取得真实只读回复，再走正式身份路由/Runner/页面输入与并行输入验收。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-manager-entry-and-tcc-preflight.md`。


### 一次系统授权与真实命令拒绝（2026-11-02）

用户明确允许仅只读能力查询的一次自动化授权。Terra/high在新私有driver复用原链路添加显式consent-once，false预检、独占600持久claim、仅-1744/fresh owner允许一次后台true请求、20秒严格截止且迟到不发事件；主agent唯一review并独立C/Swift纯测试及真实运行。原候选主二进制24284a9...保持不变，未改生产Sources/门禁/正常App。实际13:20预检-1744→一次true请求返回0→真实SFAu/requ回复OSStatus0但应用UNAUTHORIZED，driver正确exit1；无有效capabilities回复，不放行。候选PID55101保持后台/0窗口/无key，普通终止观察完成，无页面动作/全局输入/VM/重新弹框。claim保留不自动删除。只读observer3000样本但前273ms未覆盖，非全程焦点或G5证明。下一步观察原Cocoa命令上下文与真实OS属性类型长度，未定位前不放宽身份校验；新签名若再需授权只预检停下。首次构建启动停滞及正式唯一Manager/Runner/输入门禁仍未通过，无安装/提交/发布。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-11-02-consent-once-real-command.md`。


### UNAUTHORIZED真实sender编码归因与修复（2026-11-02）

- Terra/high实现，主agent唯一review并独立回归/实机验证。先在原私有fence加opt-in原命令typed-forward观察，全部7个UI拒绝保护不变；同一二进制控制与诊断均UNAUTHORIZED，真实主线程/currentself/Manager上下文通过，UID/PID却是精确4字节UInt32(magn)，audit仍tokn/32。原parser只认SInt32，归因为wire表示误拒绝，不猜测删除身份guard。
- 仅原AutomationRequestCommand.swift私有helper无损归一化明确SInt32/UInt32四字节；同UID、PID1...Int32.max、exact audit类型/长度、真实当前命令/主线程/角色及原异步流程保留。无字符串coercion/身份fallback/新执行器。原测试补unsigned/mixed/highUID、缺失/错型/错长/溢出/坏audit与非Cocoa构造命令拒绝；真实行为RED→GREEN。原文件未跟踪，重建before副本哈希与capture基线一致后主reviewattestedpatch。
- 主独立安全定向XCTest三轮各10entries=9pass/1原skip/0fail；8组headless测试通过，最终debug构建0且修复warning清除。未运行会置前/置key的全量UI套件，不称344项重跑。
- 最终同构建真实只读capabilities三轮Control/Probe/Control全部严格requestID/PID/角色/未开放能力验证通过，driverexit0、普通退出；probe真实UIDmatch/PIDpositive/audit检查通过，控制轮未装请求观察仍成功。全部权限仅false预检0，不再请求授权，无页面/全局输入/VM/鼠标焦点IME回位。正常App/相邻工作区/旧assets状态保持。
- 两次初始启动迟到与一次owned采样仍保留失败，采样时已进入正常事件循环，未定位先前延迟；最后三轮不是全新构建首次冷启动。G1/正式唯一Manager/Factory/Runner/页面/中文IME仍未通过，原门禁关闭，无安装/提交/发布。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-11-02-unauthorized-sender-encoding.md`。


### 启动等待归因与私有验证路径修复（2026-11-02）

Terra/high分别实现driver/fence，主唯一review及实机验证。内部最早C标记与原外接盘prelude分段证实延迟落在诊断I/O；tccd历史同PID记录新ad-hoc代码要求与RemovableVolumes授权不匹配、AUTHREQ_PROMPTING及长时间后Create，与旧30秒失败和采样进程恢复吻合。不能再把无旧prelude说成尚未执行。识别后停止新签名外接数据控制，未点击/绕过/重置系统权限。

仅将私有receiver的HOME/trace/prelude改为本机内部本次0700目录，固定EXE/BID、同UID、无符号链接、独占600、label绑定、7个UI拒绝、watchdog45及20秒成功界限均保留，不同时允许旧外接根。产品默认ApplicationSupport及Auth修复未改。3个不同新签名构建各首次启动均quiet-force-noop通过，callback分别234.239/170.751/200.373ms、DidFinish均<323ms、prelude<0.2ms，均后台0窗口正常退出。没有预热/重试/整体bundle重建来判绿；同旧bundle/Info inode，装配约0.3秒。修复后匹配系统日志无AUTHREQ_PROMPTING（仍可能有静默卷检查），真实只读cap验证通过，无新授权请求/页面/全局输入/VM/焦点IME回位。主独立原headless与新增时钟/路径/driver/sidecar纯测试通过。

这是验证链路位置错误的纠正，不是修改系统LS或生产Manager逻辑；外接卷用户数据仍需真实授权。正式BID/多Runner/人类UI/页面/中文IME未全验，完整G1及输入门禁不放行，未安装/提交/发布。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-11-02-launchservices-removable-volume-delay.md`。


### 单私有Manager的Bundle ID路由补证（2026-11-02）

沿现有私有driver新增标准非force/noop启动+PID control/BID只读capabilities；Terra/high实现，主agent唯一review、独立构建测试及真实执行。修正权限预检迟到后继续发送的风险，保留false预检/期限/唯一owner/严格回复门禁。三轮同签名新进程回调210.890/104.788/208.524ms，9次请求（3 PID+6 BID）UUID/PID/role/不可用能力全部匹配，正常清理；无显示激活/interactive保护命中，45状态样本后台0窗口。未触发目标授权提示流程，未用全局输入。

只证明sh.safarier.g1probe单接收者，不是实际osascript/正式BID/仅Runner/多Runner/人类UI或G5验收；G1和输入门禁仍关闭。产品源码、原UInt32身份修复和正常App不变，无安装/提交/发布。下一步先限定Runner共存/正式身份隔离验证，不能自动触碰日常App注册/授权。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-11-02-single-manager-bundle-id-routing.md`。


### 真实unavailable Runner共存验证（2026-11-02）

两位Terra/high实现私有driver/harness，主agent唯一review、独立构建测试及真实执行。沿原RunnerMain/继承socketpair/hard gate启动真实Foundation-only unavailable Runner，不开NSApp/WebView、不补GUI注册。主review修正发送期限/即时生命周期、pbi_flags退出位、空注册目标预检前置条件；首轮无注册目标false预检超时失败保留，两Runner自然exit0，不算成功。

修正后3完整周期，每周期两个真实Runner：仅Runner存活前后6次均注册列表0，明确no_registered_target，不预检、不发送、不隐式启动Manager；Manager+两Runner时只注册Manager，3 PID+6 BID capabilities严格匹配，36次注册快照正常。Manager callbacks118.077/104.236/144.315ms，3Manager普通终止、6Runner EOF自然exit0。无显示激活/interactive保护命中，无新授权提示流程或全局输入。

**仅证明当前门禁关闭的unavailable Runner分支，不是人工GUI Runner/多个已注册接收者/正式BID或实际osascript/G5验收。完整G1和输入门禁继续关闭。** 产品/正常App未改，无安装/提交/发布。后续人工GUI/正式身份验证需先限定隔离边界，不能自动开窗口或改helper架构。报告：`/Volumes/RC500/dev/safarier/docs/verification/2026-11-02-real-unavailable-runner-coexistence.md`。
