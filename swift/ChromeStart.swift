import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices

// Chrome defines a `tab` scripting term. Initialize a real HT outside its tell block.
let chromeReceiptSeparatorScript = "set mccReceiptSeparator to character id 9"

func validateChromeAutomationPermission(_ status: OSStatus) throws {
    switch status {
    case OSStatus(noErr), OSStatus(procNotFound):
        // For cold launch the target does not yet exist. The normal Apple Events
        // launch path still enforces OS authorization; this is not an exemption.
        return
    case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent):
        throw HelperFailure(code: "AUTOMATION_PERMISSION_REQUIRED",
                            message: "请本人在macOS系统设置→隐私与安全性→自动化中允许当前宿主控制Google Chrome；尚未创建窗口，不会自动点击授权")
    default:
        throw HelperFailure(code: "AUTOMATION_UNVERIFIED", message: "无法确认Chrome自动化权限；尚未创建窗口")
    }
}

// Shared by startup (query-only) and the existing explicit permissions command.
func chromeAutomationStatus(request: Bool) -> OSStatus {
    var descriptor = AEAddressDesc()
    let bundle = Array("com.google.Chrome".utf8)
    let created = bundle.withUnsafeBytes { bytes in
        AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &descriptor)
    }
    guard created == noErr else { return OSStatus(created) }
    defer { AEDisposeDesc(&descriptor) }
    // The caller is the native action queue, never the AppKit main thread.
    // true only follows the user's explicit permissions --request; it does not grant consent.
    return AEDeterminePermissionToAutomateTarget(&descriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), request)
}

func chromeAutomationPermission(request: Bool,
                                determine: (Bool) -> OSStatus = chromeAutomationStatus) -> [String: Any] {
    let code = determine(request)
    let status: String
    switch code {
    case OSStatus(noErr): status = "granted"
    case OSStatus(errAEEventWouldRequireUserConsent): status = "requires_consent"
    case OSStatus(errAEEventNotPermitted): status = "denied"
    case OSStatus(procNotFound): status = "target_not_running"
    default: status = "unverified"
    }
    return ["target": "com.google.Chrome", "requested": request,
            "granted": code == noErr, "status": status, "osStatus": code]
}

private func requireChromeAutomationPermission() throws {
    try validateChromeAutomationPermission(chromeAutomationStatus(request: false))
}

// Full-height resizing at the probe's old y is clamped by WindowServer.
// Keep order explicit and fail before the next effect when either setter fails.
func applyChromeStartGeometry(position: () throws -> AXError, size: () throws -> AXError) throws {
    guard try position() == .success else {
        throw HelperFailure(code: "CHROME_LAYOUT_FAILED", message: "Chrome 新窗口拒绝应用目标位置")
    }
    guard try size() == .success else {
        throw HelperFailure(code: "CHROME_LAYOUT_FAILED", message: "Chrome 新窗口拒绝应用目标尺寸")
    }
}

struct ChromeWindowIdentity: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

struct ChromeCreationReceipt {
    let appleScriptWindowID: String
    let bounds: WindowBounds
}

struct ChromeStartLayout {
    let bounds: WindowBounds
    let widthPixels: Int
    let availableWidthPixels: Int
    let heightPixels: Int
    let scale: Double
    let maxWidthPx: Int

    func json(measuredBounds: WindowBounds) throws -> [String: Any] {
        let measured = try originalWindowPixelSize(width: measuredBounds.width * scale,
                                                   height: measuredBounds.height * scale)
        guard measured.width <= maxWidthPx else {
            throw HelperFailure(code: "CHROME_WIDTH_CAP_UNMET",
                                message: "Chrome 新窗口最小宽度超过 maxWidthPx，未尝试调整其他窗口")
        }
        return ["bounds": measuredBounds.json, "widthPx": measured.width,
                "heightPx": measured.height, "scale": scale, "maxWidthPx": maxWidthPx,
                "availableWidthPx": availableWidthPixels, "availableHeightPx": heightPixels]
    }
}

private struct ChromeStartBudget {
    // Keep at least five seconds of response/cleanup headroom below the helper RPC's 45s cap.
    private let deadline: TimeInterval

    init(timeout: TimeInterval = 38) {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    func check(_ cancellation: InputCancellation, permit: StartupPermit) throws {
        try cancellation.checkSetup(permit)
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw HelperFailure(code: "CHROME_START_TIMEOUT", message: "Chrome startup 超过共享 38 秒预算")
        }
    }

    func remaining(_ cancellation: InputCancellation, permit: StartupPermit,
                   maximum: TimeInterval = 20) throws -> TimeInterval {
        try check(cancellation, permit: permit)
        return min(maximum, deadline - ProcessInfo.processInfo.systemUptime)
    }

    func stageDeadline(_ cancellation: InputCancellation, permit: StartupPermit,
                       maximum: TimeInterval) throws -> TimeInterval {
        try check(cancellation, permit: permit)
        return min(deadline, ProcessInfo.processInfo.systemUptime + maximum)
    }
}

