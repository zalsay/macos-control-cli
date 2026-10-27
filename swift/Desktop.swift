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
    let layer: Int
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
    private let toolbarStateLock = NSLock()
    private var preparedToolbar: ChromePreparedToastAnchor?
    private var selectingFileTarget: TargetWindow?


    func permissions(request: Bool) -> [String: Any] {
        if request {
            onMain {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                _ = CGRequestScreenCaptureAccess()
            }
        }
        // Keep Apple Events outside onMain: an explicit consent request can block
        // while the user decides, without blocking AppKit or changing any input lease.
        return ["screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(),
                "chromeAutomation": chromeAutomationPermission(request: request)]
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
              let layer = info[kCGWindowLayer as String] as? Int,
              let raw = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = try? WindowBounds(json: ["x": raw["X"] ?? NSNull(), "y": raw["Y"] ?? NSNull(),
                                                   "width": raw["Width"] ?? NSNull(), "height": raw["Height"] ?? NSNull()]),
              bounds.width >= 50, bounds.height >= 50 else { return nil }
        let target = TargetWindow(windowId: windowID, pid: pid, bundleId: app.bundleId)
        guard allowsWindowLayer(layer, scope: scope, verifyNativeDialog: {
            self.verifiedNativeDialog(target, bounds: bounds)
        }) else { return nil }
        return ChromeWindow(target: target, title: info[kCGWindowName as String] as? String ?? "",
                            bounds: bounds, layer: layer, appName: app.name)
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

    private func axValue(_ element: AXUIElement, _ name: String, deadline: TimeInterval? = nil,
                         timeout: TimeInterval = 0.1) -> CFTypeRef? {
        if let deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(timeout, remaining)))
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return nil }
        return status == .success ? value : nil
    }

    private func verifiedNativeDialog(_ target: TargetWindow, bounds: WindowBounds) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        let app = axApplication(target.pid)
        guard let windows = axValue(app, kAXWindowsAttribute, deadline: deadline) as? [AXUIElement] else { return false }
        for window in windows.prefix(64) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(window, Float(remaining))
            var id: CGWindowID = 0, pid: pid_t = 0
            guard axWindowID(window, &id) == .success, id == target.windowId,
                  AXUIElementGetPid(window, &pid) == .success, pid == target.pid else { continue }
            guard let role = axValue(window, kAXRoleAttribute, deadline: deadline) as? String,
                  let subrole = axValue(window, kAXSubroleAttribute, deadline: deadline) as? String,
                  let actualBounds = try? axBounds(window, deadline: deadline) else { return false }
            return NativeDialogIdentity(target: TargetWindow(windowId: id, pid: pid), bounds: actualBounds,
                                        role: role, subrole: subrole).matches(target: target, bounds: bounds)
        }
        return false
    }

    func axBounds(_ window: AXUIElement, deadline: TimeInterval? = nil) throws -> WindowBounds {
        guard let positionValue = axValue(window, kAXPositionAttribute, deadline: deadline),
              let sizeValue = axValue(window, kAXSizeAttribute, deadline: deadline),
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
        return WindowBounds(x: origin.x, y: origin.y, width: dimensions.width, height: dimensions.height)
    }

    private func verifyAXGeometry(_ window: AXUIElement, expected: WindowBounds) throws {
        guard try axBounds(window).matches(expected) else {
            throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "辅助功能窗口几何已变化，请重新观察")
        }
    }

    private func chromeToolbarAnchor(_ target: TargetWindow, window: WindowBounds) throws -> ChromePreparedToastAnchor {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        let app = axApplication(target.pid)
        func isTargetWindow(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.1, remaining)))
            var id: CGWindowID = 0, pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success && pid == target.pid &&
                axWindowID(element, &id) == .success && id == target.windowId
        }
        var root: AXUIElement?
        repeat {
            let windows = axValue(app, kAXWindowsAttribute, deadline: deadline) as? [AXUIElement] ?? []
            root = windows.first(where: isTargetWindow)
            if root == nil, let raw = axValue(app, kAXFocusedWindowAttribute, deadline: deadline),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                // AppKit sheet出现时AXWindows可能短暂无值；沿原生焦点窗口的父链找回精确主窗。
                // 仍逐节点验证PID/CGWindowID，不按标题或近似坐标替代身份检查。
                var element = unsafeBitCast(raw, to: AXUIElement.self)
                for _ in 0..<8 {
                    if isTargetWindow(element) { root = element; break }
                    guard let parent = axValue(element, kAXParentAttribute, deadline: deadline),
                          CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    element = unsafeBitCast(parent, to: AXUIElement.self)
                }
            }
            if root == nil { Thread.sleep(forTimeInterval: 0.02) }
        } while root == nil && ProcessInfo.processInfo.systemUptime < deadline - 0.15
        guard let root else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法定位Chrome原生工具栏窗口，请显示浏览器工具栏后重试")
        }
        var queue = [root], index = 0, bottom: Double?
        while index < queue.count && index < 256 && ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue[index]; index += 1
            guard let role = axValue(element, kAXRoleAttribute, deadline: deadline) as? String else { continue }
            if ["AXWebArea", "AXScrollArea", "AXSheet", "AXTextArea"].contains(role) { continue }
            if role == "AXToolbar", let bar = try? axBounds(element, deadline: deadline),
               bar.width >= window.width * 0.65, bar.y >= window.y,
               bar.y + bar.height <= window.y + min(160, window.height) {
                bottom = min(bottom ?? .greatestFiniteMagnitude, bar.y + bar.height)
            }
            if let children = axValue(element, kAXChildrenAttribute, deadline: deadline) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, let bottom else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法确认Chrome标签栏和地址栏区域，请显示浏览器工具栏后重试")
        }
        let toolbar = WindowBounds(x: window.x, y: window.y, width: window.width, height: bottom - window.y)
        return ChromePreparedToastAnchor(target: target, anchor: ChromeToastAnchor(window: window, toolbar: toolbar), windowElement: root)
    }

    func prepareToolbarAnchor(_ current: ChromeWindow) {
        guard current.target.bundleId == "com.google.Chrome" else { return }
        let prepared = AXIsProcessTrusted() ? try? chromeToolbarAnchor(current.target, window: current.bounds) : nil
        toolbarStateLock.lock(); defer { toolbarStateLock.unlock() }
        preparedToolbar = prepared
    }

    func setSelectingFile(_ target: TargetWindow, active: Bool) {
        toolbarStateLock.lock(); defer { toolbarStateLock.unlock() }
        if active { selectingFileTarget = target }
        else if selectingFileTarget.map({ sameToastTarget($0, target) }) == true { selectingFileTarget = nil }
    }

    // AppKit 模态框出现后 AXWindows 可能暂时无法枚举；只沿先前验证的精确主窗确认原生子 sheet。
    // 这里只验证控制条的位置缓存，不授予文件选择或通用输入权限。
    private func focusedOpenPanel(_ target: TargetWindow, root: AXUIElement) -> FileDialogIdentity? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        guard AXIsProcessTrusted(), identifier(root) == target.windowId else { return nil }
        var rootPID: pid_t = 0
        guard AXUIElementGetPid(root, &rootPID) == .success, rootPID == target.pid else { return nil }
        let app = axApplication(target.pid)
        // 模态切换使用现有文件选择输入相同的 AX 超时，并由总预算限制；普通工具栏查询仍用 0.1 秒。
        guard let raw = axValue(app, kAXFocusedWindowAttribute, deadline: deadline, timeout: 0.35),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let focused = raw as! AXUIElement
        guard let role = axValue(focused, kAXRoleAttribute, deadline: deadline, timeout: 0.35) as? String, role == kAXSheetRole,
              let name = axValue(focused, kAXIdentifierAttribute, deadline: deadline, timeout: 0.35) as? String, name == "open-panel",
              let children = axValue(root, kAXChildrenAttribute, deadline: deadline, timeout: 0.35) as? [AXUIElement],
              children.contains(where: { CFEqual($0, focused) }) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, let id = identifier(focused),
              ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return FileDialogIdentity(windowId: id, pid: pid, role: role, identifier: name)
    }

    private func fileSelectionToastAnchor(_ current: ChromeWindow) -> ChromeToastAnchor? {
        toolbarStateLock.lock()
        let cached = preparedToolbar
        let selecting = selectingFileTarget
        toolbarStateLock.unlock()
        guard let cached, cached.matches(target: current.target, window: current.bounds) else { return nil }
        if let anchor = cached.forFileSelection(target: current.target, window: current.bounds, selecting: selecting) { return anchor }
        guard let root = cached.windowElement, let panel = focusedOpenPanel(current.target, root: root) else { return nil }
        return cached.forFileSelection(target: current.target, window: current.bounds, selecting: nil, focusedPanel: panel)
    }

    private func toastAnchor(_ target: TargetWindow) throws -> ChromeToastAnchor {
        let current = try window(target)
        guard current.target.bundleId == "com.google.Chrome" else {
            return ChromeToastAnchor(window: current.bounds, toolbar: nil)
        }
        // 既覆盖 select-file 执行期间，也覆盖点击上传后、下一次工具调用前的模态等待期。
        // 仅同一窗口、相同几何、精确原生子 sheet 可复用；输入仍经过独立的焦点和文件框校验。
        if let anchor = fileSelectionToastAnchor(current) { return anchor }
        do {
            let prepared = try chromeToolbarAnchor(target, window: current.bounds)
            toolbarStateLock.lock(); preparedToolbar = prepared; toolbarStateLock.unlock()
            return prepared.anchor
        } catch {
            // 首次查询可能恰逢 sheet 尚未发布；工具栏查询失败后只再读一次，并重新核实身份/几何。
            // 同时重读 selecting 状态，防止在途的旧定位查询把刚开始的 select-file 误暂停。
            if let anchor = fileSelectionToastAnchor(try window(target)) { return anchor }
            throw error
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

    func verifyFocus(_ target: TargetWindow, expected: WindowBounds, allowNonKeyDialog: Bool = false) throws {
        try requireInputPermission()
        let current = try window(target)
        guard current.bounds.matches(expected) else {
            throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "目标窗口位置或尺寸已变化，请重新观察")
        }
        let pointerDialog = allowNonKeyDialog && current.layer != 0
        let app = axApplication(target.pid)
        try verifyStableWindowFocus(requireTargetFocus: {
            // 非激活原生面板不持有键盘焦点；仅指针动作可用已验证的原生窗口身份替代 key-window 要求。
            // 前台进程及 AXFrontmost 仍须属于目标应用，实际输入窗口仍由 SLS/AX/SLS 复核。
            if pointerDialog { return try self.frontmostAXWindow(target, app: app) }
            return try self.focusedWindow(target, app: app)
        }, verifyGeometry: { focused in
            if !pointerDialog { try self.verifyAXGeometry(focused, expected: expected) }
            // AX 查询可能耗时，查询后再读 CG 几何及原生角色，防止期间发生拖动/替换。
            try self.verifyGeometry(target, expected: expected)
        })
    }

    func prepareInput(_ target: TargetWindow, cancellation: InputCancellation, generation: UInt64,
                      expectedEpoch: UInt64? = nil, operation: String? = nil) throws -> ChromeInputPermit {
        try cancellation.check(generation)
        try requireInputPermission()
        let current = try window(target)
        _ = try cancellation.beginExecution(generation: generation)
        // 首次输入先显示 3 秒倒计时；尚未完成前不激活 Chrome 或移动指针。
        try showOperationToast(target, bounds: current.bounds, cancellation: cancellation, generation: generation, operation: operation)
        return try cancellation.waitForInput(generation: generation, expectedEpoch: expectedEpoch)
    }

    func activate(_ target: TargetWindow, expected: WindowBounds, cancellation: InputCancellation, generation: UInt64,
                  permit supplied: ChromeInputPermit? = nil, allowNonKeyDialog: Bool = false) throws {
        let permit = try supplied ?? prepareInput(target, cancellation: cancellation, generation: generation)
        try cancellation.checkInput(permit)
        try requireInputPermission()
        try verifyGeometry(target, expected: expected)
        // 冷启动的后台应用可能尚未发布 AXWindows；在既有输入许可与身份校验后先激活，再查精确窗口。
        try activateApplication(target, cancellation: cancellation, generation: generation, permit: permit)
        let app = axApplication(target.pid)
        let window = try targetAXWindow(target, app: app)
        try cancellation.checkInput(permit)
        // 不强制把非激活原生面板变成主窗口；键盘输入仍必须取得精确 key-window 焦点。
        let nativeDialog = try self.window(target).layer != 0
        if !nativeDialog || !allowNonKeyDialog {
            _ = try cancellation.inputEffect(permit: permit) {
                AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
            }
        }
        if !nativeDialog {
            _ = try cancellation.inputEffect(permit: permit) {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
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
                try verifyFocus(target, expected: expected, allowNonKeyDialog: allowNonKeyDialog)
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

    func showOperationToast(_ target: TargetWindow, bounds: WindowBounds, cancellation: InputCancellation,
                            generation: UInt64, operation: String? = nil) throws {
        let current = try window(target)
        let title = scope == .desktop ? "\(current.appName) · \(current.title)" : current.title
        let anchor = try toastAnchor(target)
        try onMain {
            try operationToast.show(over: anchor.window, target: target, title: title, toolbar: anchor.toolbar,
                                    operation: operation, anchorProvider: { [weak self] in
                guard let self else { return nil }
                return try? self.toastAnchor(target)
            }, cancellation: cancellation, generation: generation)
        }
    }

    func updateOperation(_ target: TargetWindow, label: String? = nil, finished: Bool,
                         succeeded: Bool = true, cancellation: InputCancellation, generation: UInt64) {
        onMain {
            operationToast.updateOperation(target: target, label: label, finished: finished, succeeded: succeeded,
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

    func verifyPointer(_ point: CGPoint, target: TargetWindow, expected: WindowBounds, allowNonKeyDialog: Bool = false, checkInput: () throws -> Void = {}) throws {
        guard expected.contains(point) else { throw HelperFailure.invalidArgument }
        let moved = onMain { operationToast.avoidPointer(point) }
        let verify = {
            try verifyPointerOwnership(target: target, eventTarget: {
                if self.eventHitReader.isAvailable { return try self.eventHitReader.target(at: point) }
                // 较旧系统缺少只读命中 SPI 时仍使用原保守检查，不能忽略未知绘制窗口。
                return try conservativePointerTarget(at: point, windows: self.windowList())
            }, accessibilityTarget: {
                try self.accessibilityPointerTarget(at: point, nativeDialogTarget: {
                    guard allowNonKeyDialog, self.scope == .desktop else { return nil }
                    let current = try self.window(target)
                    guard current.layer != 0 else { return nil }
                    guard current.bounds.matches(expected) else {
                        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "原生弹窗几何已变化，请重新观察")
                    }
                    return current.target
                })
            })
        }
        if moved {
            try waitForPointerAfterToastMove(check: {
                try checkInput()
                try self.verifyFocus(target, expected: expected, allowNonKeyDialog: allowNonKeyDialog)
            }, verify: verify)
        } else { try verify() }
    }

    private func accessibilityPointerTarget(at point: CGPoint, nativeDialogTarget: () throws -> TargetWindow?) throws -> TargetWindow {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.35)
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        return try resolveAccessibilityPointerTarget(status: status, windowServerHitAvailable: eventHitReader.isAvailable, hitTarget: {
            guard let hit else { throw pointerUnverified() }
            var pid: pid_t = 0
            let hitWindow = self.elementAttribute(hit, kAXWindowAttribute) ?? hit
            guard AXUIElementGetPid(hit, &pid) == .success, pid > 0,
                  let id = self.identifier(hitWindow) else { throw pointerUnverified() }
            return TargetWindow(windowId: id, pid: pid)
        }, nativeDialogTarget: nativeDialogTarget)
    }
}
