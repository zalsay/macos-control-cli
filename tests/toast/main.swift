import AppKit

// AppKit 对象回归：只点击本进程 NSButton，不截图、不移动鼠标、不激活 Chrome 或发送输入。
setbuf(stdout, nil)
func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func pumpMain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)) }
guard let primary = NSScreen.screens.first,
      let previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { exit(2) }
_ = NSApplication.shared.setActivationPolicy(.accessory)
let toast = ChromeControlToast()
final class TestClock {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
let clock = TestClock()
let cancellation = InputCancellation(clock: clock.now)
let target = TargetWindow(windowId: 1, pid: previousPID)
let pageTitle = "Copis 测试页面"
let bounds = WindowBounds(x: primary.frame.minX + 10, y: 100, width: 800, height: 600)
try toast.show(over: bounds, target: target, title: pageTitle, cancellation: cancellation, generation: cancellation.snapshot())
let firstLease = try cancellation.beginExecution(generation: cancellation.snapshot())
guard let panel = NSApplication.shared.windows.first(where: { $0.title == "AI正在操作Chrome窗口..." }),
      let content = panel.contentView else {
    fputs("FAIL: 未创建原生控制窗口\n", stderr); exit(1)
}
// Given 提示条，Then 使用系统原生左侧三联按钮，不添加仿制按钮或开启缩放行为。
guard let nativeClose = panel.standardWindowButton(.closeButton),
      let nativeMinimize = panel.standardWindowButton(.miniaturizeButton),
      let nativeZoom = panel.standardWindowButton(.zoomButton) else {
    fputs("FAIL: toast 必须具有系统原生三联按钮\n", stderr); exit(1)
}
require(panel.styleMask.contains(.titled) && panel.styleMask.contains(.fullSizeContentView),
        "提示条应使用透明原生标题栏并保留完整内容区")
require(nativeClose.isEnabled && !nativeMinimize.isEnabled && !nativeZoom.isEnabled,
        "关闭可用，最小化和缩放保持系统禁用态")
let views = descendants(content)
guard let execute = views.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-execute" }),
      let pause = views.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-pause" }),
      let label = views.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-toast-primary" }) else {
    fputs("FAIL: 控制条缺少可访问的执行/暂停按钮或状态文字\n", stderr); exit(1)
}
guard let closeButton = panel.standardWindowButton(.closeButton),
      let logo = views.compactMap({ $0 as? NSImageView }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-toast-logo" }),
      let primaryLabel = views.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-toast-primary" }),
      let secondaryLabel = views.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-toast-secondary" }) else {
    fputs("FAIL: 控制条缺少可访问的关闭按钮或主副状态文字\n", stderr); exit(1)
}
require(panel.isVisible && panel.frame.size == CGSize(width: 560, height: 80), "控制条应能容纳两行说明与控制按钮")
require(primaryLabel.font?.pointSize == 16, "主状态文字应为 16px")
require((logo.image?.size.width ?? 0) > 0 && logo.frame.size == CGSize(width: 36, height: 36),
        "toast 必须从自身 assets 加载 36px Copis logo")
require(primaryLabel.stringValue == "AI即将接管「\(pageTitle)」页面" && secondaryLabel.stringValue == "3秒后接管 · 请松开鼠标",
        "首次接管应展示动态标题与两行三秒倒计时")