func chromeStartLayout(visibleFrame: CGRect, primaryFrame: CGRect, scale: Double,
                       maxWidthPx: Int) throws -> ChromeStartLayout {
    let values = [Double(visibleFrame.minX), Double(visibleFrame.minY), Double(visibleFrame.width),
                  Double(visibleFrame.height), Double(primaryFrame.minX), Double(primaryFrame.minY),
                  Double(primaryFrame.maxY), scale]
    guard values.allSatisfy(\.isFinite), visibleFrame.width > 0, visibleFrame.height > 0,
          primaryFrame.width > 0, primaryFrame.height > 0, scale > 0,
          (400...1600).contains(maxWidthPx) else {
        throw HelperFailure.invalidArgument
    }
    let availablePixelsValue = floor(Double(visibleFrame.width) * scale + 1e-8)
    let heightPixelsValue = Double(visibleFrame.height) * scale
    guard availablePixelsValue.isFinite, heightPixelsValue.isFinite,
          availablePixelsValue >= 1,
          availablePixelsValue <= Double(Int.max),
          abs(heightPixelsValue - heightPixelsValue.rounded()) < 0.001 else {
        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "主屏可用区域无法映射为完整原始像素")
    }
    let widthPixels = min(maxWidthPx, Int(availablePixelsValue))
    guard widthPixels >= 1 else {
        throw HelperFailure(code: "CHROME_LAYOUT_TOO_SMALL", message: "主屏可用像素宽度不足，无法创建 Chrome 窗口")
    }
    let pixelSize = try originalWindowPixelSize(width: Double(widthPixels), height: heightPixelsValue)
    let x = Double(visibleFrame.minX)
    // AX/CG 的顶左坐标以主显示器顶部为 y=0；AppKit visibleFrame 使用左下原点。
    let y = Double(primaryFrame.maxY - visibleFrame.maxY)
    let width = Double(widthPixels) / scale
    let height = Double(visibleFrame.height)
    guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "主屏布局坐标无效")
    }
    return ChromeStartLayout(bounds: WindowBounds(x: x, y: y, width: width, height: height),
                             widthPixels: pixelSize.width, availableWidthPixels: Int(availablePixelsValue), heightPixels: pixelSize.height,
                             scale: scale, maxWidthPx: maxWidthPx)
}

// Two per-request geometry probes let the AppleScript object receipt be causally
// associated with one CGWindow: only that exact object is moved from A to B.
func chromeCreationProbeBounds(layout: ChromeStartLayout, nonce: UUID) throws -> (first: WindowBounds, second: WindowBounds) {
    let height = layout.bounds.height
    let maxInset = min(180, Int(floor((height - 220) / 3)))
    guard maxInset >= 2 else {
        throw HelperFailure(code: "CHROME_RECEIPT_UNAVAILABLE",
                            message: "主屏可用高度不足以安全验证 Chrome 新窗口创建 receipt")
    }
    let bytes = withUnsafeBytes(of: nonce.uuid) { Array($0) }
    func inset(_ byteIndex: Int) -> Double { Double(Int(bytes[byteIndex % bytes.count]) % maxInset + 1) }
    let firstTop = inset(0), firstBottom = inset(1)
    var secondTop = inset(2), secondBottom = inset(3)
    if firstTop == secondTop && firstBottom == secondBottom {
        secondBottom = Double(Int(secondBottom) % maxInset + 1)
    }
    if firstTop == secondTop && firstBottom == secondBottom {
        secondTop = Double(Int(secondTop) % maxInset + 1)
    }
    func make(_ topInset: Double, _ bottomInset: Double) -> WindowBounds {
        WindowBounds(x: layout.bounds.x, y: layout.bounds.y + topInset,
                     width: layout.bounds.width,
                     height: layout.bounds.height - topInset - bottomInset)
    }
    let first = make(firstTop, firstBottom)
    let second = make(secondTop, secondBottom)
    guard !sameBounds(first, second, tolerance: 0.01), first.height >= 220, second.height >= 220 else {
        throw HelperFailure(code: "CHROME_RECEIPT_UNAVAILABLE", message: "无法构造两个不同且安全的 Chrome receipt 几何探针")
    }
    return (first, second)
}

func parseChromeCreationReceipt(_ output: String, expectedBounds: WindowBounds,
                                tolerance: Double = 0.75) throws -> ChromeCreationReceipt {
    let fields = output.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 5 else {
        throw HelperFailure(code: "CHROME_RECEIPT_INVALID", message: "Chrome AppleScript 未返回完整的新窗口 receipt")
    }
    let windowID = String(fields[0])
    guard let numericWindowID = UInt64(windowID), numericWindowID > 0, windowID.utf8.count <= 128,
          !windowID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let left = Double(fields[1]), let top = Double(fields[2]),
          let right = Double(fields[3]), let bottom = Double(fields[4]),
          [left, top, right, bottom].allSatisfy(\.isFinite), right > left, bottom > top else {
        throw HelperFailure(code: "CHROME_RECEIPT_INVALID", message: "Chrome AppleScript 返回了无效的新窗口 receipt")
    }
    let bounds = WindowBounds(x: left, y: top, width: right - left, height: bottom - top)
    guard sameBounds(bounds, expectedBounds, tolerance: tolerance) else {
        throw HelperFailure(code: "CHROME_RECEIPT_MISMATCH", message: "Chrome 未接受新窗口 receipt 几何（可能受最小窗口尺寸限制）；未调整其他窗口")
    }
    return ChromeCreationReceipt(appleScriptWindowID: windowID, bounds: bounds)
}

