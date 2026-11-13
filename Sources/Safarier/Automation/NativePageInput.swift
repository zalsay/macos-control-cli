import AppKit
import WebKit
import SafarierObjCSupport
import SafarierCore
#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Darwin
#endif

#if SAFARIER_BOUND_LOCAL_CANDIDATE
private func hoverNativeElapsedMs(_ start: UInt64) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    return now >= start ? (now - start) / 1_000_000 : 0
}
// Map only fixed internal failure literals; never write the underlying string.
private func hoverNativeFailureCode(_ failure: String?) -> String {
    switch failure {
    case nil: return "none"
    case .some("bound context revoked"): return "bound_context_revoked"
    case .some("target identity, geometry, background state or point is invalid"): return "valid_rejected"
    case .some("page is not the native hit-test target"): return "hit_test_rejected"
    case .some("native mouse delivery failed"): return "scoped_dispatch_failed"
    case .some("could not create native mouse event"): return "event_create_failed"
    case .some("native tracking callback unavailable"): return "tracking_owner_empty"
    case .some("background activity unavailable"): return "activity_unavailable"
    default: return "other"
    }
}
#endif

/// Single native event path; production admission remains unavailable.
@MainActor
final class NativePageInput {
    let webView: BrowserWebView
    let window: NSWindow
    private let expectedBounds: NSRect
    private let expectedFrame: NSRect
    private let windowNumber: Int
    private(set) var activityLease: AnyObject?
    private(set) var activityReady = false
    private(set) var activityClosed = false
    private(set) var activityStatus: SFRCallStatus = .OK
    private(set) var buttonMask: UInt = 0
    #if SAFARIER_NATIVE_PROBE
    private(set) var trace: [[String: Any]] = []
    #endif
    private var epoch: UInt64 = 0
    private var finishRequested = false
    private(set) var requiresOwnedTargetDestruction = false
    private let expectedScale: CGFloat
    private let expectedZoom: CGFloat
    private let expectedViewVersion: UInt64
    private var failure: String?
    private var position = NSPoint(x: 20, y: 20)
    private var sequence = 0
    private var mouseDispatchGeneration: UInt64 = 0
    private var pendingMouse = false
    private var uncertainDispatch = false
    private var deliverySequence: UInt64 = 0
    private var performing = false
    private var snapshotWaiter: SnapshotWaiter?
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var boundContext: RunnerBinderContext?
    private var registeredTarget: AutomationTargetIdentity?
    private var registeredLeaseID: UUID?
    var registeredTargetValidator: (@MainActor () -> Bool)?
    #endif

