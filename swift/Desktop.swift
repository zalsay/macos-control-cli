import Foundation
import AppKit
import ApplicationServices

func onMain<T>(_ operation: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try operation() }
    return try DispatchQueue.main.sync(execute: operation)
}

// AX/CG 查询之间焦点可能变化；两次 requireTargetFocus 都必须对 PID/窗口不匹配抛错。
func verifyStableWindowFocus<Window>(requireTargetFocus: () throws -> Window,
                                     verifyGeometry: (Window) throws -> Void) rethrows {
    let focused = try requireTargetFocus()
    try verifyGeometry(focused)
    _ = try requireTargetFocus()
}

struct ChromeWindow {
    let target: TargetWindow
    let title: String
    let bounds: WindowBounds

    var json: [String: Any] {
        ["windowId": target.windowId, "pid": target.pid, "title": title, "bounds": bounds.json]
    }
}

// AX 没有公开的 CGWindowID 属性；只用窗口 ID 精确对应，不以标题/相似坐标猜测。
@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

final class ChromeDesktop {
    private let bundleID = "com.google.Chrome"
    private let operationToast = ChromeControlToast()
    private lazy var eventHitReader = WindowEventHitReader()

    func permissions(request: Bool) -> [String: Any] {
        if request {
            onMain {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                _ = CGRequestScreenCaptureAccess()
            }
        }
        return ["screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()]
    }

    func requireScreenPermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelperFailure(code: "SCREEN_PERMISSION_REQUIRED", message: "需要在系统设置中允许屏幕录制后重试")
        }
    }

    func requireInputPermission() throws {
        guard AXIsProcessTrusted() else {
            throw HelperFailure(code: "ACCESSIBILITY_PERMISSION_REQUIRED", message: "需要在系统设置中允许辅助功能后重试")
        }
        guard CGPreflightPostEventAccess() else {
            throw HelperFailure(code: "ACCESSIBILITY_PERMISSION_REQUIRED", message: "系统尚未允许发送桌面输入事件")
        }
    }

    private func application(pid: pid_t) -> NSRunningApplication? {
        // NSWorkspace 的应用与焦点快照必须由主 RunLoop 更新。
        NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == pid && $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
    }

    private func isChrome(pid: pid_t) -> Bool { onMain { application(pid: pid) != nil } }

    private func windowList() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func decodeWindow(_ info: [String: Any], chromePIDs: Set<pid_t>) -> ChromeWindow? {
        guard let windowID = info[kCGWindowNumber as String] as? UInt32, windowID > 0,
              let pid = info[kCGWindowOwnerPID as String] as? Int32, chromePIDs.contains(pid),
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let raw = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = try? WindowBounds(json: ["x": raw["X"] ?? NSNull(), "y": raw["Y"] ?? NSNull(),
                                                   "width": raw["Width"] ?? NSNull(), "height": raw["Height"] ?? NSNull()]) else { return nil }
        return ChromeWindow(target: TargetWindow(windowId: windowID, pid: pid),
                            title: info[kCGWindowName as String] as? String ?? "", bounds: bounds)
    }

    func windows() -> [ChromeWindow] {
        let pids = onMain {
            Set(NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == bundleID && !$0.isTerminated
            }.map(\.processIdentifier))
        }
        return windowList().compactMap { decodeWindow($0, chromePIDs: pids) }
    }

    func window(_ target: TargetWindow) throws -> ChromeWindow {
        guard isChrome(pid: target.pid), let info = windowList().first(where: {
            ($0[kCGWindowNumber as String] as? UInt32) == target.windowId &&
            ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid
        }), let window = decodeWindow(info, chromePIDs: [target.pid]) else {
            throw HelperFailure(code: "WINDOW_UNAVAILABLE", message: "目标 Chrome 窗口不存在或已不再可用")
        }
        return window
    }

    func verifyGeometry(_ target: TargetWindow, expected: WindowBounds) throws {
        guard try window(target).bounds.matches(expected) else {
            throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "目标窗口位置或尺寸已变化，请重新观察")
        }
    }

    func axApplication(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        return app
    }

    func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, 0.35)
        return result
    }

    func identifier(_ window: AXUIElement) -> CGWindowID? {
        AXUIElementSetMessagingTimeout(window, 0.35)
        var value: CGWindowID = 0
        return axWindowID(window, &value) == .success && value > 0 ? value : nil
    }

    func targetAXWindow(_ target: TargetWindow, app: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let window = windows.first(where: { identifier($0) == target.windowId }) else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法精确定位目标 Chrome 的辅助功能窗口")
        }
        AXUIElementSetMessagingTimeout(window, 0.35)
        return window
    }

    private func verifyAXGeometry(_ window: AXUIElement, expected: WindowBounds) throws {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法确认辅助功能窗口的实际几何区域")
        }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "系统返回了无效的辅助功能窗口几何")
        }
        let bounds = WindowBounds(x: origin.x, y: origin.y, width: dimensions.width, height: dimensions.height)
        guard bounds.matches(expected) else {
            throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "辅助功能窗口几何已变化，请重新观察")
        }
    }

    func frontmostAXWindow(_ target: TargetWindow, app: AXUIElement) throws -> AXUIElement {
        let frontPID = onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard frontPID == target.pid else {
            throw HelperFailure(code: "FOCUS_LOST", message: "目标 Chrome 窗口未持有真实焦点，未发送输入")
        }
        // 系统级 AXFocusedApplication 可能返回 noValue；以 AXFrontmost 独立核实前台归属。
        // 仍须取得成功响应和严格布尔类型，不能把查询失败或缺值当成已聚焦。
        var frontmost: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &frontmost) == .success,
              let frontmost, CFGetTypeID(frontmost) == CFBooleanGetTypeID() else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法确认 Chrome 的辅助功能前台状态")
        }
        let axFrontmost = frontmost as! CFBoolean
        guard CFBooleanGetValue(axFrontmost) else {
            throw HelperFailure(code: "FOCUS_LOST", message: "Chrome 已失去辅助功能前台状态，未发送输入")
        }
        guard let focused = elementAttribute(app, kAXFocusedWindowAttribute) else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法读取 Chrome 当前焦点窗口")
        }
        return focused
    }

    private func focusedWindow(_ target: TargetWindow, app: AXUIElement) throws -> AXUIElement {
        let focused = try frontmostAXWindow(target, app: app)
        // 通用网页输入仍只接受精确主窗口；原生 sheet 由专用文件选择命令处理。
        guard identifier(focused) == target.windowId else {
            throw HelperFailure(code: "FOCUS_LOST", message: "目标 Chrome 窗口未持有真实焦点，未发送输入")
        }
        return focused
    }

    func verifyFocus(_ target: TargetWindow, expected: WindowBounds) throws {
        try requireInputPermission()
        try verifyGeometry(target, expected: expected)
        let app = axApplication(target.pid)
        try verifyStableWindowFocus(requireTargetFocus: {
            try self.focusedWindow(target, app: app)
        }, verifyGeometry: { focused in
            try self.verifyAXGeometry(focused, expected: expected)
            // AX 查询可能耗时，查询后再读 CG 几何，防止期间发生拖动/缩放。
            try self.verifyGeometry(target, expected: expected)
        })
    }

    func prepareInput(_ target: TargetWindow, cancellation: InputCancellation, generation: UInt64,
                      expectedEpoch: UInt64? = nil) throws -> ChromeInputPermit {
        try cancellation.check(generation)
        try requireInputPermission()
        let current = try window(target)
        _ = try cancellation.beginExecution(generation: generation)
        // 首次输入先显示 3 秒倒计时；尚未完成前不激活 Chrome 或移动指针。
        try showOperationToast(target, bounds: current.bounds, cancellation: cancellation, generation: generation)
        return try cancellation.waitForInput(generation: generation, expectedEpoch: expectedEpoch)
    }

    func activate(_ target: TargetWindow, expected: WindowBounds, cancellation: InputCancellation, generation: UInt64,
                  permit supplied: ChromeInputPermit? = nil) throws {
        let permit = try supplied ?? prepareInput(target, cancellation: cancellation, generation: generation)
        try cancellation.checkInput(permit)
        try requireInputPermission()
        try verifyGeometry(target, expected: expected)
        let app = axApplication(target.pid)
        let window = try targetAXWindow(target, app: app)
        try cancellation.checkInput(permit)
        try activateApplication(target, cancellation: cancellation, generation: generation, permit: permit)
        // 每个 AX 副作用独立提交，沿用每次 AX 调用 0.35 秒超时，不把整条链捆成一个临界区。
        _ = try cancellation.inputEffect(permit: permit) {
            AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        }
        _ = try cancellation.inputEffect(permit: permit) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        _ = try cancellation.inputEffect(permit: permit) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        // AX setter 成功不等于焦点已经切换；以真实焦点轮询结果为准，且等待有上限。
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var lastFailure: HelperFailure?
        repeat {
            try cancellation.checkInput(permit)
            do {
                try verifyFocus(target, expected: expected)
                try showOperationToast(target, bounds: expected, cancellation: cancellation, generation: generation)
                return
            }
            catch let failure as HelperFailure where failure.code == "FOCUS_LOST" || failure.code == "FOCUS_UNVERIFIED" {
                lastFailure = failure
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "激活后仍无法确认目标窗口焦点：\(lastFailure?.message ?? "未取得焦点状态")")
    }

    func activateApplication(_ target: TargetWindow, cancellation: InputCancellation, generation: UInt64,
                             permit supplied: ChromeInputPermit? = nil) throws {
        let permit = try supplied ?? prepareInput(target, cancellation: cancellation, generation: generation)
        try cancellation.checkInput(permit)
        let activated = try onMain {
            let targetApplication = application(pid: target.pid)
            // 先进入主线程再取提交锁，不能持锁等待主线程。
            return try cancellation.inputEffect(permit: permit) {
                targetApplication?.activate(options: []) ?? false
            }
        }
        guard activated else { throw HelperFailure(code: "ACTIVATION_FAILED", message: "系统未允许激活目标 Chrome 窗口") }
    }

    func showOperationToast(_ target: TargetWindow, bounds: WindowBounds, cancellation: InputCancellation, generation: UInt64) throws {
        let title = try window(target).title
        try onMain {
            try operationToast.show(over: bounds, target: target, title: title,
                                    cancellation: cancellation, generation: generation)
        }
    }

    func updateOperationToastTitle(_ target: TargetWindow, title: String,
                                   cancellation: InputCancellation, generation: UInt64) throws {
        onMain {
            operationToast.updateTitle(target: target, title: title,
                                       cancellation: cancellation, generation: generation)
        }
    }

    func verifyPointer(_ point: CGPoint, target: TargetWindow, expected: WindowBounds) throws {
        guard expected.contains(point) else { throw HelperFailure.invalidArgument }
        onMain { operationToast.avoidPointer(point) }
        try verifyPointerOwnership(target: target, eventTarget: {
            if self.eventHitReader.isAvailable { return try self.eventHitReader.target(at: point) }
            // 较旧系统缺少只读命中 SPI 时仍使用原保守检查，不能忽略未知绘制窗口。
            return try conservativePointerTarget(at: point, windows: self.windowList())
        }, accessibilityTarget: {
            try self.accessibilityPointerTarget(at: point)
        })
    }

    private func accessibilityPointerTarget(at point: CGPoint) throws -> TargetWindow {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.35)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { throw HelperFailure(code: "POINTER_UNVERIFIED", message: "无法确认鼠标目标点所属窗口") }
        var pid: pid_t = 0
        let hitWindow = elementAttribute(hit, kAXWindowAttribute) ?? hit
        guard AXUIElementGetPid(hit, &pid) == .success, pid > 0,
              let id = identifier(hitWindow) else { throw pointerUnverified() }
        return TargetWindow(windowId: id, pid: pid)
    }
}