func selectReceiptBoundNewWindow(before: Set<ChromeWindowIdentity>, after: [ChromeWindow],
                                 receiptBounds: WindowBounds,
                                 tolerance: Double = 0.75) throws -> TargetWindow? {
    let matches = after.filter { window in
        guard window.target.bundleId == "com.google.Chrome" else { return false }
        let identity = ChromeWindowIdentity(pid: window.target.pid, windowID: window.target.windowId)
        return !before.contains(identity) && sameBounds(window.bounds, receiptBounds, tolerance: tolerance)
    }
    guard matches.count <= 1 else {
        throw HelperFailure(code: "CHROME_RECEIPT_AMBIGUOUS",
                            message: "多个新增 Chrome 窗口匹配同一 creation receipt，拒绝猜测目标")
    }
    return matches.first?.target
}

private func sameBounds(_ lhs: WindowBounds, _ rhs: WindowBounds, tolerance: Double) -> Bool {
    abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
}

// A single readback attempt either has exact-window AX/CG geometry or an
// explicitly classified transient AX unavailability. Other errors propagate.
enum ChromeStartReadback {
    case unavailable
    case unavailableWindow(ChromeWindow)
    case deadline(ChromeWindow?)
    case sample(ax: WindowBounds, window: ChromeWindow)
}

func validateChromeReadbackBounds(_ bounds: WindowBounds, scale: Double, maxWidthPx: Int) throws {
    guard [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite),
          bounds.width > 0, bounds.height > 0 else {
        throw HelperFailure(code: "CHROME_LAYOUT_READBACK_FAILED", message: "新 Chrome 窗口返回无效几何")
    }
    if bounds.width * scale > Double(maxWidthPx) + 0.5 {
        throw HelperFailure(code: "CHROME_WIDTH_CAP_UNMET", message: "Chrome 新窗口实际原始像素宽度超过 maxWidthPx")
    }
}
func validateChromeReadbackWindow(_ window: ChromeWindow, target: ChromeWindowIdentity,
                              scale: Double, maxWidthPx: Int) throws {
    guard window.target.pid == target.pid && window.target.windowId == target.windowID else {
        throw HelperFailure(code: "CHROME_WINDOW_IDENTITY", message: "新 Chrome 窗口的 PID/window ID 不匹配")
    }
    try validateChromeReadbackBounds(window.bounds, scale: scale, maxWidthPx: maxWidthPx)
}


func waitForChromeStableReadback(expected: WindowBounds, target: ChromeWindowIdentity,
                                scale: Double, maxWidthPx: Int, deadline: TimeInterval,
                                now: () -> TimeInterval, check: () throws -> Void,
                                read: () throws -> ChromeStartReadback,
                                sleep: (TimeInterval) -> Void) throws -> ChromeWindow {
    var previous: (ax: WindowBounds, cg: WindowBounds)?
    var sawGeometry = false
    let tolerance = max(0.5, 1.0 / scale)
    func expired() -> HelperFailure {
        if !sawGeometry {
            return HelperFailure(code: "CHROME_LAYOUT_READBACK_FAILED", message: "无法回读新 Chrome 窗口 AX 几何")
        }
        return HelperFailure(code: "CHROME_LAYOUT_UNSTABLE",
                             message: "Chrome 新窗口 AX/CG 几何未稳定在目标位置和尺寸；拒绝接受 snapback 或系统钳制")
    }
    while true {
        try check()
        guard now() < deadline else { throw expired() }
        let sample = try read()
        try check()
        switch sample {
        case .unavailable:
            previous = nil
        case .unavailableWindow(let window):
            try validateChromeReadbackWindow(window, target: target, scale: scale, maxWidthPx: maxWidthPx)
            previous = nil
        case .deadline(let window):
            if let window { try validateChromeReadbackWindow(window, target: target, scale: scale, maxWidthPx: maxWidthPx) }
            throw expired()
        case .sample(let ax, let window):
            try validateChromeReadbackWindow(window, target: target, scale: scale, maxWidthPx: maxWidthPx)
            try validateChromeReadbackBounds(ax, scale: scale, maxWidthPx: maxWidthPx)
            let cg = window.bounds
            sawGeometry = true
            guard now() < deadline else { throw expired() }
            if sameBounds(ax, expected, tolerance: tolerance),
               sameBounds(cg, expected, tolerance: tolerance),
               sameBounds(ax, cg, tolerance: tolerance) {
                if let previous, sameBounds(ax, previous.ax, tolerance: 0.25),
                   sameBounds(cg, previous.cg, tolerance: 0.25) {
                    try check()
                    guard now() < deadline else { throw expired() }
                    return window
                }
                previous = (ax, cg)
            } else {
                previous = nil
            }
        }
        let remaining = deadline - now()
        guard remaining > 0 else { throw expired() }
        sleep(min(0.05, remaining))
    }
}

