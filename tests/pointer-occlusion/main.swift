import AppKit

private final class ProbePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw HelperFailure(code: "TEST_FAILED", message: message) }
}
setbuf(stdout, nil)
_ = NSApplication.shared.setActivationPolicy(.accessory)
guard CommandLine.arguments.count == 2, let windowID = UInt32(CommandLine.arguments[1]) else { exit(2) }
let previous = NSWorkspace.shared.frontmostApplication
let desktop = ChromeDesktop()
let reader = WindowEventHitReader()
guard reader.isAvailable else { fputs("只读 WindowServer 命中查询在当前系统不可用\n", stderr); exit(2) }
DispatchQueue.global().async {
    var overlay: NSPanel?
    var status: Int32 = 1
    defer {
        onMain {
            overlay?.close()
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" {
                _ = previous?.activate(options: [])
            }
        }
        exit(status)
    }
    do {
        guard let window = desktop.windows().first(where: { $0.target.windowId == windowID }) else {
            throw HelperFailure(code: "WINDOW_UNAVAILABLE", message: "测试目标不可用")
        }
        let cancellation = InputCancellation()
        try desktop.activate(window.target, expected: window.bounds, cancellation: cancellation, generation: cancellation.snapshot())
        let point = CGPoint(x: window.bounds.x + window.bounds.width / 2, y: window.bounds.y + window.bounds.height / 2)
        try desktop.verifyPointer(point, target: window.target, expected: window.bounds)
        print("PASS: 前台 Chrome 的系统绘制浮层不会被误判为输入遮挡")
        overlay = onMain {
            let primary = NSScreen.screens.first!
            let frame = CGRect(x: point.x - 40, y: primary.frame.maxY - point.y - 40, width: 80, height: 80)
            let panel = ProbePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Copis pointer verification fixture"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15)
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            return panel
        }
        try desktop.verifyPointer(point, target: window.target, expected: window.bounds)
        print("PASS: ignoresMouseEvents=true 的上层绘制窗口允许下层目标校验")
        onMain { overlay?.ignoresMouseEvents = false }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while try reader.target(at: point).pid == window.target.pid {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "可拦截测试浮层未进入系统命中列表")
            Thread.sleep(forTimeInterval: 0.01)
        }
        do {
            try desktop.verifyPointer(point, target: window.target, expected: window.bounds)
            throw HelperFailure(code: "TEST_FAILED", message: "可拦截输入的真实遮挡被错误放行")
        } catch let failure as HelperFailure where failure.code == "POINTER_OBSCURED" { }
        print("PASS: 同一浮层改为接收鼠标后仍拒绝 POINTER_OBSCURED")
        onMain { overlay?.orderOut(nil) }
        let hiddenDeadline = ProcessInfo.processInfo.systemUptime + 1
        while true {
            let hit = try reader.target(at: point)
            if hit.pid == window.target.pid && hit.windowId == window.target.windowId { break }
            try require(ProcessInfo.processInfo.systemUptime < hiddenDeadline, "浮层收起后目标输入归属仍未恢复")
            Thread.sleep(forTimeInterval: 0.01)
        }
        try desktop.verifyPointer(point, target: window.target, expected: window.bounds)
        try desktop.verifyFocus(window.target, expected: window.bounds)
        print("PASS: 移除遮挡后恢复，目标精确焦点仍有效；全程未发送鼠标键盘或截图")
        status = 0
    } catch let failure as HelperFailure { fputs("FAIL: \(failure.code): \(failure.message)\n", stderr) }
    catch { fputs("FAIL: 指针归属只读回归异常\n", stderr) }
}
let keepAlive = Port()
RunLoop.main.add(keepAlive, forMode: .default)
RunLoop.main.run()