    /// No production caller can bypass the unverified G0/G1/G2 admission gate.
    static var shippingAdmissionAvailable: Bool { NativeInputPreflight.shippingAdmissionAvailable }
    static func requireShippingAdmission() throws {
        guard shippingAdmissionAvailable else { throw AutomationError(code: .uiPolicyUnavailable) }
    }
    static func open(webView: BrowserWebView, window: NSWindow, viewVersion: UInt64 = 1) throws -> NativePageInput {
        try requireShippingAdmission()
        let input = NativePageInput(webView: webView, window: window, viewVersion: viewVersion)
        input.beginActivity()
        guard input.activityStatus == .OK, input.activityLease != nil else {
            input.closeActivity()
            throw AutomationError(code: .backendUnavailable)
        }
        return input
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    /// This overload is only for the Core-authenticated, sealed local fixture.
    /// The ordinary shipping factory above remains independently denied.
    static func open(webView: BrowserWebView, window: NSWindow, context: RunnerBinderContext, viewVersion: UInt64 = 1) throws -> NativePageInput {
        try context.checkLive()
        _ = try context.localFixtureURL()
        let input = NativePageInput(webView: webView, window: window, viewVersion: viewVersion)
        input.boundContext = context
        input.beginActivity()
        do {
            try context.checkLive()
            guard input.activityStatus == .OK, input.activityLease != nil else {
                throw AutomationError(code: .backendUnavailable)
            }
            return input
        } catch {
            input.closeActivity()
            throw error
        }
    }

    static func prepareRegistered(webView: BrowserWebView, window: NSWindow, context: RunnerBinderContext,
                                  target: AutomationTargetIdentity, viewVersion: UInt64 = 1) throws -> NativePageInput {
        try context.validateRegisteredTarget(target)
        guard RegisteredAdmissionDiagnostic.check(!NSApp.isActive, .inputAppActive),
              RegisteredAdmissionDiagnostic.check(!window.isKeyWindow, .inputWindowKey),
              RegisteredAdmissionDiagnostic.check(!window.isMainWindow, .inputWindowMain),
              RegisteredAdmissionDiagnostic.check(webView.window === window, .inputWebViewWindow),
              RegisteredAdmissionDiagnostic.check(window.windowNumber > 0, .inputWindowNumber) else {
            throw AutomationError(code: .interactionRequired)
        }
        let input = NativePageInput(webView: webView, window: window, viewVersion: viewVersion)
        input.boundContext = context
        input.registeredTarget = target
        input.registeredLeaseID = BrowserWindowController.registeredLeaseID(window: window)
        return input
    }

    var registeredPresentationNotStarted: Bool {
        activityLease == nil && !activityReady && !activityClosed && !finishRequested && buttonMask == 0
    }

    func startRegistered() throws {
        guard let context = boundContext, let target = registeredTarget, registeredTargetValidator?() == true, activityLease == nil,
              !finishRequested else { throw AutomationError(code: .targetChanged) }
        try context.validateRegisteredTarget(target)
        guard let leaseID = registeredLeaseID ?? BrowserWindowController.registeredLeaseID(window: window),
              BrowserWindowController.registeredPresentationValid(window: window, webView: webView, leaseID: leaseID) else {
            RegisteredAdmissionDiagnostic.check(false, .inputPresentation)
            throw AutomationError(code: .interactionRequired)
        }
        registeredLeaseID = leaseID
        beginActivity()
        try context.validateRegisteredTarget(target)
        guard BrowserWindowController.registeredPresentationValid(window: window, webView: webView, leaseID: leaseID),
              activityStatus == .OK, activityLease != nil else { throw AutomationError(code: .backendUnavailable) }
    }
    #endif

    private init(webView: BrowserWebView, window: NSWindow, viewVersion: UInt64) {
        self.webView = webView
        self.window = window
        expectedBounds = webView.bounds
        expectedFrame = window.frame
        windowNumber = window.windowNumber
        expectedScale = window.backingScaleFactor
        expectedZoom = webView.pageZoom
        expectedViewVersion = viewVersion
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_NATIVE_INPUT_POLICY_TESTS
    static func unstartedRegisteredInputForPolicyTest(webView: BrowserWebView, window: NSWindow) -> NativePageInput {
        let input = NativePageInput(webView: webView, window: window, viewVersion: 1)
        input.registeredTarget = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        return input
    }
    var policyTestFailure: String? { failure }
    var policyTestUncertainDispatch: Bool { uncertainDispatch }
    func markPolicyTestUncertainDispatch() { uncertainDispatch = true }
    #endif

    #if SAFARIER_NATIVE_PROBE
    convenience init(diagnosticWebView webView: BrowserWebView, window: NSWindow) {
        self.init(webView: webView, window: window, viewVersion: 1)
        beginActivity()
    }
    func rejectDiagnosticInput() { failure = "unsupported diagnostic input" }
    #endif

    private func beginActivity() {
        let currentEpoch = epoch
        var token: AnyObject?
        var detail: NSString?
        activityStatus = SFRBeginBackgroundPageActivity(webView, &token, { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.epoch == currentEpoch, !self.activityClosed else { return }
                self.activityReady = true
            }
        }, &detail)
        activityLease = token
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if boundContext != nil {
            fputs("OPEN_DIAG phase=runner.activity_begin urlPresent=\(webView.url != nil) activityStatus=\(activityStatus.rawValue) hasLease=\(activityLease != nil)\n", stderr)
        }
        #endif
        #if SAFARIER_NATIVE_PROBE
        trace.append(["activityBeginStatus": activityStatus.rawValue])
        #endif
        if activityStatus != .OK { failure = "background activity unavailable" }
    }

    func waitUntilReady() async throws {
        let currentEpoch = epoch
        let deadline = ContinuousClock.now + .seconds(Int(AutomationLimits.actionSeconds))
        while !activityReady {
            guard epoch == currentEpoch, !activityClosed, activityLease != nil, failure == nil else {
                throw AutomationError(code: .targetChanged)
            }
            guard ContinuousClock.now < deadline else { throw AutomationError(code: .timeout) }
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { throw AutomationError(code: .cancelled) }
        }
        if Task.isCancelled { throw AutomationError(code: .cancelled) }
        guard epoch == currentEpoch, !activityClosed, activityLease != nil, failure == nil else {
            throw AutomationError(code: .targetChanged)
        }
    }

    /// Wait only for the native finish acknowledgement; timeout is not an acknowledgement.
    func waitUntilClosed() async throws {
        let currentEpoch = epoch
        let deadline = ContinuousClock.now + .seconds(Int(AutomationLimits.actionSeconds))
        while !activityClosed {
            guard finishRequested, epoch == currentEpoch, activityStatus == .OK else {
                throw AutomationError(code: .targetChanged)
            }
            guard ContinuousClock.now < deadline else { throw AutomationError(code: .timeout) }
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { throw AutomationError(code: .cancelled) }
        }
        guard !Task.isCancelled else { throw AutomationError(code: .cancelled) }
        guard finishRequested, epoch == currentEpoch, activityStatus == .OK else {
            throw AutomationError(code: .targetChanged)
        }
    }

    private func revokeBoundOnNativeFailure() {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        boundContext?.beginClosing()
        #endif
    }

    private func valid(_ point: NSPoint) -> Bool {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        if let boundContext, (try? boundContext.checkLive()) == nil {
            failure = failure ?? "bound context revoked"
            fputs("HOVER_NATIVE phase=valid.reject elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) failure=\(hoverNativeFailureCode(failure))\n", stderr)
            return false
        }
        if let registeredTarget, let boundContext,
           (try? boundContext.validateRegisteredTarget(registeredTarget)) == nil {
            failure = failure ?? "registered target revoked"
            boundContext.beginClosing()
            return false
        }
        if registeredTarget != nil {
            guard registeredTargetValidator?() == true, let leaseID = registeredLeaseID,
                  BrowserWindowController.registeredPresentationValid(window: window, webView: webView, leaseID: leaseID) else {
                failure = failure ?? "registered presentation lease changed"
                boundContext?.beginClosing()
                return false
            }
        }
        #endif
        guard failure == nil, activityLease != nil, !NSApplication.shared.isActive,
              !window.isKeyWindow, !window.isMainWindow, webView.window === window,
              window.windowNumber == windowNumber, window.frame == expectedFrame,
              webView.bounds == expectedBounds, window.backingScaleFactor == expectedScale,
              webView.pageZoom == expectedZoom, activityReady, !activityClosed,
              AutomationViewport(viewportWidthPoints: Double(expectedBounds.width), viewportHeightPoints: Double(expectedBounds.height), pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: expectedViewVersion).contains(ViewportPoint(x: Double(point.x), y: Double(point.y))) else {
            failure = failure ?? "target identity, geometry, background state or point is invalid"
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if boundContext != nil { fputs("HOVER_NATIVE phase=valid.reject elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) failure=\(hoverNativeFailureCode(failure))\n", stderr) }
            boundContext?.beginClosing()
            #endif
            return false
        }
        guard recipient(windowPoint(point)) != nil else {
            failure = "page is not the native hit-test target"
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if boundContext != nil { fputs("HOVER_NATIVE phase=valid.reject elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) failure=\(hoverNativeFailureCode(failure))\n", stderr) }
            #endif
            revokeBoundOnNativeFailure()
            return false
        }
        return true
    }

    private func windowPoint(_ point: NSPoint) -> NSPoint {
        webView.convert(NSPoint(x: point.x, y: webView.isFlipped ? point.y : webView.bounds.height - point.y), to: nil)
    }

    private func recipient(_ point: NSPoint) -> NSView? {
        guard let root = window.contentView else { return nil }
        let converted = root.superview?.convert(point, from: nil) ?? point
        guard let hit = root.hitTest(converted), hit.isDescendant(of: webView) else { return nil }
        return hit
    }

    private func deliver(_ target: NSObject, _ event: NSEvent) {
        var detail: NSString?
        if event.type == .scrollWheel {
            // The mouse fence does not establish scroll completion.
            uncertainDispatch = true
        } else {
            mouseDispatchGeneration &+= 1
            pendingMouse = true
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        if boundContext != nil && event.type == .mouseMoved {
            fputs("HOVER_NATIVE phase=scoped_dispatch.before elapsed_ms=0 pendingMouse=\(pendingMouse)\n", stderr)
        }
        #endif
        let status = SFRDispatchScopedMouseEvent(target, event, buttonMask, &detail)
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if boundContext != nil && event.type == .mouseMoved {
            fputs("HOVER_NATIVE phase=scoped_dispatch.after elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) status=\(status.rawValue) pendingMouse=\(pendingMouse)\n", stderr)
        }
        #endif
        #if SAFARIER_NATIVE_PROBE
        trace.append(["event": event.type.rawValue, "buttons": buttonMask, "status": status.rawValue])
        #endif
        if status != .OK {
            uncertainDispatch = true
            failure = "native mouse delivery failed"
            revokeBoundOnNativeFailure()
        }
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, count: Int = 0) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        #endif
        guard valid(point) else { return }
        sequence += 1
        let p = windowPoint(point)
        guard let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
            context: nil, eventNumber: sequence, clickCount: count, pressure: type == .leftMouseDown ? 0.5 : 0) else {
            failure = "could not create native mouse event"; return
        }
        let previousMask = buttonMask
        if type == .leftMouseDown || type == .leftMouseDragged { buttonMask = 1 }
        if type == .leftMouseUp { buttonMask = 0 }
        if type == .mouseMoved {
            var owners = Set<ObjectIdentifier>()
            for area in webView.trackingAreas where area.options.contains(.mouseMoved) {
                guard let owner = area.owner as? NSObject,
                      owner.responds(to: #selector(NSResponder.mouseMoved(with:))),
                      owners.insert(ObjectIdentifier(owner)).inserted else { continue }
                deliver(owner, event)
                if failure != nil { break }
            }
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if boundContext != nil { fputs("HOVER_NATIVE phase=tracking_owners elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) ownersCount=\(owners.count)\n", stderr) }
            #endif
            if owners.isEmpty { failure = "native tracking callback unavailable" }
        } else {
            guard let target = recipient(p) else { if type == .leftMouseUp { buttonMask = previousMask }; failure = "page is not the native hit-test target"; return }
            deliver(target, event)
        }
        if failure != nil && type == .leftMouseUp { buttonMask = previousMask }
        position = point
    }

    func move(_ x: Double, _ y: Double) {
        mouse(buttonMask == 0 ? .mouseMoved : .leftMouseDragged, NSPoint(x: x, y: y))
    }
    func press(_ x: Double, _ y: Double, count: Int = 1) {
        guard failure == nil else { return }
        guard NativeInputPreflight.nextButtonState(held: buttonMask != 0, action: .down) != nil else { failure = "left button is already held"; return }
        mouse(.leftMouseDown, NSPoint(x: x, y: y), count: count)
    }
    func release(_ x: Double, _ y: Double, count: Int = 1) {
        guard failure == nil else { return }
        guard NativeInputPreflight.nextButtonState(held: buttonMask != 0, action: .up) != nil else { failure = "left button is not held"; return }
        mouse(.leftMouseUp, NSPoint(x: x, y: y), count: count)
    }
    func click(_ x: Double, _ y: Double, count: Int = 1) {
        guard failure == nil else { return }
        guard NativeInputPreflight.nextButtonState(held: buttonMask != 0, action: .click) != nil else { failure = "left button is already held"; return }
        guard count == 1 || count == 2 else { failure = "invalid click count"; return }
        move(x, y)
        for i in 1...count { press(x, y, count: i); release(x, y, count: i) }
    }
    func drag(_ start: NSPoint, _ end: NSPoint) {
        guard failure == nil, buttonMask == 0 else { failure = "left button is already held"; return }
        move(start.x, start.y)
        press(start.x, start.y)
        for i in 1...16 {
            let fraction = Double(i) / 16
            move(start.x + (end.x - start.x) * fraction, start.y + (end.y - start.y) * fraction)
        }
        release(end.x, end.y)
    }

    func key(_ key: AutomationKey, shift: Bool = false) {
        guard NativeInputPreflight.keyAllowed(name: key, shift: shift) else { failure = "unsupported key combination"; return }
        guard valid(position), let target = window.firstResponder as? NSView, target.isDescendant(of: webView) else { failure = "keyboard target unavailable"; return }
        let mapping: (String, UInt16)
        switch key {
        case .backspace: mapping = ("\u{8}", 51)
        case .delete: mapping = ("\u{f728}", 117)
        case .enter: mapping = ("\r", 36)
        case .tab: mapping = ("\t", 48)
        case .escape: mapping = ("\u{1b}", 53)
        case .left: mapping = ("\u{f702}", 123)
        case .right: mapping = ("\u{f703}", 124)
        case .up: mapping = ("\u{f700}", 126)
        case .down: mapping = ("\u{f701}", 125)
        case .home: mapping = ("\u{f729}", 115)
        case .end: mapping = ("\u{f72b}", 119)
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, characters: mapping.0, charactersIgnoringModifiers: mapping.0, isARepeat: false, keyCode: mapping.1) else { failure = "native key unavailable"; return }
            var detail: NSString?
            let status = SFRSetObject(target, type == .keyDown ? "keyDown:" : "keyUp:", event, &detail)
            if status != .OK { uncertainDispatch = true; failure = "native key delivery failed"; return }
        }
    }
    func type(_ text: String) {
        guard valid(position), let target = window.firstResponder as? NSView, target.isDescendant(of: webView), let textClient = target as? NSTextInputClient else { failure = "text input unavailable"; return }
        textClient.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func scroll(_ x: Double, _ y: Double, delta: Int32) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && !SAFARIER_WHEEL_OBSERVER_PROBE
        guard registeredTarget == nil else { failure = "registered wheel unavailable"; return }
        #endif
        let point = NSPoint(x: x, y: y)
        guard valid(point) else { return }
        let p = windowPoint(point)
        guard let cg = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState),
            units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { failure = "could not create wheel event"; return }
        // No associated NSWindow: preserve window-local coordinates as WebKit's native test sender does.
        cg.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        guard let event = NSEvent(cgEvent: cg), let target = recipient(p) else { failure = "invalid wheel target"; return }
        deliver(target, event)
    }

    func drain() async throws {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        let diagnosticEnabled = boundContext != nil
        var diagnosticResult = "unknown"
        defer {
            if diagnosticEnabled {
                let result = diagnosticResult == "unknown" && Task.isCancelled ? "cancelled" : diagnosticResult
                fputs("HOVER_NATIVE phase=drain.result elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) result=\(result)\n", stderr)
            }
        }
        #endif
        if failure != nil {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticResult = "prior_failure"
            #endif
            throw AutomationError(code: .backendUnavailable)
        }
        guard pendingMouse else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticResult = "no_pending"
            #endif
            return
        }
        guard activityLease != nil else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticResult = "no_lease"
            #endif
            throw AutomationError(code: .backendUnavailable)
        }
        let currentEpoch = epoch, generation = mouseDispatchGeneration
        var completed = false
        var detail: NSString?
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if diagnosticEnabled { fputs("HOVER_NATIVE phase=drain.registration.before elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart))\n", stderr) }
        #endif
        let status = SFRCallWithVoidCompletion(webView, "_doAfterProcessingAllPendingMouseEvents:", { [weak self] in
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if diagnosticEnabled { fputs("HOVER_NATIVE phase=drain.callback_arrived elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart))\n", stderr) }
            #endif
            MainActor.assumeIsolated {
                guard let self, self.epoch == currentEpoch, !self.activityClosed else { return }
                completed = true
            }
        }, &detail)
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if diagnosticEnabled { fputs("HOVER_NATIVE phase=drain.registration elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) status=\(status.rawValue)\n", stderr) }
        if status != .OK { diagnosticResult = "registration_failed" }
        #endif
        guard status == .OK else { uncertainDispatch = true; throw AutomationError(code: .backendUnavailable) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if boundContext != nil && !completed {
            let presentationStatus = SFRCallWithVoidCompletion(webView, "_doAfterNextPresentationUpdate:", {
                fputs("HOVER_NATIVE phase=drain.presentation_callback elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart))\n", stderr)
            }, &detail)
            fputs("HOVER_NATIVE phase=drain.presentation_registration elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) status=\(presentationStatus.rawValue)\n", stderr)
            guard presentationStatus == .OK else {
                diagnosticResult = "presentation_registration_failed"
                uncertainDispatch = true
                throw AutomationError(code: .backendUnavailable)
            }
        }
        #endif
        while !completed && ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard epoch == currentEpoch, !activityClosed else {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticResult = epoch != currentEpoch ? "epoch" : "closed"
                #endif
                throw AutomationError(code: .cancelled)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard completed, epoch == currentEpoch, !activityClosed else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticResult = !completed ? "timeout" : (epoch != currentEpoch ? "epoch" : "closed")
            #endif
            throw AutomationError(code: .timeout)
        }
        guard generation == mouseDispatchGeneration else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticResult = "generation"
            #endif
            uncertainDispatch = true; throw AutomationError(code: .sessionBusy)
        }
        pendingMouse = false
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        diagnosticResult = "completed"
        #endif
    }

    /// Native delivery is not a claim about DOM processing. The production gate is still closed.
    func perform(_ action: AutomationAction, viewVersion: UInt64) async throws -> AutomationResult {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && !SAFARIER_WHEEL_OBSERVER_PROBE
        if registeredTarget != nil, case .scroll = action {
            throw AutomationError(code: .uiPolicyUnavailable)
        }
        #endif
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        let diagnosticMove: Bool
        if boundContext != nil, case .move = action { diagnosticMove = true } else { diagnosticMove = false }
        if diagnosticMove { fputs("HOVER_NATIVE phase=perform.enter elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) failure=\(hoverNativeFailureCode(failure)) pendingMouse=\(pendingMouse)\n", stderr) }
        #endif
        do { try Task.checkCancellation() } catch { uncertainDispatch = true; revokeBoundOnNativeFailure(); closeActivity(); throw AutomationError(code: .cancelled) }
        guard !performing, !pendingMouse, snapshotWaiter == nil else { throw AutomationError(code: .sessionBusy) }
        guard viewVersion == expectedViewVersion else { throw AutomationError(code: .targetChanged) }
        if case let .key(name, shift) = action, !NativeInputPreflight.keyAllowed(name: name, shift: shift) { throw AutomationError(code: .invalidRequest) }
        let width = Double(expectedBounds.width), height = Double(expectedBounds.height), scale = Double(expectedScale)
        guard width.isFinite, height.isFinite, scale.isFinite, width > 0, height > 0, scale > 0,
              width * scale <= Double(Int32.max), height * scale <= Double(Int32.max) else { throw AutomationError(code: .targetChanged) }
        let pixelWidth = Int((width * scale).rounded()), pixelHeight = Int((height * scale).rounded())
        let viewport = AutomationViewport(viewportWidthPoints: width, viewportHeightPoints: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scaleX: Double(pixelWidth) / width, scaleY: Double(pixelHeight) / height, pageZoom: Double(expectedZoom), viewVersion: expectedViewVersion)
        guard NativeInputPreflight.geometryMatches(viewport, width: width, height: height, scale: scale, zoom: Double(expectedZoom), version: viewVersion), valid(position) else { throw AutomationError(code: .targetChanged) }
        func validate(_ point: ViewportPoint, _ version: UInt64) throws {
            guard version == viewVersion else { throw AutomationError(code: .targetChanged) }
            guard viewport.contains(point) else { throw AutomationError(code: .outOfBounds) }
        }
        performing = true
        defer { performing = false }
        switch action {
        case let .move(point, version):
            try validate(point, version)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if diagnosticMove { fputs("HOVER_NATIVE phase=move.before elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) failure=\(hoverNativeFailureCode(failure)) pendingMouse=\(pendingMouse)\n", stderr) }
            #endif
            move(point.x, point.y)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if diagnosticMove { fputs("HOVER_NATIVE phase=move.after elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) failure=\(hoverNativeFailureCode(failure)) pendingMouse=\(pendingMouse)\n", stderr) }
            #endif
        case let .mouseDown(point, version):
            try validate(point, version)
            guard NativeInputPreflight.nextButtonState(held: buttonMask != 0, action: .down) != nil else { throw AutomationError(code: .invalidPointerState) }
            press(point.x, point.y)
        case let .mouseUp(point, version):
            try validate(point, version)
            guard NativeInputPreflight.nextButtonState(held: buttonMask != 0, action: .up) != nil else { throw AutomationError(code: .invalidPointerState) }
            release(point.x, point.y)
        case let .click(point, version, count):
            try validate(point, version)
            guard NativeInputPreflight.nextButtonState(held: buttonMask != 0, action: .click) != nil else { throw AutomationError(code: .invalidPointerState) }
            guard count == 1 || count == 2 else { throw AutomationError(code: .invalidRequest) }
            click(point.x, point.y, count: count)
        case let .scroll(point, version, dx, dy):
            try validate(point, version)
            guard let delta = NativeInputPreflight.scrollDelta(x: dx, y: dy) else { throw AutomationError(code: .invalidRequest) }
            scroll(point.x, point.y, delta: delta)
        case let .key(name, shift): key(name, shift: shift)
        case let .insertText(text):
            guard NativeInputPreflight.textAllowed(text) else { throw AutomationError(code: .invalidRequest) }
            type(text)
        default: throw AutomationError(code: .invalidRequest)
        }
        do {
            if failure != nil { throw AutomationError(code: .backendUnavailable) }
            if pendingMouse { try await drain() }
            try Task.checkCancellation()
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if diagnosticMove {
                let code = (error as? AutomationError)?.code.rawValue ?? (error is CancellationError ? "cancelled" : "unknown")
                fputs("HOVER_NATIVE phase=perform.failure elapsed_ms=\(hoverNativeElapsedMs(diagnosticStart)) code=\(code) failure=\(hoverNativeFailureCode(failure)) pendingMouse=\(pendingMouse)\n", stderr)
            }
            #endif
            uncertainDispatch = true
            revokeBoundOnNativeFailure()
            closeActivity()
            if error is CancellationError { throw AutomationError(code: .cancelled) }
            throw error
        }
        guard deliverySequence < UInt64.max else { uncertainDispatch = true; revokeBoundOnNativeFailure(); closeActivity(); throw AutomationError(code: .backendUnavailable) }
        deliverySequence += 1
        return .nativeDelivered(sequence: deliverySequence, buttons: Int(buttonMask), viewVersion: expectedViewVersion)
    }

    @MainActor private final class SnapshotWaiter {
        private let oneShot = NativeInputPreflight.OneShot()
        private var continuation: CheckedContinuation<NSImage, Error>?
        private var result: Result<NSImage, Error>?
        var timeoutTask: Task<Void, Never>?
        func install(_ continuation: CheckedContinuation<NSImage, Error>) {
            if let result { continuation.resume(with: result) } else { self.continuation = continuation }
        }
        func finish(_ result: Result<NSImage, Error>) {
            guard oneShot.claim() else { return }
            self.result = result
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    struct Snapshot {
        let png: Data
        let viewport: AutomationViewport
    }

    func captureSnapshot(viewVersion: UInt64) async throws -> Snapshot {
        if Task.isCancelled { throw AutomationError(code: .cancelled) }
        guard !performing, !pendingMouse else { throw AutomationError(code: .sessionBusy) }
        guard viewVersion == expectedViewVersion, valid(position) else { throw AutomationError(code: .targetChanged) }
        let currentEpoch = epoch
        let width = expectedBounds.width * expectedScale, height = expectedBounds.height * expectedScale
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(AutomationLimits.screenshotMaxEdge), height <= CGFloat(AutomationLimits.screenshotMaxEdge) else { throw AutomationError(code: .outOfBounds) }
        guard snapshotWaiter == nil else { throw AutomationError(code: .sessionBusy) }
        let waiter = SnapshotWaiter()
        snapshotWaiter = waiter
        defer { if snapshotWaiter === waiter { snapshotWaiter = nil }; waiter.timeoutTask?.cancel() }
        let image: NSImage = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                waiter.timeoutTask = Task { @MainActor [weak waiter] in
                    do { try await Task.sleep(nanoseconds: UInt64(AutomationLimits.actionSeconds * 1_000_000_000)) } catch { return }
                    waiter?.finish(.failure(AutomationError(code: .timeout)))
                }
                webView.takeSnapshot(with: nil) { [weak self, weak waiter] image, error in
                    Task { @MainActor [weak self, weak waiter] in
                        guard let waiter else { return }
                        guard let self, self.epoch == currentEpoch, self.activityLease != nil, !self.activityClosed else {
                            waiter.finish(.failure(AutomationError(code: .targetChanged))); return
                        }
                        if let image, error == nil { waiter.finish(.success(image)) }
                        else { waiter.finish(.failure(AutomationError(code: .backendUnavailable))) }
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak waiter] in waiter?.finish(.failure(AutomationError(code: .cancelled))) }
        })
        if Task.isCancelled { throw AutomationError(code: .cancelled) }
        guard epoch == currentEpoch, valid(position) else { throw AutomationError(code: .targetChanged) }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width == Int(width.rounded()), cgImage.height == Int(height.rounded()),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
              png.count <= AutomationLimits.screenshotMaxBytes else { throw AutomationError(code: .backendUnavailable) }
        let viewport = AutomationViewport(viewportWidthPoints: Double(expectedBounds.width), viewportHeightPoints: Double(expectedBounds.height), pixelWidth: cgImage.width, pixelHeight: cgImage.height, scaleX: Double(cgImage.width) / Double(expectedBounds.width), scaleY: Double(cgImage.height) / Double(expectedBounds.height), pageZoom: Double(expectedZoom), viewVersion: viewVersion)
        guard NativeInputPreflight.viewportValid(viewport) else { throw AutomationError(code: .targetChanged) }
        return Snapshot(png: png, viewport: viewport)
    }

    func closeActivity() {
        guard !finishRequested else { return }
        finishRequested = true
        epoch &+= 1
        snapshotWaiter?.finish(.failure(AutomationError(code: .targetChanged)))
        activityReady = false
        requiresOwnedTargetDestruction = NativeInputPreflight.requiresOwnedTargetDestruction(held: buttonMask != 0, pending: pendingMouse, uncertain: uncertainDispatch, previouslyRequired: requiresOwnedTargetDestruction)
        guard let token = activityLease else { activityClosed = true; return }
        var detail: NSString?
        activityStatus = SFRFinishBackgroundPageActivity(token, { [weak self] in
            MainActor.assumeIsolated { self?.activityClosed = true }
        }, &detail)
        activityLease = nil
        #if SAFARIER_NATIVE_PROBE
        trace.append(["activityEndStatus": activityStatus.rawValue])
        #endif
    }
}