final class ChromeStarter {
    private let desktop: ChromeDesktop
    private let cancellation: InputCancellation

    init(desktop: ChromeDesktop, cancellation: InputCancellation) {
        self.desktop = desktop
        self.cancellation = cancellation
    }

    func start(_ request: NativeRequest, generation: UInt64) throws -> [String: Any] {
        guard request.action == "chrome-start", let epoch = request.inputEpoch else {
            throw HelperFailure.invalidArgument
        }
        // Fresh helper has no execution lease. This distinct capability checks that condition
        // without creating a lease/countdown or mutating the user's cancellation state.
        let permit = try cancellation.beginSetup(generation: generation, expectedEpoch: epoch)
        let budget = ChromeStartBudget()
        let profile = try request.profile.map { try resolveChromeProfile(name: $0) }
        try requireChromeAutomationPermission()
        try budget.check(cancellation, permit: permit)
        let layout = try currentLayout(maxWidthPx: request.maxWidthPx, permit: permit, budget: budget)
        let probes = try chromeCreationProbeBounds(layout: layout, nonce: UUID())
        try budget.check(cancellation, permit: permit)
        let before = Set(chromeWindows().map {
            ChromeWindowIdentity(pid: $0.target.pid, windowID: $0.target.windowId)
        })
        try budget.check(cancellation, permit: permit)
        let target: TargetWindow
        var explicitReceipt: ChromeCreationReceipt?
        var profileMarker: String?
        if let profile {
            guard let markerPath = request.profileMarkerPath else { throw HelperFailure.invalidArgument }
            let marker = try createChromeProfileMarker(path: markerPath).absoluteString
            let created = try createProfileWindow(profile, marker: marker, probes: probes,
                                                  layout: layout, before: before, permit: permit, budget: budget)
            target = created.target
            explicitReceipt = created.receipt
            profileMarker = marker
        } else {
            let receipt = try createChromeWindow(url: request.url, marker: probes.first,
                                                permit: permit, budget: budget)
            guard sameBounds(receipt.bounds, probes.first, tolerance: 0.75) else {
                throw HelperFailure(code: "CHROME_RECEIPT_MISMATCH", message: "新 Chrome 窗口未处于第一阶段 receipt 几何")
            }
            target = try waitForReceiptWindow(before: before, marker: receipt.bounds,
                                                  permit: permit, budget: budget)
            let movedReceipt = try moveReceiptWindow(receipt, to: probes.second, permit: permit, budget: budget)
            guard movedReceipt.appleScriptWindowID == receipt.appleScriptWindowID,
                  sameBounds(movedReceipt.bounds, probes.second, tolerance: 0.75) else {
                throw HelperFailure(code: "CHROME_RECEIPT_MISMATCH", message: "AppleScript receipt ID 未绑定到同一 Chrome 窗口对象")
            }
            try waitForReceiptTransition(target, from: receipt.bounds, to: movedReceipt.bounds,
                                         permit: permit, budget: budget)
        }
        let axWindow = try verifiedAXWindow(target, permit: permit, budget: budget)
        try apply(layout.bounds, to: axWindow, target: target, permit: permit, budget: budget, marker: profileMarker)
        if let profile, let receipt = explicitReceipt, let marker = profileMarker {
            try profile.revalidate()
            try navigateProfileWindow(receipt, marker: marker, url: request.url, permit: permit, budget: budget)
            try profile.revalidate()
        }
        let measured = try waitForStableReadback(layout.bounds, scale: layout.scale, maxWidthPx: layout.maxWidthPx,
                                                target: target, permit: permit, budget: budget)
        try budget.check(cancellation, permit: permit)
        var result: [String: Any] = ["window": measured.json, "layout": try layout.json(measuredBounds: measured.bounds)]
        if let profile { result["profile"] = profile.json }
        return result
    }

    private func currentLayout(maxWidthPx: Int, permit: StartupPermit,
                               budget: ChromeStartBudget) throws -> ChromeStartLayout {
        try budget.check(cancellation, permit: permit)
        let layout = try onMain {
            // NSScreen.screens.first 是固定主显示器；不跟随 key window 切换到副屏。
            guard let primary = NSScreen.screens.first else {
                throw HelperFailure(code: "CHROME_SCREEN_UNAVAILABLE", message: "无法读取当前主屏可用区域")
            }
            return try chromeStartLayout(visibleFrame: primary.visibleFrame, primaryFrame: primary.frame,
                                         scale: Double(primary.backingScaleFactor), maxWidthPx: maxWidthPx)
        }
        try budget.check(cancellation, permit: permit)
        return layout
    }

