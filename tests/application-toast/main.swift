import AppKit

func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
_ = NSApplication.shared.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first,
      let previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { exit(2) }
let toast = ChromeControlToast(desktopMode: true)
let cancellation = InputCancellation()
let target = TargetWindow(windowId: 1, pid: previousPID, bundleId: "com.apple.TextEdit")
try toast.show(over: WindowBounds(x: screen.frame.minX + 50, y: 100, width: 900, height: 700),
               target: target, title: "TextEdit · 测试文档", cancellation: cancellation, generation: 0)
guard let panel = NSApplication.shared.windows.first(where: { $0.title == "AI正在操作应用窗口..." }),
      let content = panel.contentView,
      let label = descendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "copis-chrome-toast-primary" }) else {
    fputs("FAIL: 通用应用控制条不存在\n", stderr); exit(1)
}
require(label.stringValue == "AI即将接管「TextEdit · 测试文档」窗口", "通用模式应显示应用与窗口标题")
require(!panel.canBecomeKey && !panel.canBecomeMain, "通用控制条不能抢焦点")
toast.updateTitle(target: target, title: "Finder · 测试目录", cancellation: cancellation, generation: 0)
require(label.stringValue.contains("Finder · 测试目录"), "同一目标的标题更新应生效")
cancellation.cancel()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
require(!panel.isVisible, "取消后必须收起控制条")
require(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousPID, "未产生桌面焦点切换")
print("PASS: 通用控制条应用名/窗口标题、无键盘焦点、标题更新与取消清理；未截图或发送输入")
