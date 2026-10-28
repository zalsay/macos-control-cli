import Foundation
import AppKit

private func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func expect(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "未拒绝：\(code)") }
    catch let failure as HelperFailure { require(failure.code == code, "错误码不符合预期：\(failure.code)，期望：\(code)") }
    catch { require(false, "错误类型不符合预期：\(error)") }
}
private func chromeWindow(_ pid: pid_t, _ id: CGWindowID, _ bounds: WindowBounds,
                          bundleId: String = "com.google.Chrome") -> ChromeWindow {
    ChromeWindow(target: TargetWindow(windowId: id, pid: pid, bundleId: bundleId),
                 title: "test", bounds: bounds, layer: 0, appName: "Chrome")
}

// This mode runs only deterministic readback fakes: no osascript, subprocess or GUI.
if ProcessInfo.processInfo.environment["MCC_CHROME_START_READBACK_ONLY"] == "1" {
    do { try testStableReadback(); print("PASS: fake-only Chrome readback") }
    catch { fputs("FAIL: unexpected readback error: \(error)\n", stderr); exit(1) }
    exit(0)
}

// Automation preflight is non-prompting and must fail clearly before any window is created.
try validateChromeAutomationPermission(0)
try validateChromeAutomationPermission(-600) // Not running: the normal OS launch still enforces its own authorization.
for status: Int32 in [-1744, -1743] {
    expect("AUTOMATION_PERMISSION_REQUIRED") { try validateChromeAutomationPermission(status) }
}
expect("AUTOMATION_UNVERIFIED") { try validateChromeAutomationPermission(-1) }

// Explicit --request must reach the OS as true; ordinary queries remain non-prompting.
var permissionCalls: [Bool] = []
let readonlyPermission = chromeAutomationPermission(request: false, determine: { ask in
    permissionCalls.append(ask); return -1744
})
require(permissionCalls == [false] && readonlyPermission["requested"] as? Bool == false,
        "只读permissions不允许请求系统弹窗")
require(readonlyPermission["status"] as? String == "requires_consent" && readonlyPermission["granted"] as? Bool == false,
        "尚待同意不得视为已授权")
let requestedPermission = chromeAutomationPermission(request: true, determine: { ask in
    permissionCalls.append(ask); return 0
})
require(permissionCalls == [false,true] && requestedPermission["requested"] as? Bool == true,
        "permissions --request必须调用可请求授权路径")
require(requestedPermission["granted"] as? Bool == true && requestedPermission["target"] as? String == "com.google.Chrome",
        "授权结果须绑定Chrome目标")
for (code,name): (Int32,String) in [(-1743,"denied"),(-600,"target_not_running"),(-1,"unverified")] {
    let result=chromeAutomationPermission(request:true,determine:{_ in code})
    require(result["status"] as? String == name && result["granted"] as? Bool == false,
            "拒绝、未运行或未知状态不能冒充已授权")
    require(result["osStatus"] as? Int32 == code,"返回原始OS状态供诊断")
}

// The normal suite still exercises subprocesses; this opt-in mode is exclusively
// for the no-process fake validation requested for readback changes.
if ProcessInfo.processInfo.environment["MCC_CHROME_START_FAKE_ONLY"] != "1" {
// Exercise the same separator initialization through a real local osascript pipe.
// No application is targeted: this cannot create a window or ask for automation consent.
let formatCancellation=InputCancellation()
let formatPermit=try formatCancellation.beginSetup(generation:formatCancellation.snapshot(), expectedEpoch:formatCancellation.inputSnapshot())
let formatProcess=Process()
let formatPipe=Pipe()
formatProcess.executableURL=URL(fileURLWithPath:"/usr/bin/osascript")
formatProcess.arguments=["-e", chromeReceiptSeparatorScript + "\nreturn \"7007\" & mccReceiptSeparator & \"0\" & mccReceiptSeparator & \"25\" & mccReceiptSeparator & \"800\" & mccReceiptSeparator & \"625\""]
formatProcess.standardOutput=formatPipe
let formatData=try withCancellableSetupProcess(formatProcess,cancellation:formatCancellation,permit:formatPermit,timeout:3,
    timeoutCode:"FORMAT_TIMEOUT",failureCode:"FORMAT_FAILED",failureMessage:"format fixture failed",timeoutMessage:"format fixture timeout",
    readOutput:{formatPipe.fileHandleForReading.readDataToEndOfFile()})
let formatted=String(data:formatData,encoding:.utf8)!
require(formatted.filter{$0=="\t"}.count==4,"receipt分隔必须是四个真正的HT字符，不是Chrome tab术语文本")
let pipeReceipt=try parseChromeCreationReceipt(formatted,expectedBounds:WindowBounds(x:0,y:25,width:800,height:600))
require(pipeReceipt.appleScriptWindowID=="7007","本地真实子进程输出必须可解析为创建receipt")

}

