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
    var appName = "Chrome"

    var json: [String: Any] {
        ["windowId": target.windowId, "pid": target.pid, "title": title, "bounds": bounds.json,
         "bundleId": target.bundleId ?? "com.google.Chrome", "appName": appName]
    }
}

// AX 没有公开的 CGWindowID 属性；只用窗口 ID 精确对应，不以标题/相似坐标猜测。
@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

final class ChromeDesktop {
    let scope: DesktopScope
    private let operationToast: ChromeControlToast

    init(scope: DesktopScope = .chrome) {
        self.scope = scope
        operationToast = ChromeControlToast(desktopMode: scope == .desktop)
    }
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

    private func applications() -> [DesktopApplication] {
        onMain {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      let bundleId = app.bundleIdentifier else { return nil }
                let record = DesktopApplication(pid: app.processIdentifier, bundleId: bundleId,
                                                name: app.localizedName ?? bundleId, regular: app.activationPolicy == .regular)
                return record.allowed(in: scope) ? record : nil
            }
        }
    }

    private func application(pid: pid_t) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == pid && !$0.isTerminated && $0.activationPolicy == .regular &&
                (scope == .desktop || $0.bundleIdentifier == "com.google.Chrome")
        }
    }

    private func windowList() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func decodeWindow(_ info: [String: Any], applications: [DesktopApplication]) -> ChromeWindow? {
        guard let windowID = info[kCGWindowNumber as String] as? UInt32, windowID > 0,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let app = applications.first(where: { $0.pid == pid }),
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let raw = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = try? WindowBounds(json: ["x": raw["X"] ?? NSNull(), "y": raw["Y"] ?? NSNull(),
                                                   "width": raw["Width"] ?? NSNull(), "height": raw["Height"] ?? NSNull()]),
              bounds.width >= 50, bounds.height >= 50 else { return nil }
        return ChromeWindow(target: TargetWindow(windowId: windowID, pid: pid, bundleId: app.bundleId),
                            title: info[kCGWindowName as String] as? String ?? "", bounds: bounds, appName: app.name)
    }

    func windows() -> [ChromeWindow] {
        let allowed = applications()
        return windowList().compactMap { decodeWindow($0, applications: allowed) }
    }

    func apps() -> [[String: Any]] {
        let visiblePIDs = Set(windows().map { $0.target.pid })
        return applications().filter { visiblePIDs.contains($0.pid) }.map(\.json)
    }

    func window(_ target: TargetWindow) throws -> ChromeWindow {
        let allowed = applications()
        guard let app = allowed.first(where: { $0.pid == target.pid }) else {
            throw HelperFailure(code: "WINDOW_UNAVAILABLE", message: "目标应用已退出或不支持普通窗口控制")
        }
        try verifyApplicationIdentity(target, application: app, scope: scope)
        guard let info = windowList().first(where: {
            ($0[kCGWindowNumber as String] as? UInt32) == target.windowId &&
            ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid
        }), let window = decodeWindow(info, applications: allowed) else {
            throw HelperFailure(code: "WINDOW_UNAVAILABLE", message: "指定应用窗口已不可用，请重新列出窗口")
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
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法精确定位目标应用的辅助功能窗口")
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
            throw HelperFailure(code: "FOCUS_LOST", message: "目标应用 窗口未持有真实焦点，未发送输入")
        }
        // 系统级 AXFocusedApplication 可能返回 noValue；以 AXFrontmost 独立核实前台归属。
        // 仍须取得成功响应和严格布尔类型，不能把查询失败或缺值当成已聚焦。
        var frontmost: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &frontmost) == .success,
              let frontmost, CFGetTypeID(frontmost) == CFBooleanGetTypeID() else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法确认 目标应用的辅助功能前台状态")
        }
        let axFrontmost = frontmost as! CFBoolean
        guard CFBooleanGetValue(axFrontmost) else {
            throw HelperFailure(code: "FOCUS_LOST", message: "目标应用已失去辅助功能前台状态，未发送输入")
        }
        guard let focused = elementAttribute(app, kAXFocusedWindowAttribute) else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法读取 目标应用当前焦点窗口")
        }
        return focused
    }

    private func focusedWindow(_ target: TargetWindow, app: AXUIElement) throws -> AXUIElement {
        let focused = try frontmostAXWindow(target, app: app)
        // 通用网页输入仍只接受精确主窗口；原生 sheet 由专用文件选择命令处理。
        guard identifier(focused) == target.windowId else {
            throw HelperFailure(code: "FOCUS_LOST", message: "目标应用 窗口未持有真实焦点，未发送输入")
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
        // 冷启动的后台应用可能尚未发布 AXWindows；在既有输入许可与身份校验后先激活，再查精确窗口。
        try activateApplication(target, cancellation: cancellation, generation: generation, permit: permit)
        let app = axApplication(target.pid)
        let window = try targetAXWindow(target, app: app)
        try cancellation.checkInput(permit)
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
        _ = try window(target)
        let activated = try onMain {
            let targetApplication = application(pid: target.pid)
            // 先进入主线程再取提交锁，不能持锁等待主线程。
            return try cancellation.inputEffect(permit: permit) {
                guard targetApplication?.bundleIdentifier == (target.bundleId ?? "com.google.Chrome") else { return false }
                return targetApplication?.activate(options: []) ?? false
            }
        }
        guard activated else { throw HelperFailure(code: "ACTIVATION_FAILED", message: "系统未允许激活目标应用 窗口") }
    }

    func showOperationToast(_ target: TargetWindow, bounds: WindowBounds, cancellation: InputCancellation, generation: UInt64) throws {
        let current = try window(target)
        let title = scope == .desktop ? "\(current.appName) · \(current.title)" : current.title
        try onMain {
            try operationToast.show(over: bounds, target: target, title: title,
                                    cancellation: cancellation, generation: generation)
        }
    }

    func updateOperationToastTitle(_ target: TargetWindow, title: String,
                                   cancellation: InputCancellation, generation: UInt64) throws {
        let displayTitle: String
        if scope == .desktop {
            guard let current = try? window(target) else { return }
            displayTitle = "\(current.appName) · \(title)"
        } else { displayTitle = title }
        onMain {
            operationToast.updateTitle(target: target, title: displayTitle,
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