require(!panel.canBecomeKey && !panel.canBecomeMain && !panel.ignoresMouseEvents, "控制条必须可点击且不抢键盘焦点")
require(execute.acceptsFirstMouse(for: nil) && pause.acceptsFirstMouse(for: nil), "非激活控制条按钮必须支持 firstMouse")
require(!execute.isEnabled && pause.isEnabled && primaryLabel.stringValue == "AI即将接管「\(pageTitle)」页面", "首次接管应展示三秒倒计时，而不是立即发送输入")
require(pause.title == "取消", "倒计时期间应提供取消接管")
clock.advance(1)
pumpMain()
require(secondaryLabel.stringValue == "2秒后接管 · 请松开鼠标", "计时器应显示两秒")
clock.advance(1)
pumpMain()
require(secondaryLabel.stringValue == "1秒后接管 · 请松开鼠标", "计时器应显示一秒")
// 倒计时内收到的应用通知即使延迟到接管后处理，也不能暂停新输入。
try cancellation.effect(generation: cancellation.snapshot()) {
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
        userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
}
clock.advance(1)
pumpMain()
require(primaryLabel.stringValue == "AI正在操作「\(pageTitle)」页面" && pause.title == "暂停", "三秒后应自动接管并保持控制条可见")
let firstWindowNumber = panel.windowNumber
pause.performClick(nil)
require(cancellation.executionPaused(lease: firstLease) == true, "暂停按钮未关闭 core 输入门禁")
require(execute.isEnabled && !pause.isEnabled && primaryLabel.stringValue == "AI已暂停「\(pageTitle)」页面", "暂停按钮状态未更新")
try toast.show(over: bounds, target: target, title: pageTitle, cancellation: cancellation, generation: cancellation.snapshot())
require(try cancellation.beginExecution(generation: cancellation.snapshot()) == firstLease, "同一控制应复用 lease")
require(cancellation.executionPaused(lease: firstLease) == true && execute.isEnabled, "重复 show 不得自动清除暂停")
toast.updateTitle(target: target, title: "动态更新标题", cancellation: cancellation, generation: cancellation.snapshot())
require(primaryLabel.stringValue == "AI已暂停「动态更新标题」页面", "成功观察后的标题更新未刷新已有 toast")
toast.updateTitle(target: TargetWindow(windowId: 99, pid: previousPID), title: "错误目标", cancellation: cancellation, generation: cancellation.snapshot())
require(primaryLabel.stringValue == "AI已暂停「动态更新标题」页面", "错误目标可以修改 toast 标题")
let noToastDesktop = ChromeDesktop()
let visibleToastCount = NSApplication.shared.windows.filter { $0.title == "AI正在操作Chrome窗口..." }.count
try noToastDesktop.updateOperationToastTitle(target, title: "无toast更新", cancellation: cancellation,
                                              generation: cancellation.snapshot())
require(NSApplication.shared.windows.filter { $0.title == "AI正在操作Chrome窗口..." }.count == visibleToastCount,
        "没有已有 toast 时标题更新不能新建或显示控制条")
require(panel.windowNumber == firstWindowNumber && NSApplication.shared.windows.filter { $0.title == panel.title }.count == 1,
        "重复 show 创建了多余窗口")
execute.performClick(nil)
require(cancellation.executionPaused(lease: firstLease) == false && !execute.isEnabled && pause.isEnabled,
        "继续按钮应进入倒计时")
require(cancellation.executionState(lease: firstLease) == .countdown(3), "点击继续不能立即获得输入权限")
clock.advance(3)
pumpMain()
require(cancellation.executionState(lease: firstLease) == .running && pause.title == "暂停", "恢复后也应等待完整三秒")
require(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousPID, "点击控制条抢占了前台焦点")

// 模拟 inputEffect 锁内同步发布激活通知；回调必须异步暂停，不能重入同一把 core 锁。
try cancellation.effect(generation: cancellation.snapshot()) {
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
        userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
}
pumpMain()
require(cancellation.executionPaused(lease: firstLease) == true && execute.isEnabled && panel.isVisible,
        "运行中已收到外部应用激活通知，即使处理时已返回 Chrome 也必须保留暂停")
execute.performClick(nil)
clock.advance(3)
pumpMain()