// macOS clamps a full-height resize at the current y. Move first, then resize.
var layoutOperations:[String]=[]
var fakeTop=90.0
var fakeHeight=900.0
try applyChromeStartGeometry(position:{layoutOperations.append("position");fakeTop=30;return .success},
                             size:{layoutOperations.append("size");fakeHeight=min(1336,1366-fakeTop);return .success})
require(layoutOperations == ["position","size"] && fakeHeight==1336,
        "满高布局必须先移至可用顶边，再设置高度，不能接受系统从旧y钳制后的短窗口")
layoutOperations=[]
expect("CHROME_LAYOUT_FAILED") {
    try applyChromeStartGeometry(position:{layoutOperations.append("position");return .cannotComplete},
                                 size:{layoutOperations.append("size");return .success})
}
require(layoutOperations==["position"],"位置设置失败后禁止继续尺寸副作用")
expect("USER_PAUSED") {
    try applyChromeStartGeometry(position:{throw HelperFailure.userPaused},size:{return .success})
}

// Given 主屏可用区含菜单栏/程序坞扣除后的真实 visibleFrame，Then 按 Retina 原始像素计算宽度并保留全高。
let retina = try chromeStartLayout(
    visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850),
    primaryFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    scale: 2, maxWidthPx: 1600)
require(retina.bounds.x == 0 && retina.bounds.y == 25, "主屏左上角必须从 visibleFrame 与主屏坐标变换得出")
require(retina.bounds.width == 800 && retina.bounds.height == 850, "Retina 窗口点尺寸错误")
require(retina.widthPixels == 1600 && retina.availableWidthPixels == 2880 && retina.heightPixels == 1700 && retina.scale == 2,
        "Retina 原始像素不能按点数解释或缩放")

// Given 主屏上方有菜单栏留白，Then 使用 visibleFrame 顶边而不是整屏顶边。
let dockAndMenu = try chromeStartLayout(
    visibleFrame: CGRect(x: 20, y: 35, width: 1200, height: 800),
    primaryFrame: CGRect(x: 0, y: 0, width: 1240, height: 900),
    scale: 1, maxWidthPx: 1600)
require(dockAndMenu.bounds.x == 20 && dockAndMenu.bounds.y == 65,
        "窗口左上角必须避开 visibleFrame 之外的菜单栏/程序坞区域")
require(dockAndMenu.bounds.height == 800, "窗口必须使用完整 usable height")

// Given 扩展屏位于主屏左侧/上方，Then 保留负全局原点并用主屏 maxY 转为 AX 顶左坐标。
let negativeOrigin = try chromeStartLayout(
    visibleFrame: CGRect(x: -1280, y: 900, width: 1280, height: 775),
    primaryFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    scale: 1, maxWidthPx: 1600)
require(negativeOrigin.bounds.x == -1280 && negativeOrigin.bounds.y == -775,
        "扩展屏负原点/主屏顶左坐标变换错误")
require(negativeOrigin.widthPixels == 1280 && negativeOrigin.heightPixels == 775,
        "屏幕宽度不足 maxWidthPx 时必须使用可用原始像素宽度")
