import AppKit

func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func pump(_ duration: TimeInterval = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }
func requireVisibleControls(_ panel: NSWindow) {
    guard let background = panel.contentView else { require(false, "缺少控制条内容区"); return }
    background.layoutSubtreeIfNeeded()
    let views = descendants(background)
    // stringValue 正确不代表可见；底边偏移写反时，控件仍存在但全部落到内容区外。
    for identifier in ["copis-chrome-toast-primary", "copis-chrome-toast-secondary", "copis-chrome-toast-logo",
                       "copis-chrome-execute", "copis-chrome-pause"] {
        guard let view = views.first(where: { $0.accessibilityIdentifier() == identifier }) else {
            require(false, "缺少控件：\(identifier)"); return
        }
        let rect = view.convert(view.bounds, to: background)
        require(rect.width > 0 && rect.height > 0 && background.bounds.contains(rect) && !view.isHiddenOrHasHiddenAncestor,
                "控件必须完整位于内容区：\(identifier)，frame=\(rect)，content=\(background.bounds)")
    }
}
_ = NSApplication.shared.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first, let previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { exit(2) }
let toast = ChromeControlToast()
var now: TimeInterval = 100
let cancellation = InputCancellation(clock: { now })
let target = TargetWindow(windowId: 1, pid: previousPID)
let anchorLock = NSLock(), probeStarted = DispatchSemaphore(value: 0), releaseProbe = DispatchSemaphore(value: 0)
var blockProbe = false, probeCount = 0
var anchor: ChromeToastAnchor? = ChromeToastAnchor(window: WindowBounds(x: 100, y: 100, width: 1000, height: 700),
                                                 toolbar: WindowBounds(x: 100, y: 100, width: 1000, height: 86))
let provider: () -> ChromeToastAnchor? = {
    anchorLock.lock(); let value = anchor, blocked = blockProbe; probeCount += 1; anchorLock.unlock()
    if blocked { probeStarted.signal(); releaseProbe.wait() }
    return value
}
try toast.show(over: anchor!.window, target: target, title: "测试页面", toolbar: anchor!.toolbar,
               operation: "点击", anchorProvider: provider, cancellation: cancellation, generation: 0)
guard let panel = NSApplication.shared.windows.first(where: { $0.title == "AI正在操作Chrome窗口..." }),
      let background = panel.contentView as? NSVisualEffectView else { require(false, "缺少毛玻璃面板"); exit(1) }
let views = descendants(background)
guard let primary = views.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-toast-primary" }),
      let secondary = views.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-toast-secondary" }),
      let close = panel.standardWindowButton(.closeButton) else { exit(1) }
require(panel.frame.height == 72 && background.material == .hudWindow && background.blendingMode == .behindWindow && background.state == .active,
        "保持当前毛玻璃，仅压缩为顶部72pt提示条")
require(!panel.canBecomeKey && !panel.canBecomeMain, "不能抢键盘焦点")
require(secondary.stringValue.contains("将点击"), "倒计时显示待执行操作")
require(!primary.stringValue.isEmpty, "主标题不能空白")
requireVisibleControls(panel)
for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
    guard let button = panel.standardWindowButton(kind), let parent = button.superview else { exit(1) }
    let rect = parent.convert(button.frame, to: background)
    require(!rect.intersects(primary.frame) && !rect.intersects(secondary.frame), "紧凑模式文字不能覆盖系统三联按钮")
}
now += 3; pump()
require(secondary.stringValue == "正在：点击", "运行时显示当前操作")
requireVisibleControls(panel)
toast.updateOperation(target: target, label: "输入文字", finished: false, succeeded: true, cancellation: cancellation, generation: 0)
require(secondary.stringValue == "正在：输入文字", "输入状态不包含输入内容")
toast.updateOperation(target: target, label: nil, finished: true, succeeded: true, cancellation: cancellation, generation: 0)
require(secondary.stringValue == "已完成：输入文字", "完成状态不能继续假装在执行")
requireVisibleControls(panel)
let original = panel.frame
anchorLock.lock()
anchor = ChromeToastAnchor(window: WindowBounds(x: 220, y: 160, width: 1000, height: 700), toolbar: WindowBounds(x: 220, y: 160, width: 1000, height: 86))
anchorLock.unlock()
pump(0.4)
require(panel.frame.minX - original.minX == 120 && panel.frame.minY - original.minY == -60, "提示条随目标窗口移动")
let covered = CGPoint(x: panel.frame.midX, y: screen.frame.maxY - panel.frame.midY)
let y = panel.frame.minY
toast.avoidPointer(covered)
require(panel.frame.minY == y && !panel.frame.contains(CGPoint(x: covered.x, y: screen.frame.maxY - covered.y)), "只横向避让，不进入网页")
let avoided = panel.frame; pump()
require(panel.frame == avoided, "定位timer不能把避让后的控制条移回鼠标目标")
// Given 最窄的受支持工具栏，Then 文本可以截断，但两行文字、Logo 与操作按钮不能被裁出窗口。
anchorLock.lock()
anchor = ChromeToastAnchor(window: WindowBounds(x: 220, y: 160, width: 328, height: 700),
                          toolbar: WindowBounds(x: 220, y: 160, width: 328, height: 86))