    private func chromeWindows() -> [ChromeWindow] {
        desktop.windows().filter { $0.target.bundleId == "com.google.Chrome" }
    }

    private func boundsArguments(_ bounds: WindowBounds) -> [String] {
        [String(bounds.x), String(bounds.y), String(bounds.x + bounds.width), String(bounds.y + bounds.height)]
    }

    private func receiptScriptOutput(_ script: String, arguments: [String], permit: StartupPermit,
                                     budget: ChromeStartBudget) throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        process.standardOutput = pipe
        let processTimeout = try budget.remaining(cancellation, permit: permit)
        let data = try withCancellableSetupProcess(process, cancellation: cancellation, permit: permit,
                                                   timeout: processTimeout, timeoutCode: "CHROME_START_TIMEOUT",
                                                   failureCode: "CHROME_START_FAILED",
                                                   failureMessage: "无法通过 Apple Events 创建或定位 Chrome 新窗口",
                                                   timeoutMessage: "Chrome 新窗口 setup 超时，启动子进程已终止",
                                                   readOutput: {
            let result = pipe.fileHandleForReading.readDataToEndOfFile()
            guard result.count <= 1024 else {
                throw HelperFailure(code: "CHROME_RECEIPT_INVALID", message: "Chrome AppleScript receipt 超出安全长度")
            }
            return result
        })
        try budget.check(cancellation, permit: permit)
        guard let output = String(data: data, encoding: .utf8) else {
            throw HelperFailure(code: "CHROME_RECEIPT_INVALID", message: "Chrome AppleScript receipt 不是有效 UTF-8")
        }
        return output
    }

    private func createProfileWindow(_ profile: ChromeProfileSelection, marker: String,
                                     probes: (first: WindowBounds, second: WindowBounds),
                                     layout: ChromeStartLayout, before: Set<ChromeWindowIdentity>,
                                     permit: StartupPermit, budget: ChromeStartBudget) throws
        -> (target: TargetWindow, receipt: ChromeCreationReceipt) {
        try budget.check(cancellation, permit: permit)
        try profile.revalidate()
        guard let application = onMain({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }) else {
            throw HelperFailure(code: "CHROME_NOT_INSTALLED", message: "无法找到正式版Google Chrome应用")
        }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = try chromeProfileLaunchArguments(application: application, profile: profile, marker: marker)
        // LaunchServices owns the browser lifetime. Cancelling only reaps our short-lived
        // open launcher, never an existing (or newly running) user's browser process.
        try withCancellableSetupProcess(launcher, cancellation: cancellation, permit: permit,
                                        timeout: try budget.remaining(cancellation, permit: permit),
                                        timeoutCode: "CHROME_START_TIMEOUT", failureCode: "PROFILE_LAUNCH_FAILED",
                                        failureMessage: "无法启动指定Chrome profile", timeoutMessage: "Chrome profile启动超时",
                                        readOutput: { () })
        try profile.revalidate()
        let target = try waitForProfileMarker(marker, before: before, permit: permit, budget: budget)
        let ax = try verifiedAXWindow(target, permit: permit, budget: budget)
        // Only mutate the new CG/AX window that itself exposes our unique document
        // marker. AppleScript merely reads A->B, so it cannot resize another window.
        try apply(probes.first, to: ax, target: target, permit: permit, budget: budget, marker: marker)
        let first = try waitForStableReadback(probes.first, scale: layout.scale, maxWidthPx: layout.maxWidthPx,
                                               target: target, permit: permit, budget: budget)
        let receipt = try readProfileMarkerReceipt(marker, id: nil, expected: first.bounds, permit: permit, budget: budget)
        try profile.revalidate()
        try apply(probes.second, to: ax, target: target, permit: permit, budget: budget, marker: marker)
        let second = try waitForStableReadback(probes.second, scale: layout.scale, maxWidthPx: layout.maxWidthPx,
                                                target: target, permit: permit, budget: budget)
        let moved = try readProfileMarkerReceipt(marker, id: receipt.appleScriptWindowID,
                                                expected: second.bounds, permit: permit, budget: budget)
        guard moved.appleScriptWindowID == receipt.appleScriptWindowID else {
            throw HelperFailure(code: "PROFILE_WINDOW_UNVERIFIED", message: "profile窗口AppleScript身份在原生几何迁移时变化")
        }
        try waitForReceiptTransition(target, from: first.bounds, to: moved.bounds, permit: permit, budget: budget)
        try profile.revalidate()
        return (target, moved)
    }

    private func waitForProfileMarker(_ marker: String, before: Set<ChromeWindowIdentity>,
                                       permit: StartupPermit, budget: ChromeStartBudget) throws -> TargetWindow {
        let deadline = try budget.stageDeadline(cancellation, permit: permit, maximum: 8)
        repeat {
            try budget.check(cancellation, permit: permit)
            var matches: [ChromeWindow] = []
            for window in chromeWindows() where window.layer == 0 {
                try budget.check(cancellation, permit: permit)
                if (try? desktop.windowDocument(window.target, deadline: deadline)) == marker { matches.append(window) }
            }
            if let target = try selectProfileMarkerWindow(before: before, matches: matches) {
                try requireProfileMarker(target, marker: marker, permit: permit, budget: budget)
                return target
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        try budget.check(cancellation, permit: permit)
        throw HelperFailure(code: "PROFILE_WINDOW_UNVERIFIED", message: "无法把profile启动标记绑定到新的原生Chrome窗口；不会回退或猜测")
    }

    private func requireProfileMarker(_ target: TargetWindow, marker: String,
                                       permit: StartupPermit, budget: ChromeStartBudget) throws {
        try budget.check(cancellation, permit: permit)
        let deadline = try budget.stageDeadline(cancellation, permit: permit, maximum: 0.5)
        guard try desktop.windowDocument(target, deadline: deadline) == marker else {
            throw HelperFailure(code: "PROFILE_MARKER_LOST", message: "profile窗口启动标记已变化；停止后续布局或导航")
        }
        try budget.check(cancellation, permit: permit)
    }

    private func readProfileMarkerReceipt(_ marker: String, id: String?, expected: WindowBounds,
                                           permit: StartupPermit, budget: ChromeStartBudget) throws -> ChromeCreationReceipt {
        // Read-only: never use an unbound AppleScript object to change geometry.
        let script = """
        on run argv
            \(chromeReceiptSeparatorScript)
            set markerURL to item 1 of argv
            set receiptID to item 2 of argv
            tell application id "com.google.Chrome"
                set matchedWindows to {}
                if receiptID is "" then
                    repeat with candidateWindow in windows
                        try
                            if (URL of active tab of candidateWindow as text) is markerURL then
                                set end of matchedWindows to candidateWindow
                            end if
                        end try
                    end repeat
                else
                    set matchedWindows to every window whose id is (receiptID as integer)
                end if
                if (count of matchedWindows) is not 1 then return "PROFILE_MARKER_UNVERIFIED"
                set targetWindow to item 1 of matchedWindows
                if (URL of active tab of targetWindow as text) is not markerURL then return "PROFILE_MARKER_UNVERIFIED"
                set actualBounds to bounds of targetWindow
                return (id of targetWindow as text) & mccReceiptSeparator & (item 1 of actualBounds as text) & mccReceiptSeparator & (item 2 of actualBounds as text) & mccReceiptSeparator & (item 3 of actualBounds as text) & mccReceiptSeparator & (item 4 of actualBounds as text)
            end tell
        end run
        """
        let output = try receiptScriptOutput(script, arguments: [marker, id ?? ""], permit: permit, budget: budget)
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "PROFILE_MARKER_UNVERIFIED" {
            throw HelperFailure(code: "PROFILE_WINDOW_UNVERIFIED", message: "无法唯一对应profile标记与AppleScript窗口身份")
        }
        return try parseChromeCreationReceipt(output, expectedBounds: expected)
    }

    private func navigateProfileWindow(_ receipt: ChromeCreationReceipt, marker: String, url: String,
                                        permit: StartupPermit, budget: ChromeStartBudget) throws {
        let script = """
        on run argv
            set receiptID to (item 1 of argv) as integer
            set markerURL to item 2 of argv
            set targetURL to item 3 of argv
            tell application id "com.google.Chrome"
                set matchedWindows to every window whose id is receiptID
                if (count of matchedWindows) is not 1 then return "PROFILE_MARKER_UNVERIFIED"
                set targetWindow to item 1 of matchedWindows
                if (URL of active tab of targetWindow as text) is not markerURL then return "PROFILE_MARKER_UNVERIFIED"
                set URL of active tab of targetWindow to targetURL
                return id of targetWindow as text
            end tell
        end run
        """
        let output = try receiptScriptOutput(script, arguments: [receipt.appleScriptWindowID, marker, url], permit: permit, budget: budget)
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == receipt.appleScriptWindowID else {
            throw HelperFailure(code: "PROFILE_WINDOW_UNVERIFIED", message: "profile窗口导航前身份或标记不匹配；未继续连接")
        }
    }

    private func createChromeWindow(url: String, marker: WindowBounds,
                                    permit: StartupPermit, budget: ChromeStartBudget) throws -> ChromeCreationReceipt {
        // 固定脚本；URL 与几何均为独立 argv 数据。脚本返回 make new window 的对象 ID，
        // 并将该对象置于第一阶段探针几何；不读取或猜测 application front window。
        let script = """
        on run argv
            \(chromeReceiptSeparatorScript)
            set targetURL to item 1 of argv
            set leftEdge to (item 2 of argv) as real
            set topEdge to (item 3 of argv) as real
            set rightEdge to (item 4 of argv) as real
            set bottomEdge to (item 5 of argv) as real
            tell application id "com.google.Chrome"
                activate
                set createdWindow to make new window
                set bounds of createdWindow to {leftEdge, topEdge, rightEdge, bottomEdge}
                set URL of active tab of createdWindow to targetURL
                set actualBounds to bounds of createdWindow
                return (id of createdWindow as text) & mccReceiptSeparator & (item 1 of actualBounds as text) & mccReceiptSeparator & (item 2 of actualBounds as text) & mccReceiptSeparator & (item 3 of actualBounds as text) & mccReceiptSeparator & (item 4 of actualBounds as text)
            end tell
        end run
        """
        let output = try receiptScriptOutput(script, arguments: [url] + boundsArguments(marker),
                                             permit: permit, budget: budget)
        return try parseChromeCreationReceipt(output, expectedBounds: marker)
    }

    private func moveReceiptWindow(_ receipt: ChromeCreationReceipt, to marker: WindowBounds,
                                   permit: StartupPermit, budget: ChromeStartBudget) throws -> ChromeCreationReceipt {
        // Resolve by the exact AppleScript creation receipt ID, then move that object A->B.
        // The returned second receipt must echo the same ID and B geometry before a CG target is accepted.
        let script = """
        on run argv
            \(chromeReceiptSeparatorScript)
            set receiptID to (item 1 of argv) as integer
            set leftEdge to (item 2 of argv) as real
            set topEdge to (item 3 of argv) as real
            set rightEdge to (item 4 of argv) as real
            set bottomEdge to (item 5 of argv) as real
            tell application id "com.google.Chrome"
                set receiptMatches to every window whose id is receiptID
                if (count of receiptMatches) is not 1 then error "receipt window is not unique"
                set targetWindow to item 1 of receiptMatches
                set bounds of targetWindow to {leftEdge, topEdge, rightEdge, bottomEdge}
                set actualBounds to bounds of targetWindow
                return (id of targetWindow as text) & mccReceiptSeparator & (item 1 of actualBounds as text) & mccReceiptSeparator & (item 2 of actualBounds as text) & mccReceiptSeparator & (item 3 of actualBounds as text) & mccReceiptSeparator & (item 4 of actualBounds as text)
            end tell
        end run
        """
        let output = try receiptScriptOutput(script,
                                            arguments: [receipt.appleScriptWindowID] + boundsArguments(marker),
                                            permit: permit, budget: budget)
        return try parseChromeCreationReceipt(output, expectedBounds: marker)
    }

    private func waitForReceiptWindow(before: Set<ChromeWindowIdentity>, marker: WindowBounds,
                                      permit: StartupPermit, budget: ChromeStartBudget) throws -> TargetWindow {
        let deadline = try budget.stageDeadline(cancellation, permit: permit, maximum: 8)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try budget.check(cancellation, permit: permit)
            if let target = try selectReceiptBoundNewWindow(before: before, after: chromeWindows(),
                                                            receiptBounds: marker, tolerance: 1.0) {
                _ = try desktop.window(target)
                return target
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try budget.check(cancellation, permit: permit)
        throw HelperFailure(code: "CHROME_RECEIPT_NOT_VISIBLE",
                            message: "AppleScript 创建的指定 Chrome receipt 尚未映射到新增 CGWindowID")
    }

    private func waitForReceiptTransition(_ target: TargetWindow, from oldBounds: WindowBounds,
                                          to newBounds: WindowBounds, permit: StartupPermit,
                                          budget: ChromeStartBudget) throws {
        let deadline = try budget.stageDeadline(cancellation, permit: permit, maximum: 4)
        let identity = ChromeWindowIdentity(pid: target.pid, windowID: target.windowId)
        repeat {
            try budget.check(cancellation, permit: permit)
            guard let window = chromeWindows().first(where: {
                $0.target.pid == identity.pid && $0.target.windowId == identity.windowID &&
                    $0.target.bundleId == "com.google.Chrome"
            }) else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if sameBounds(window.bounds, newBounds, tolerance: 1.0) {
                _ = try desktop.window(target)
                return
            }
            // It must still be the same identity observed at stage A while stage B propagates.
            guard sameBounds(window.bounds, oldBounds, tolerance: 1.0) ||
                    ProcessInfo.processInfo.systemUptime < deadline else {
                throw HelperFailure(code: "CHROME_RECEIPT_IDENTITY_CHANGED",
                                    message: "creation receipt 的 CGWindowID 在几何迁移期间发生变化")
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        try budget.check(cancellation, permit: permit)
        throw HelperFailure(code: "CHROME_RECEIPT_NOT_BOUND",
                            message: "receipt 指定的 AppleScript 窗口几何变化未对应到同一 PID/CGWindowID")
    }

    private func verifiedAXWindow(_ target: TargetWindow, permit: StartupPermit,
                                  budget: ChromeStartBudget) throws -> AXUIElement {
        let deadline = try budget.stageDeadline(cancellation, permit: permit, maximum: 3)
        var lastFailure: HelperFailure?
        repeat {
            try budget.check(cancellation, permit: permit)
            do {
                _ = try desktop.window(target)
                let app = desktop.axApplication(target.pid)
                let element = try desktop.targetAXWindow(target, app: app)
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid,
                      desktop.identifier(element) == target.windowId else {
                    throw HelperFailure(code: "CHROME_WINDOW_IDENTITY", message: "新 Chrome 窗口的 AX PID/window ID 不匹配")
                }
                return element
            } catch let failure as HelperFailure {
                if failure.code == "CHROME_WINDOW_IDENTITY" { throw failure }
                lastFailure = failure
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw HelperFailure(code: "CHROME_AX_WINDOW_UNAVAILABLE",
                            message: "receipt 对应的 CGWindowID 无法精确映射到 AX：\(lastFailure?.code ?? "未取得 AX 窗口")")
    }

    private func apply(_ bounds: WindowBounds, to window: AXUIElement,
                       target: TargetWindow, permit: StartupPermit, budget: ChromeStartBudget, marker: String? = nil) throws {
        try budget.check(cancellation, permit: permit)
        _ = try desktop.window(target)
        AXUIElementSetMessagingTimeout(window, 0.35)
        var size = CGSize(width: bounds.width, height: bounds.height)
        var position = CGPoint(x: bounds.x, y: bounds.y)
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else {
            throw HelperFailure(code: "CHROME_LAYOUT_FAILED", message: "无法构造 Chrome AX 窗口几何值")
        }
        try applyChromeStartGeometry(position: {
            if let marker { try requireProfileMarker(target, marker: marker, permit: permit, budget: budget) }
            try budget.check(cancellation, permit: permit)
            return try cancellation.setupEffect(permit: permit) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            }
        }, size: {
            if let marker { try requireProfileMarker(target, marker: marker, permit: permit, budget: budget) }
            try budget.check(cancellation, permit: permit)
            return try cancellation.setupEffect(permit: permit) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
        })
        try budget.check(cancellation, permit: permit)
    }

    private func waitForStableReadback(_ expected: WindowBounds, scale: Double, maxWidthPx: Int,
                                       target: TargetWindow, permit: StartupPermit,
                                       budget: ChromeStartBudget) throws -> ChromeWindow {
        let deadline = try budget.stageDeadline(cancellation, permit: permit, maximum: 2)
        func withinStage() throws -> Bool {
            try budget.check(cancellation, permit: permit)
            return ProcessInfo.processInfo.systemUptime < deadline
        }
        return try waitForChromeStableReadback(
            expected: expected, target: ChromeWindowIdentity(pid: target.pid, windowID: target.windowId),
            scale: scale, maxWidthPx: maxWidthPx, deadline: deadline,
            now: { ProcessInfo.processInfo.systemUptime },
            check: { try budget.check(self.cancellation, permit: permit) },
            read: {
                guard try withinStage() else { return .deadline(nil) }
                let before = try self.desktop.window(target)
                let beforeInTime = try withinStage()
                try validateChromeReadbackWindow(before, target: ChromeWindowIdentity(pid: target.pid, windowID: target.windowId),
                                                 scale: scale, maxWidthPx: maxWidthPx)
                guard beforeInTime else { return .deadline(before) }
                do {
                    // Reacquire the exact AX window on every attempt; never reuse the
                    // element that was obtained before navigation or layout changes.
                    let app = self.desktop.axApplication(target.pid)
                    guard try withinStage() else { return .deadline(before) }
                    let element = try self.desktop.targetAXWindow(target, app: app, deadline: deadline, strictReadback: true)
                    guard try withinStage() else { return .deadline(before) }
                    let pidResult = performBoundedAXCall(
                        deadline: deadline, timeout: 0.35, setDefaultTimeout: true,
                        now: { ProcessInfo.processInfo.systemUptime },
                        setTimeout: { AXUIElementSetMessagingTimeout(element, $0) }, call: {
                            var pid: pid_t = 0
                            let status = AXUIElementGetPid(element, &pid)
                            return (status, pid)
                        })
                    let pid = try requireChromeAXValue(pidResult, strict: true, message: "无法确认新 Chrome 窗口的 AX PID")
                    let pidInTime = try withinStage()
                    guard pid == target.pid else {
                        throw HelperFailure(code: "CHROME_WINDOW_IDENTITY", message: "新 Chrome 窗口的 AX PID 不匹配")
                    }
                    guard pidInTime else { return .deadline(before) }
                    let windowID = try self.desktop.readbackIdentifier(element, deadline: deadline)
                    let idInTime = try withinStage()
                    guard windowID == target.windowId else {
                        throw HelperFailure(code: "CHROME_WINDOW_IDENTITY", message: "新 Chrome 窗口的 AX window ID 不匹配")
                    }
                    guard idInTime else { return .deadline(before) }
                    let ax = try self.desktop.axBounds(element, deadline: deadline, strictReadback: true)
                    guard try withinStage() else { return .sample(ax: ax, window: before) }
                    let after = try self.desktop.window(target)
                    return .sample(ax: ax, window: after)
                } catch is ChromeAXReadbackUnavailable {
                    // Only typed transient AX failures retry. CG identity and the
                    // startup permit remain authoritative even on a failed read.
                    guard try withinStage() else { return .deadline(before) }
                    return .unavailableWindow(try self.desktop.window(target))
                }
            },
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }

}