expect("INVALID_ARGUMENT") {
    _ = try chromeStartLayout(visibleFrame: .zero, primaryFrame: .zero, scale: 1, maxWidthPx: 1600)
}
expect("INVALID_ARGUMENT") {
    _ = try chromeStartLayout(visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              primaryFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              scale: .infinity, maxWidthPx: 1600)
}
expect("IMAGE_TOO_LARGE") {
    _ = try chromeStartLayout(visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 4200),
                              primaryFrame: CGRect(x: 0, y: 0, width: 800, height: 4200),
                              scale: 2, maxWidthPx: 1600)
}

// Given 两阶段 AppleScript 对象 receipt，Then 只有同一新增 Chrome PID/CGWindowID 的 A->B 几何迁移可绑定。
let oldIdentity = ChromeWindowIdentity(pid: 10, windowID: 101)
let receiptLayout = try chromeStartLayout(
    visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850),
    primaryFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1, maxWidthPx: 1400)
let probes = try chromeCreationProbeBounds(
    layout: receiptLayout, nonce: UUID(uuidString: "74D1A9B0-2210-4F31-9A42-3891D4B13E73")!)
require(probes.first.y != probes.second.y && probes.first.height != probes.second.height,
        "receipt 的两个探针必须有不同几何")
require(probes.first.y >= receiptLayout.bounds.y &&
        probes.first.y + probes.first.height <= receiptLayout.bounds.y + receiptLayout.bounds.height,
        "receipt 探针必须保持在 visibleFrame 内")
let receipt = try parseChromeCreationReceipt(
    "7007\t\(probes.first.x)\t\(probes.first.y)\t\(probes.first.x + probes.first.width)\t\(probes.first.y + probes.first.height)\n",
    expectedBounds: probes.first)
require(receipt.appleScriptWindowID == "7007", "必须保留 make new window 的数值对象 receipt ID")
let oldWindow = chromeWindow(10, 101, WindowBounds(x: 0, y: 25, width: 900, height: 700))
let concurrentUserWindow = chromeWindow(10, 102, WindowBounds(x: 50, y: 80, width: 700, height: 500))
let ownAtA = chromeWindow(10, 103, probes.first)
let ownAtB = chromeWindow(10, 103, probes.second)
let beforeChrome: Set<ChromeWindowIdentity> = [oldIdentity]
let stageA = try selectReceiptBoundNewWindow(before: beforeChrome,
                                             after: [oldWindow, concurrentUserWindow, ownAtA],
                                             receiptBounds: probes.first)
require(stageA?.pid == 10 && stageA?.windowId == 103,
        "差集中即使有并发用户新窗，也必须选择 receipt 几何对应的对象")
let stageB = try selectReceiptBoundNewWindow(before: beforeChrome,
                                             after: [oldWindow, concurrentUserWindow, ownAtB],
                                             receiptBounds: probes.second)
require(stageB?.pid == stageA?.pid && stageB?.windowId == stageA?.windowId,
        "receipt 从 A 移到 B 必须仍对应同一 CGWindowID/PID")
let unrelatedOnly = try selectReceiptBoundNewWindow(before: beforeChrome,
                                                    after: [oldWindow, concurrentUserWindow],
                                                    receiptBounds: probes.first)
require(unrelatedOnly == nil, "receipt 窗口未出现在 CG 列表时不得误选并发用户窗口")
let nonChromeReceipt = try selectReceiptBoundNewWindow(before: beforeChrome,
                                                       after: [chromeWindow(10, 101, probes.first),
                                                               chromeWindow(20, 201, probes.first,
                                                                            bundleId: "com.apple.finder")],
                                                       receiptBounds: probes.first)
