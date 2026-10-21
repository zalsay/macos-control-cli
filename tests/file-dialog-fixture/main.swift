import AppKit
import ApplicationServices

setbuf(stdout, nil)

@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--front-pid" {
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    exit(0)
}
guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[1]),
      let windowID = UInt32(CommandLine.arguments[2]),
      let running = NSRunningApplication(processIdentifier: pid), running.bundleIdentifier == "com.google.Chrome" else { exit(2) }
if CommandLine.arguments[3].hasPrefix("background:") {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    require(windows.contains { ($0[kCGWindowNumber as String] as? UInt32) == windowID && ($0[kCGWindowOwnerPID as String] as? Int32) == pid },
            "隔离测试窗口不存在")
    guard let previousPID = Int32(CommandLine.arguments[3].dropFirst("background:".count)), previousPID != pid,
          let previous = NSRunningApplication(processIdentifier: previousPID), !previous.isTerminated else { exit(2) }
    // 只恢复测试启动前的应用焦点，不向该应用窗口发送输入，也不预热目标 AX。
    _ = NSApplication.shared.setActivationPolicy(.accessory)
    require(previous.activate(options: []), "无法恢复原前台应用")
    let focusDeadline = ProcessInfo.processInfo.systemUptime + 2
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != previousPID {
        require(ProcessInfo.processInfo.systemUptime < focusDeadline, "无法建立 Chrome 后台条件")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    print("READY: FIXTURE_CHROME_IS_BACKGROUND")
    exit(0)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
let deadline = ProcessInfo.processInfo.systemUptime + 4
var root: AXUIElement?
repeat {
    root = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first {
        var identifier: CGWindowID = 0
        return axWindowID($0, &identifier) == .success && identifier == windowID
    }
    if root != nil { break }
    Thread.sleep(forTimeInterval: 0.05)
} while ProcessInfo.processInfo.systemUptime < deadline
guard let root else { fputs("FAIL: 无法确认隔离测试窗口\n", stderr); exit(1) }
let title = attribute(root, kAXTitleAttribute) as? String ?? ""
require(title.contains("CopisFileChooserFixture") || title.contains("CopisFileChosen:"), "只能操作隔离文件选择测试页")
let controlAction = CommandLine.arguments[3].split(separator: ":", maxSplits: 1).map(String.init)
if controlAction.count == 2, ["pause-control", "execute-control", "control-paused", "control-countdown", "control-closed", "close-control", "foreign-pointer"].contains(controlAction[0]) {
    guard let helperPID = Int32(controlAction[1]), helperPID > 0, helperPID != pid else { exit(2) }
    let helper = AXUIElementCreateApplication(helperPID)
    AXUIElementSetMessagingTimeout(helper, 0.5)
    if controlAction[0] == "control-closed" {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        require(!windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == helperPID }, "断开后控制条仍可见")
        exit(0)
    }
    if controlAction[0] == "foreign-pointer" {
        guard CGPreflightPostEventAccess(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let target = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID && ($0[kCGWindowOwnerPID as String] as? Int32) == pid }),
              let rawBounds = target[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              let source = CGEventSource(stateID: .privateState) else { exit(2) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // 同坐标 mouseMoved 可被系统合并，必须真正移动到隔离页面中的另一个空白点。
        let point = CGEvent(source: nil)?.location == center ? CGPoint(x: center.x + 24, y: center.y + 24) : center
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left) else { exit(2) }
        move.post(tap: .cghidEventTap)
        let deliveredDeadline = ProcessInfo.processInfo.systemUptime + 2
        while CGEvent(source: nil)?.location != point {
            require(ProcessInfo.processInfo.systemUptime < deliveredDeadline, "系统未投递外部测试鼠标移动，不能据此判断接管保护失效")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        print("PASS: 隔离页面中的外部测试鼠标移动已实际送达")
        exit(0)
    }
    let identifier: String
    switch controlAction[0] {
    case "pause-control": identifier = "copis-chrome-pause"
    case "close-control": identifier = "copis-chrome-close"
    default: identifier = "copis-chrome-execute"
    }
    let controlDeadline = ProcessInfo.processInfo.systemUptime + 3
    repeat {
        var queue = attribute(helper, kAXWindowsAttribute) as? [AXUIElement] ?? [], index = 0
        while index < queue.count && index < 128 {
            let node = queue[index]; index += 1
            if controlAction[0] == "control-countdown",
               attribute(node, kAXIdentifierAttribute) as? String == "copis-chrome-toast-secondary",
               let text = attribute(node, kAXValueAttribute) as? String,
               (1...3).contains(Int(text.prefix(1)) ?? 0), text.contains("秒后接管"), text.contains("请松开鼠标") {
                print("PASS: 原生控制条正在倒计时")
                exit(0)
            }
            if controlAction[0] != "control-countdown", attribute(node, kAXIdentifierAttribute) as? String == identifier {
                if attribute(node, kAXEnabledAttribute) as? Bool != true { break }
                if controlAction[0] != "control-paused" {
                    require(AXUIElementPerformAction(node, kAXPressAction as CFString) == .success, "操作隔离 helper 控制按钮失败")
                    if controlAction[0] == "close-control" {
                        let closedDeadline = ProcessInfo.processInfo.systemUptime + 2
                        repeat {
                            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                            if !windows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == helperPID }) {
                                print("PASS: toast 关闭按钮已隐藏控制条")
                                exit(0)
                            }
                            require(ProcessInfo.processInfo.systemUptime < closedDeadline, "关闭按钮未隐藏原生 toast")
                            Thread.sleep(forTimeInterval: 0.02)
                        } while true
                    }
                    // AXPress 可能先 ACK 再执行 selector；确认状态已提交后才能构造后续新输入。
                    let appliedDeadline = ProcessInfo.processInfo.systemUptime + 2
                    while attribute(node, kAXEnabledAttribute) as? Bool != false {
                        require(ProcessInfo.processInfo.systemUptime < appliedDeadline, "控制按钮动作尚未提交")
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                }
                exit(0)
            }
            queue.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        Thread.sleep(forTimeInterval: 0.04)
    } while ProcessInfo.processInfo.systemUptime < controlDeadline
    let windowCount = (attribute(helper, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
    fputs("FAIL: 隔离 helper 控制按钮未就绪（AX 窗口数：\(windowCount)）\n", stderr)
    exit(1)
}
func activateFixture() {
    // 模拟真实点击上传按钮的前置条件：目标窗口处于前台。
    require(running.activate(options: []), "无法激活隔离 Chrome")
    let focusDeadline = ProcessInfo.processInfo.systemUptime + 2
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        require(ProcessInfo.processInfo.systemUptime < focusDeadline, "隔离 Chrome 未进入前台")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}
switch CommandLine.arguments[3] {
case "activate":
    activateFixture()
    exit(0)
case "open":
    activateFixture()
    var queue = [root], index = 0
    while index < queue.count && index < 1000 {
        let node = queue[index]; index += 1
        let title = attribute(node, kAXTitleAttribute) as? String ?? ""
        let description = attribute(node, kAXDescriptionAttribute) as? String ?? ""
        if attribute(node, kAXRoleAttribute) as? String == kAXButtonRole,
           title == "Copis open test picker" || description == "Copis open test picker" {
            require(AXUIElementPerformAction(node, kAXPressAction as CFString) == .success, "打开测试文件选择框失败")
            print("PASS: 已打开隔离测试页的文件选择框")
            exit(0)
        }
        queue.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    require(false, "找不到隔离测试按钮")
case "selected":
    require(title.contains("CopisFileChosen:copis-test.txt"), "网页未收到预期的本地测试文件")
    let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
    require(!children.contains { attribute($0, kAXIdentifierAttribute) as? String == "open-panel" }, "文件选择框仍打开")
    print("PASS: 原生对话框已关闭，网页收到预期文件；未上传")
default: exit(2)
}