anchorLock.unlock()
try toast.show(over: anchor!.window, target: target, title: String(repeating: "很长的页面标题", count: 20), toolbar: anchor!.toolbar,
               anchorProvider: provider, cancellation: cancellation, generation: 0)
require(panel.frame.width == 320, "覆盖最小320pt提示条")
requireVisibleControls(panel)
anchorLock.lock(); blockProbe = true; anchorLock.unlock()
pump(0.4)
require(probeStarted.wait(timeout: .now()) == .success, "模拟的定位查询必须已在后台等待")
anchorLock.lock(); let beforeRepeatedShow = probeCount; anchorLock.unlock()
for _ in 0..<2 {
    try toast.show(over: anchor!.window, target: target, title: "重复显示", toolbar: anchor!.toolbar,
                   anchorProvider: provider, cancellation: cancellation, generation: 0)
    pump(0.4)
}
close.performClick(nil)
require(!panel.isVisible, "定位查询在途时，关闭也应立即暂停并隐藏")
anchorLock.lock(); blockProbe = false; anchorLock.unlock()
releaseProbe.signal(); pump(0.5)
anchorLock.lock(); let afterRepeatedShow = probeCount; anchorLock.unlock()
require(afterRepeatedShow == beforeRepeatedShow, "重复show不能给后台队列追加过期定位任务")
require(!panel.isVisible, "迟到的定位结果不能复活控制条")
toast.updateOperation(target: target, label: "观察页面", finished: false, succeeded: true, cancellation: cancellation, generation: 0)
anchorLock.lock()
anchor = ChromeToastAnchor(window: WindowBounds(x: 300, y: 200, width: 1000, height: 700), toolbar: WindowBounds(x: 300, y: 200, width: 1000, height: 86)); anchorLock.unlock(); pump()
require(!panel.isVisible, "关闭后标题/操作/定位timer都不能复活控制条")
cancellation.cancel()
do {
    try toast.show(over: WindowBounds(x: 100, y: 100, width: 1000, height: 600), target: target,
                   toolbar: WindowBounds(x: 100, y: 100, width: 1000, height: 30),
                   operation: "点击", cancellation: cancellation, generation: cancellation.snapshot())
    require(false, "顶部区域不足必须拒绝显示和输入")
} catch let error as HelperFailure { require(error.code == "FOCUS_UNVERIFIED", "保留布局错误") }
require(!panel.isVisible, "布局失败不能留下旧位置的控制条")
do {
    _ = try cancellation.beginInput(generation: cancellation.snapshot())
    require(false, "布局失败后不能继续运行输入")
} catch let error as HelperFailure { require(error.code == "USER_PAUSED", "布局失败应保留暂停门禁") }
cancellation.cancel()
require(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousPID, "整个对象回归不切换用户应用")
print("PASS: 顶部紧凑毛玻璃、560/320pt控件可见范围、当前操作/完成状态、窗口跟随、横向避让与关闭不复活；未截图/投递输入")