require(nonChromeReceipt == nil, "receipt 差集与快照必须显式限于 Chrome bundle")
expect("CHROME_RECEIPT_AMBIGUOUS") {
    _ = try selectReceiptBoundNewWindow(before: beforeChrome,
                                        after: [ownAtA, chromeWindow(11, 203, probes.first)],
                                        receiptBounds: probes.first)
}
expect("CHROME_RECEIPT_INVALID") {
    _ = try parseChromeCreationReceipt("\t0\t0\t800\t800", expectedBounds: probes.first)
}
expect("CHROME_RECEIPT_INVALID") {
    _ = try parseChromeCreationReceipt("not-an-integer\t0\t0\t800\t800", expectedBounds: probes.first)
}
expect("CHROME_RECEIPT_MISMATCH") {
    _ = try parseChromeCreationReceipt("7007\t0\t0\t800\t800", expectedBounds: probes.first)
}

// Given 原生协议请求，Then 默认 about:blank 与像素上限明确，且 URL 必须是绝对 HTTP(S)。
let defaultRequest = try NativeRequest.decode(["id": "start", "action": "chrome-start"])
require(defaultRequest.url == "about:blank" && defaultRequest.maxWidthPx == 1600,
        "chrome-start 默认值不符合契约")
let boundedRequest = try NativeRequest.decode(["id": "start", "action": "chrome-start",
                                                "url": "https://example.com/path?q=1", "maxWidthPx": 900])
require(boundedRequest.url == "https://example.com/path?q=1" && boundedRequest.maxWidthPx == 900,
        "chrome-start 合法参数未保留")
let desktopScopeRequest = try NativeRequest.decode(["id": "desktop-start", "action": "chrome-start",
                                                     "url": "https://example.com", "maxWidthPx": 1200],
                                                    scope: .desktop)
require(desktopScopeRequest.url == "https://example.com" && desktopScopeRequest.maxWidthPx == 1200,
        "Desktop scope 的 mcc chrome start 入口必须接受 Chrome 专用启动动作")
for badURL in ["", "about:blank", "javascript:alert(1)", "file:///tmp/a", "ftp://example.com",
               "/relative", "https:example.com", "https:///missing-host", " https://example.com",
               "https://user:secret@example.com", "https://" + String(repeating: "a", count: 4100)] {
    expect("INVALID_ARGUMENT") {
        _ = try NativeRequest.decode(["id": "start", "action": "chrome-start", "url": badURL])
    }
}
for badWidth: Any in [399, 1601, true, 800.5, "800"] {
    expect("INVALID_ARGUMENT") {
        _ = try NativeRequest.decode(["id": "start", "action": "chrome-start", "maxWidthPx": badWidth])
    }
}

// Given fresh helper 且无 execution lease，Then setup 可执行但不造 lease/countdown 或改变 cancellation 状态。
let freshCancellation = InputCancellation()
let freshGeneration = freshCancellation.snapshot()
let freshEpoch = freshCancellation.inputSnapshot()
let startupPermit = try freshCancellation.beginSetup(generation: freshGeneration, expectedEpoch: freshEpoch)
var setupEffects = 0
try freshCancellation.checkSetup(startupPermit)
try freshCancellation.setupEffect(permit: startupPermit) { setupEffects += 1 }
try freshCancellation.checkSetup(startupPermit)
require(setupEffects == 1 && freshCancellation.snapshot() == freshGeneration &&
        freshCancellation.inputSnapshot() == freshEpoch,
        "fresh setup permit 必须成功且不得修改 generation/epoch/lease/phase")

// Given startup permit 已签发，When 后续建立 lease，Then stale setup capability 关闭。
let racedCancellation = InputCancellation()
let racedGeneration = racedCancellation.snapshot()
let racedPermit = try racedCancellation.beginSetup(generation: racedGeneration,
                                                   expectedEpoch: racedCancellation.inputSnapshot())
_ = try racedCancellation.beginExecution(generation: racedGeneration)
var racedEffects = 0
expect("CONNECTION_BUSY") { try racedCancellation.checkSetup(racedPermit) }
expect("CONNECTION_BUSY") { _ = try racedCancellation.setupEffect(permit: racedPermit) { racedEffects += 1 } }
require(racedEffects == 0, "活动 lease 不能通过 stale setup permit 执行副作用")

