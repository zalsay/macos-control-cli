import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
func a(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func fail(_ message: String) -> Never { fputs("FAIL: \(message)\n", stderr); exit(1) }
func output(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--front" {
    output(["pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0]); exit(0)
}
guard CommandLine.arguments.count >= 4, let pid = Int32(CommandLine.arguments[1]),
      let id = UInt32(CommandLine.arguments[2]),
      let running = NSRunningApplication(processIdentifier: pid),
      ["com.apple.TextEdit", "com.apple.finder"].contains(running.bundleIdentifier ?? "") else { exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 0.5)
guard let root = (a(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first(where: {
    var actual: CGWindowID = 0
    return axWindowID($0, &actual) == .success && actual == id
}), (a(root, kAXTitleAttribute) as? String ?? "").contains("DesktopControlFixture") else { fail("只能操作本次创建的隔离测试窗口") }
let action = CommandLine.arguments[3]
if action == "geometry" {
    var size = CGSize(width: 900, height: 700), position = CGPoint(x: 80, y: 100)
    guard AXUIElementSetAttributeValue(root, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!) == .success,
          AXUIElementSetAttributeValue(root, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &position)!) == .success else { fail("无法设置隔离窗口几何") }
    exit(0)
}
if action == "close" {
    guard let raw = a(root, kAXCloseButtonAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID(),
          AXUIElementPerformAction(unsafeBitCast(raw, to: AXUIElement.self), kAXPressAction as CFString) == .success else { fail("无法关闭本次测试窗口") }
    exit(0)
}
if action == "focus" {
    guard let raw = a(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { fail("没有焦点节点") }
    let e = unsafeBitCast(raw, to: AXUIElement.self)
    var value: [String: Any] = ["role": a(e, kAXRoleAttribute) as? String ?? "", "value": a(e, kAXValueAttribute) as? String ?? ""]
    if let range = a(e, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
        var selection = CFRange()
        if AXValueGetValue(unsafeBitCast(range, to: AXValue.self), .cfRange, &selection) {
            value["selectionLocation"] = selection.location; value["selectionLength"] = selection.length
        }
    }
    output(value)
    exit(0)
}
if action == "elements" {
    var queue = [root], index = 0, values: [[String: Any]] = []
    while index < queue.count, index < 2500 {
        let e = queue[index]; index += 1
        let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { a(e, $0) as? String }.first { !$0.isEmpty } ?? ""
        if a(e, kAXRoleAttribute) as? String == kAXTextAreaRole || title.contains("DesktopControlTarget") {
            var point = CGPoint.zero, size = CGSize.zero
            if let p = a(e, kAXPositionAttribute), let s = a(e, kAXSizeAttribute),
               CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
               AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
               AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) {
                var selected = a(e, kAXSelectedAttribute) as? Bool ?? false
                var ancestor = e
                for _ in 0..<4 {
                    guard let raw = a(ancestor, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
                    ancestor = unsafeBitCast(raw, to: AXUIElement.self)
                    selected = selected || a(ancestor, kAXSelectedAttribute) as? Bool == true
                }
                values.append(["name": title, "role": a(e, kAXRoleAttribute) as? String ?? "", "x": point.x, "y": point.y,
                               "width": size.width, "height": size.height, "selected": selected])
            }
        }
        queue.append(contentsOf: a(e, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    output(["elements": values]); exit(0)
}
exit(2)