// 窄屏布局只缩短文字，不裁掉两个固定按钮。
panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 288, height: 80)), display: false)
content.layoutSubtreeIfNeeded()
for button in [execute, pause] {
    let rect = button.convert(button.bounds, to: content)
    require(content.bounds.contains(rect) && rect.width >= 50 && rect.height >= 28, "窄屏下按钮被压缩或裁切")
}
let closeRect = closeButton.convert(closeButton.bounds, to: content)
require(content.bounds.contains(closeRect) && closeRect.maxX < content.bounds.midX, "原生关闭按钮必须位于左侧且不被裁切")
for button in [nativeClose, nativeMinimize, nativeZoom] {
    let rect = button.convert(button.bounds, to: content)
    require(content.bounds.contains(rect), "原生三联按钮不能被裁切")
    require(!rect.intersects(logo.frame) && !rect.intersects(primaryLabel.frame) && !rect.intersects(secondaryLabel.frame),
            "Logo和两行文字应让出系统标题栏：button=\(rect) logo=\(logo.frame) primary=\(primaryLabel.frame) secondary=\(secondaryLabel.frame) content=\(content.bounds)")
}
require(closeButton === nativeClose && closeButton.acceptsFirstMouse(for: nil), "红色关闭使用系统控件且首次点击可用")
require(primaryLabel.frame.minY >= secondaryLabel.frame.maxY, "页面主标题应位于状态说明上方")
require(!panel.isMovable, "原生标题栏不应改变固定提示条的定位行为")
try toast.show(over: bounds, target: target, title: pageTitle, cancellation: cancellation, generation: cancellation.snapshot())
let initialFrame = panel.frame
toast.avoidPointer(CGPoint(x: -10000, y: -10000))
require(panel.frame == initialFrame && panel.isVisible, "不覆盖目标时不应移动或关闭控制条")
let covered = CGPoint(x: panel.frame.midX, y: primary.frame.maxY - panel.frame.midY)
toast.avoidPointer(covered)
require(panel.isVisible && panel.frame != initialFrame && panel.frame.size == initialFrame.size,
        "AI 点覆盖 HUD 时应同屏避让而不是隐藏")
let appKitPoint = CGPoint(x: covered.x, y: primary.frame.maxY - covered.y)
require(!panel.frame.contains(appKitPoint), "避让后仍会点到控制按钮")

// 即使目标仍在后台也应先显示准备倒计时，倒计时内切应用不能把准备动作暂停。
cancellation.cancel()
try toast.show(over: bounds, target: TargetWindow(windowId: 2, pid: -1), title: pageTitle, cancellation: cancellation, generation: cancellation.snapshot())
let backgroundLease = try cancellation.beginExecution(generation: cancellation.snapshot())
require(panel.isVisible && cancellation.executionState(lease: backgroundLease) == .countdown(3), "后台首次 show 也必须显示准备倒计时")
try cancellation.effect(generation: cancellation.snapshot()) {
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
}
require(cancellation.executionPaused(lease: backgroundLease) == false, "激活通知不能在 core 锁内同步暂停")
pumpMain()
require(cancellation.executionPaused(lease: backgroundLease) == false, "倒计时中的应用切换不能造成暂停竞态")
clock.advance(3)
pumpMain()
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
pumpMain()
require(cancellation.executionPaused(lease: backgroundLease) == true && panel.isVisible && execute.isEnabled,
        "切走应用应暂停并保留可点击控制条")
// 正常 show 与该执行共用暂停状态，不会自动恢复。
try toast.show(over: bounds, target: target, title: pageTitle, cancellation: cancellation, generation: cancellation.snapshot())
require(execute.isEnabled && panel.isVisible, "暂停后 show 必须保留暂停状态")