// Given 活动 lease，Then setup 拒绝；已暂停时以 USER_PAUSED 拒绝并精确保留状态/epoch。
var now: TimeInterval = 10
let cancellation = InputCancellation(clock: { now })
let generation = cancellation.snapshot()
let lease = try cancellation.beginExecution(generation: generation)
let activeEpoch = cancellation.inputSnapshot()
expect("CONNECTION_BUSY") {
    _ = try cancellation.beginSetup(generation: generation, expectedEpoch: activeEpoch)
}
require(cancellation.inputSnapshot() == activeEpoch, "active lease 拒绝不能更改 epoch")
require(cancellation.startCountdown(lease: lease), "测试倒计时未开始")
now += 4
_ = try cancellation.beginInput(generation: generation, expectedEpoch: cancellation.inputSnapshot())
require(cancellation.pauseExecution(lease: lease), "测试暂停未生效")
let pausedEpoch = cancellation.inputSnapshot()
expect("USER_PAUSED") {
    _ = try cancellation.beginSetup(generation: generation, expectedEpoch: pausedEpoch)
}
require(cancellation.inputSnapshot() == pausedEpoch && cancellation.executionState(lease: lease) == .paused,
        "setup 门禁不能重置 userPaused 状态或 epoch")

// Given cancel 已推进 generation，Then 旧 startup request 必须拒绝。
let cancelledSetup = InputCancellation()
let cancelledGeneration = cancelledSetup.snapshot()
let cancelledEpoch = cancelledSetup.inputSnapshot()
cancelledSetup.cancel()
expect("CANCELLED") {
    _ = try cancelledSetup.beginSetup(generation: cancelledGeneration, expectedEpoch: cancelledEpoch)
}

if ProcessInfo.processInfo.environment["MCC_CHROME_START_FAKE_ONLY"] != "1" {
// Given setup 子进程运行中 helper cancel，Then ACK 前子进程必须终止。
let processCancellation = InputCancellation()
let processGeneration = processCancellation.snapshot()
let processPermit = try processCancellation.beginSetup(generation: processGeneration,
                                                      expectedEpoch: processCancellation.inputSnapshot())
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sleep")
child.arguments = ["10"]
let processDone = DispatchSemaphore(value: 0)
let resultLock = NSLock()
var processFailure: String?
DispatchQueue.global().async {
    defer { processDone.signal() }
    do {
        try withCancellableSetupProcess(child, cancellation: processCancellation, permit: processPermit,
                                        timeout: 5, timeoutCode: "TEST_TIMEOUT", failureCode: "TEST_FAILED",
                                        failureMessage: "fake process failed", timeoutMessage: "fake process hung",
                                        readOutput: { () })
    } catch let failure as HelperFailure {
        resultLock.lock(); processFailure = failure.code; resultLock.unlock()
    } catch {
        resultLock.lock(); processFailure = "UNEXPECTED"; resultLock.unlock()
    }
}
let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
while !child.isRunning && ProcessInfo.processInfo.systemUptime < launchDeadline {
    Thread.sleep(forTimeInterval: 0.005)
}
require(child.isRunning, "可取消 fake setup 子进程没有启动")
processCancellation.cancel()
require(!child.isRunning, "cancel ACK 早于 setup 子进程退出")
require(processDone.wait(timeout: .now() + 2) == .success, "cancel 后 setup 子进程未及时终止")
resultLock.lock(); let cancelledProcessFailure = processFailure; resultLock.unlock()
require(cancelledProcessFailure == "CANCELLED" && !child.isRunning,
        "cancel 必须通过 StartupPermit 中断并回收 setup 子进程")

}

try testStableReadback()

