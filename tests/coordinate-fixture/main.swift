import AppKit
import ApplicationServices
import ImageIO

@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}
func output(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--desktop" {
    output(["pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "screens": NSScreen.screens.map { ["x": $0.frame.minX, "y": $0.frame.minY,
                                                 "width": $0.frame.width, "height": $0.frame.height,
                                                 "scale": $0.backingScaleFactor] }])
    exit(0)
}
guard CommandLine.arguments.count >= 4, let pid = Int32(CommandLine.arguments[1]),
      let windowID = UInt32(CommandLine.arguments[2]),
      let running = NSRunningApplication(processIdentifier: pid), running.bundleIdentifier == "com.google.Chrome" else { exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
guard let root = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first(where: {
    var identifier: CGWindowID = 0
    return axWindowID($0, &identifier) == .success && identifier == windowID
}) else { fail("无法确认隔离坐标测试窗口") }
let title = attribute(root, kAXTitleAttribute) as? String ?? ""
guard title.hasPrefix("CopisCoordinateFixture") else { fail("只能操作隔离坐标测试页") }
let action = CommandLine.arguments[3]
if action == "address" || action == "focused-address" {
    var queue = action == "focused-address" ? (attribute(app, kAXFocusedUIElementAttribute).map { [unsafeBitCast($0, to: AXUIElement.self)] } ?? []) : [root]
    var index = 0
    while index < queue.count, index < 256 {
        let node = queue[index]; index += 1
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        if ["AXWebArea", "AXScrollArea"].contains(role) { continue }
        let value = attribute(node, kAXValueAttribute) as? String ?? ""
        if ["AXTextField", "AXComboBox"].contains(role), value.contains("127.0.0.1:") {
            var point = CGPoint.zero, size = CGSize.zero
            guard let p = attribute(node, kAXPositionAttribute), let s = attribute(node, kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
                  AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { fail("地址栏无可核对几何") }
            output(["x": point.x, "y": point.y, "width": size.width, "height": size.height, "focused": action == "focused-address"])
            exit(0)
        }
        if action == "address" { queue.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []) }
    }
    fail("未找到本机fixture地址栏或未真正取得焦点")
}
if action == "title" { output(["title": title]); exit(0) }
// 仅识别隔离测试页的三种固定色块，校验 CLI 图像协议的内容原点与比例。
if action == "markers", CommandLine.arguments.count == 5 {
    let url = URL(fileURLWithPath: CommandLine.arguments[4])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        fail("无法解码隔离测试图像")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { fail("无法读取测试图像像素") }
    var colors = [UInt8](repeating: 0, count: image.width * image.height)
    for index in colors.indices {
        let offset = index * 4
        let rgb = [data[offset], data[offset + 1], data[offset + 2]]
        if let channel = rgb.firstIndex(where: { $0 > 180 }),
           rgb.enumerated().allSatisfy({ $0.offset == channel || $0.element < 90 }) {
            colors[index] = UInt8(channel + 1)
        }
    }
    // 每种颜色只取最大连通色块，排除 Chrome 关闭按钮和工具栏图标。
    var limits = Array(repeating: (minX: 0, minY: 0, maxX: -1, maxY: -1), count: 3)
    var largest = [0, 0, 0]
    for start in colors.indices where colors[start] > 0 {
        let color = colors[start], channel = Int(color - 1)
        var queue = [start], index = 0
        var box = (minX: image.width, minY: image.height, maxX: -1, maxY: -1)
        colors[start] = 0
        while index < queue.count {
            let pixel = queue[index]; index += 1
            let x = pixel % image.width, y = pixel / image.width
            box.minX = min(box.minX, x); box.maxX = max(box.maxX, x)
            box.minY = min(box.minY, y); box.maxY = max(box.maxY, y)
            let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            for (nx, ny) in neighbours where nx >= 0 && nx < image.width && ny >= 0 && ny < image.height {
                let next = ny * image.width + nx
                if colors[next] == color { colors[next] = 0; queue.append(next) }
            }
        }
        if queue.count > largest[channel] { largest[channel] = queue.count; limits[channel] = box }
    }
    var result: [String: Any] = [:]
    for (index, name) in ["top", "middle", "bottom"].enumerated() {
        let box = limits[index]
        guard largest[index] > 1000 else { fail("测试图像缺少色块 \(name)") }
        result[name] = ["x": Double(box.minX + box.maxX + 1) / 2, "y": Double(box.minY + box.maxY + 1) / 2]
    }
    output(result)
    exit(0)
}

if action == "background", CommandLine.arguments.count == 5, let previousPID = Int32(CommandLine.arguments[4]),
   previousPID != pid, let previous = NSRunningApplication(processIdentifier: previousPID) {
    _ = NSApplication.shared.setActivationPolicy(.accessory)
    guard previous.activate(options: []) else { fail("无法恢复原前台应用") }
    exit(0)
}
if action == "geometry", CommandLine.arguments.count == 8,
   let x = Double(CommandLine.arguments[4]), let y = Double(CommandLine.arguments[5]),
   let width = Double(CommandLine.arguments[6]), let height = Double(CommandLine.arguments[7]) {
    var size = CGSize(width: width, height: height)
    guard AXUIElementSetAttributeValue(root, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!) == .success else { fail("无法调整隔离测试窗口尺寸") }
    var point = CGPoint(x: x, y: y)
    let value = AXValueCreate(.cgPoint, &point)!
    guard AXUIElementSetAttributeValue(root, kAXPositionAttribute as CFString, value) == .success else { fail("无法移动隔离测试窗口") }
    exit(0)
}
if action == "element", CommandLine.arguments.count == 5 {
    let name = CommandLine.arguments[4]
    var queue = [root], index = 0
    while index < queue.count, index < 5000 {
        let node = queue[index]; index += 1
        let label = attribute(node, kAXTitleAttribute) as? String ?? attribute(node, kAXDescriptionAttribute) as? String ?? ""
        if label == name {
            var point = CGPoint.zero, size = CGSize.zero
            guard let position = attribute(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let dimensions = attribute(node, kAXSizeAttribute), CFGetTypeID(dimensions) == AXValueGetTypeID(),
                  AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size) else { fail("测试控件没有屏幕几何") }
            output(["x": point.x, "y": point.y, "width": size.width, "height": size.height,
                    "value": attribute(node, kAXValueAttribute) as? String ?? ""])
            exit(0)
        }
        queue.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    fail("没有找到测试控件 \(name)")
}
exit(2)