// 取消 ACK 后即使主线程清理尚未调度，也不能移动旧控制条。
let cancelledGeneration = cancellation.snapshot()
let beforeCancel = panel.frame
cancellation.cancel()
toast.avoidPointer(CGPoint(x: beforeCancel.midX, y: primary.frame.maxY - beforeCancel.midY))
require(panel.frame == beforeCancel, "取消 ACK 后旧控制仍在避让移动")
pause.performClick(nil)
require(cancellation.executionPaused(lease: backgroundLease) == nil, "过期按钮不能创建或恢复执行状态")
do {
    try toast.show(over: bounds, target: target, title: pageTitle, cancellation: cancellation, generation: cancelledGeneration)
    require(false, "取消后旧代次仍能 show")
} catch let failure as HelperFailure { require(failure.code == "CANCELLED", "旧代次未保留取消错误") }
try toast.show(over: bounds, target: target, title: pageTitle, cancellation: cancellation, generation: cancellation.snapshot())
let newLease = try cancellation.beginExecution(generation: cancellation.snapshot())
pumpMain()
require(newLease != backgroundLease && panel.isVisible && cancellation.executionPaused(lease: newLease) == false,
        "旧 onEnd 回调隐藏或暂停了新 lease 控制条")
require(!execute.isEnabled && pause.isEnabled, "旧按钮状态泄漏到新 lease")

// 不同 core 实例可能使用相同 lease 数字；旧 owner 的结束回调不能关闭新 owner。
cancellation.cancel()
pumpMain()
let oldOwner = InputCancellation()
let newOwner = InputCancellation()
try toast.show(over: bounds, target: target, title: pageTitle, cancellation: oldOwner, generation: oldOwner.snapshot())
oldOwner.cancel()
try toast.show(over: bounds, target: target, title: pageTitle, cancellation: newOwner, generation: newOwner.snapshot())
pumpMain()
require(panel.isVisible, "不同 core 的相同 lease 让旧回调关闭了新控制条")
let closeLease = try newOwner.beginExecution(generation: newOwner.snapshot())
let queuedEpoch = newOwner.inputSnapshot()
closeButton.performClick(nil)
require(!panel.isVisible && newOwner.executionPaused(lease: closeLease) == true, "关闭必须先暂停输入门禁再隐藏 toast")
do {
    _ = try newOwner.beginInput(generation: newOwner.snapshot(), expectedEpoch: queuedEpoch)
    require(false, "toast 关闭后旧排队输入仍可提交")
} catch let failure as HelperFailure {
    require(failure.code == "USER_PAUSED", "toast 关闭后后续输入应保持 USER_PAUSED")
}
Thread.sleep(forTimeInterval: 3.2)
pumpMain()
require(!panel.isVisible && newOwner.executionPaused(lease: closeLease) == true, "关闭后旧倒计时不得复活或恢复输入")
toast.updateTitle(target: target, title: "关闭后更新", cancellation: newOwner, generation: newOwner.snapshot())
require(!panel.isVisible, "关闭后的标题更新不得重新显示 toast")
try toast.show(over: bounds, target: target, title: "再次显示", cancellation: newOwner, generation: newOwner.snapshot())
require(panel.isVisible && execute.isEnabled && newOwner.executionPaused(lease: closeLease) == true,
        "关闭后重新 show 只能展示暂停状态，不能自动恢复")
require(primaryLabel.stringValue == "AI已暂停「再次显示」页面", "重新显示暂停 toast 未使用最新标题")

// 超过旧 3 秒时限仍常驻；仅结束 lease 才收起，不截图或制造真实输入。
DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
    require(panel.isVisible, "暂停控制条仍应保持可见")
    require(!panel.isKeyWindow && !panel.isMainWindow, "控制条不应成为键盘或主窗口")
    newOwner.cancel()
    DispatchQueue.main.async {
        require(!panel.isVisible, "结束执行后未清理控制条")
        print("PASS: 原生左侧三联按钮、禁用最小化/缩放、标题栏避让、动态标题、3/2/1倒计时、关闭pause-before-dismiss、旧倒计时不复活、重新显示保持暂停、执行门禁与lease清理 BDD；未截图或发送真实输入")
        exit(0)
    }
}
NSApplication.shared.run()