print("PASS: chrome-start 几何、receipt、协议、授权映射、setup门禁与readback fake；子进程测试：\(ProcessInfo.processInfo.environment["MCC_CHROME_START_FAKE_ONLY"] == "1" ? "跳过" : "已执行")；未启动 Chrome 或发送网站输入")


private enum ReadbackEvent {
    case unavailable
    case unavailableWindow(WindowBounds)
    case deadlineWindow(WindowBounds)
    case sample(WindowBounds, WindowBounds, advance: TimeInterval = 0, failAfter: String? = nil)
    case failure(String)
    case wrongIdentity
}
private final class FakeReadback {
    var time: TimeInterval = 0
    var deadline: TimeInterval = 0.2
    var events: [ReadbackEvent]
    var reads = 0
    var failure: String?
    var checks = 0
    var expireOnCheck: Int?
    let expected = WindowBounds(x: 20, y: 25, width: 700, height: 600)
    init(_ events: [ReadbackEvent]) { self.events = events }
    func run() throws -> ChromeWindow {
        try waitForChromeStableReadback(expected: expected, target: ChromeWindowIdentity(pid: 71, windowID: 502), scale: 1, maxWidthPx: 800,
            deadline: deadline, now: { self.time }, check: {
                self.checks += 1
                if self.checks == self.expireOnCheck { self.time = self.deadline }
                if let code = self.failure { throw HelperFailure(code: code, message: "fake control failure") }
            }, read: {
                self.reads += 1
                let event = self.events.isEmpty ? ReadbackEvent.unavailable : self.events.removeFirst()
                switch event {
                case .unavailable: return .unavailable
                case .unavailableWindow(let bounds): return .unavailableWindow(chromeWindow(71, 502, bounds))
                case .deadlineWindow(let bounds): self.time = self.deadline; return .deadline(chromeWindow(71, 502, bounds))
                case .failure(let code): throw HelperFailure(code: code, message: "fake failure")
                case .wrongIdentity: return .sample(ax: self.expected, window: chromeWindow(71, 503, self.expected))
                case .sample(let ax, let cg, let advance, let failAfter):
                    self.time += advance
                    self.failure = failAfter
                    return .sample(ax: ax, window: chromeWindow(71, 502, cg))
                }
            }, sleep: { self.time += $0 })
    }
}
private func testStableReadback() throws {
    try testAXReadbackPrimitives()
    let b = WindowBounds(x: 20, y: 25, width: 700, height: 600)
    let good = ReadbackEvent.sample(b, b)
    let retry = FakeReadback([.unavailable, good, good])
    let result = try retry.run()
    require(result.target.pid == 71 && result.target.windowId == 502 && retry.reads == 3,
            "首次AX不可用后必须重新读取并取得两个连续稳定样本")

    let cgOnly = FakeReadback([.unavailableWindow(b), good, good])
    _ = try cgOnly.run()
    require(cgOnly.reads == 3, "已取得CG但AX不可用时仍须连续两次完整读取")

    let interrupted = FakeReadback([good, .unavailable, good])
    expect("CHROME_LAYOUT_UNSTABLE") { _ = try interrupted.run() }
    require(interrupted.reads > 3, "中间不可读必须清除旧稳定样本")

    let jitter = WindowBounds(x: 20.4, y: 25, width: 700, height: 600)
    let unstableAX = FakeReadback([good, .sample(jitter,b), good])
    expect("CHROME_LAYOUT_UNSTABLE") { _ = try unstableAX.run() }
    require(unstableAX.reads > 3, "AX变化时不能仅凭CG稳定判定成功")

    let mismatch = WindowBounds(x: 23, y: 25, width: 700, height: 600)
    let mismatchReset = FakeReadback([good, .sample(mismatch,b), good, good])
    _ = try mismatchReset.run()
    require(mismatchReset.reads == 4, "不匹配样本必须清除旧稳定样本")
    let wrongIdentity = FakeReadback([.wrongIdentity, good, good])
    expect("CHROME_WINDOW_IDENTITY") { _ = try wrongIdentity.run() }
    require(wrongIdentity.reads == 1, "错误CG窗口身份必须立即终止")

    let unavailable = FakeReadback([])
    expect("CHROME_LAYOUT_READBACK_FAILED") { _ = try unavailable.run() }
    require(unavailable.time >= unavailable.deadline && unavailable.reads <= 5, "永久不可读必须在原deadline有界失败")

    let before = FakeReadback([good, good]); before.deadline = 0
    expect("CHROME_LAYOUT_READBACK_FAILED") { _ = try before.run() }
    require(before.reads == 0, "deadline到期前不得启动读取")

    let late = FakeReadback([good, .sample(b, b, advance: 0.2)])
    expect("CHROME_LAYOUT_UNSTABLE") { _ = try late.run() }
    require(late.reads == 2, "迟到的第二样本不可被接受")
    let justBeforeAccept = FakeReadback([good,good]); justBeforeAccept.expireOnCheck = 5
    expect("CHROME_LAYOUT_UNSTABLE") { _ = try justBeforeAccept.run() }
    require(justBeforeAccept.reads == 2, "接受最终结果前过期不能成功")
    let pausedBeforeRead = FakeReadback([good,good]); pausedBeforeRead.failure = "USER_PAUSED"
    expect("USER_PAUSED") { _ = try pausedBeforeRead.run() }
    require(pausedBeforeRead.reads == 0, "暂停时不得开始新的AX/CG读取")
    let cancelledAfterRead = FakeReadback([.sample(b,b,failAfter:"CANCELLED")])
    expect("CANCELLED") { _ = try cancelledAfterRead.run() }
    require(cancelledAfterRead.reads == 1, "读取后取消必须立即传播")
    let afterReadPause = FakeReadback([good, .sample(b, b, failAfter: "USER_PAUSED")])
    expect("USER_PAUSED") { _ = try afterReadPause.run() }
    require(afterReadPause.reads == 2, "第二次读取后必须再次检查暂停")
    for code in ["WINDOW_UNAVAILABLE", "CHROME_WINDOW_IDENTITY", "USER_PAUSED", "CANCELLED", "CHROME_START_TIMEOUT"] {
        let fatal = FakeReadback([.failure(code), good, good])
        expect(code) { _ = try fatal.run() }
        require(fatal.reads == 1, "身份、窗口、暂停、取消和预算错误必须立即终止")
    }
    let deadlineOnly = FakeReadback([.deadlineWindow(b), good, good])
    expect("CHROME_LAYOUT_READBACK_FAILED") { _ = try deadlineOnly.run() }
    require(deadlineOnly.reads == 1, "读取中到期不得伪装成临时AX错误并继续读取")
    let wide = WindowBounds(x: 20, y: 25, width: 801, height: 600)
    for event in [ReadbackEvent.unavailableWindow(wide), .deadlineWindow(wide), .sample(wide,b), .sample(b,wide), .sample(wide,b,advance:0.2)] {
        let invalid = FakeReadback([event,good,good])
        expect("CHROME_WIDTH_CAP_UNMET") { _ = try invalid.run() }
        require(invalid.reads == 1, "宽度越界应立即优先拒绝")
    }
    for bad in [WindowBounds(x: .nan, y: 25, width: 700, height: 600), WindowBounds(x: 20, y: 25, width: 0, height: 600)] {
        for event in [ReadbackEvent.unavailableWindow(bad), .sample(bad,b), .sample(b,bad)] {
            let invalid = FakeReadback([event,good,good])
            expect("CHROME_LAYOUT_READBACK_FAILED") { _ = try invalid.run() }
            require(invalid.reads == 1, "无效AX或CG几何不能被重试掩盖")
        }
    }
}


private func testAXReadbackPrimitives() throws {
    var clock: TimeInterval = 10
    var timeoutValues: [Float] = []
    var calls = 0
    func perform(_ deadline: TimeInterval?, defaultTimeout: Bool = false,
                 status: AXError = .success, value: Int? = 7,
                 advance: TimeInterval = 0) -> ChromeAXCallResult<Int> {
        performBoundedAXCall(deadline: deadline, timeout: 0.35, setDefaultTimeout: defaultTimeout,
                             now: { clock }, setTimeout: { timeoutValues.append($0) }, call: {
                                 calls += 1; clock += advance; return (status, value)
                             })
    }
    var point = CGPoint(x: 20, y: 25)
    var size = CGSize(width: 700, height: 600)
    let validPoint = AXValueCreate(.cgPoint, &point)!
    let validSize = AXValueCreate(.cgSize, &size)!
    let invalidType = "not-an-AX-value" as CFString
    for (position, dimensions): (CFTypeRef, CFTypeRef) in [(invalidType, validSize), (validSize, validPoint)] {
        expect("FOCUS_UNVERIFIED") { _ = try decodeChromeAXBounds(positionValue: position, sizeValue: dimensions, strict: false) }
        expect("CHROME_LAYOUT_READBACK_FAILED") { _ = try decodeChromeAXBounds(positionValue: position, sizeValue: dimensions, strict: true) }
    }
    let parsed = try decodeChromeAXBounds(positionValue: validPoint, sizeValue: validSize, strict: true)
    require(parsed.x == 20 && parsed.y == 25 && parsed.width == 700 && parsed.height == 600,
            "合法AXValue几何应保留原样")
    let defaultValue = perform(nil)
    require(try requireChromeAXValue(defaultValue, strict: false, message: "fake") == 7,
            "默认AX读取必须保持原始成功值")
    require(timeoutValues.isEmpty && calls == 1, "默认属性读取不应新增timeout设置")
    _ = perform(nil, defaultTimeout: true)
    require(timeoutValues.count == 1 && abs(timeoutValues[0] - 0.35) < 0.0001,
            "默认identifier需保留0.35秒timeout")
    timeoutValues.removeAll(); calls = 0
    let bounded = perform(10.12)
    require(try requireChromeAXValue(bounded, strict: false, message: "fake") == 7,
            "deadline内AX读取应成功")
    require(timeoutValues.count == 1 && abs(timeoutValues[0] - 0.12) < 0.0001,
            "AX timeout不得超过deadline剩余时间")
    timeoutValues.removeAll(); calls = 0
    let expired = perform(10)
    if case .expired = expired {} else { require(false, "到期前不得读取AX") }
    require(calls == 0 && timeoutValues.isEmpty, "过期时不得调用AX")
    clock = 10; calls = 0
    let expiredDuringSetup: ChromeAXCallResult<Int> = performBoundedAXCall(
        deadline: 10.1, timeout: 0.35, setDefaultTimeout: false,
        now: { clock }, setTimeout: { _ in clock = 10.1 }, call: { calls += 1; return (.success, 7) })
    if case .expired = expiredDuringSetup {} else { require(false, "设置timeout期间过期必须拒绝") }
    require(calls == 0, "设置timeout后到期不得继续调用AX")
    clock = 10; calls = 0
    let late = perform(10.1, advance: 0.1)
    if case .expired = late {} else { require(false, "迟到的AX值不得接受") }
    require(calls == 1, "迟到读取只能执行一次")
    expect("FOCUS_UNVERIFIED") { _ = try requireChromeAXValue(ChromeAXCallResult<Int>.failure(.cannotComplete), strict: false, message: "fake") }
    expect("FOCUS_UNVERIFIED") { _ = try requireChromeAXValue(ChromeAXCallResult<Int>.failure(.apiDisabled), strict: true, message: "fake") }
    for outcome in [ChromeAXCallResult<Int>.failure(.cannotComplete), .failure(.invalidUIElement), .failure(.noValue), .expired] {
        do { _ = try requireChromeAXValue(outcome, strict: true, message: "fake"); require(false, "暂不可读必须单独分类") }
        catch is ChromeAXReadbackUnavailable {}
        catch { require(false, "暂不可读分类错误") }
    }
}
