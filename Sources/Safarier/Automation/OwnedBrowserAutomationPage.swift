import AppKit
import WebKit
import SafarierCore
#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
import ObjectiveC
import SafarierObjCSupport
#endif
#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Darwin
#endif

#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
private func internalNavigationErrorFields(_ error: Error) -> String {
    if let automationError = error as? AutomationError {
        return "automationCode=\(automationError.code.rawValue)"
    }
    let nsError = error as NSError
    let category = nsError.domain == NSURLErrorDomain ? "url" : (["WKErrorDomain", "WebKitErrorDomain"].contains(nsError.domain) ? "webkit" : "other")
    return "errorDomain=\(category) errorCode=\(nsError.code)"
}

private func registeredNativeTrace(_ phase: StaticString, epoch: UInt64, result: String = "ok") {
    let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
    fputs("REGISTERED_NATIVE_DIAG phase=\(phase) monotonic_ms=\(ms) epoch=\(epoch) result=\(result)\n", stderr)
}

private func registeredNativeError(_ error: Error) -> String {
    if let error = error as? AutomationError { return error.code.rawValue }
    return error is CancellationError ? "cancelled" : "other"
}

enum InternalNavigationPolicy {
    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, let host = url.host, !host.isEmpty, host != ".",
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return false }
        return true
    }
    static func allowsFrameURL(_ url: URL) -> Bool {
        isWebURL(url) || url.absoluteString == "about:blank"
    }
}
#endif

/// Owns only the objects admitted by the background factory. It never adopts an
/// interactive window, and teardown is deliberately not a destruction proof.
@MainActor
final class OwnedBrowserAutomationPage: RunnerAutomationPage {
    let identity: AutomationTargetIdentity
    var onBlocked: ((BackgroundUIRequest) -> Void)?

    private var session: BrowserSession?
    private var controller: BrowserWindowController?
    private var webView: BrowserWebView?
    private var window: NSWindow?
    private var input: NativePageInput?
    private let windowNumber: Int
    private let frame: NSRect
    private let bounds: NSRect
    private let scale: CGFloat
    private let zoom: CGFloat
    private var version: UInt64 = 1
    private var epoch: UInt64 = 0
    private var invalidated = false
    private var navigating = false
    private var navigation: WKNavigation?
    private var correlation = NavigationCorrelation()
    private var navigationEpoch: UInt64 = 0
    private enum NavigationOutcome { case finished, failed(Error, provisional: Bool) }
    private var navigationOutcome: NavigationOutcome?
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var boundContext: RunnerBinderContext?
    private var registeredGeneration: UUID?
    private var registeredBorrowed = false
    private var registeredURL: URL?
    private var registeredNavigationURL: URL?
    #if SAFARIER_INTERNAL_TEST_APP
    struct RegisteredFrameSnapshot {
        let view: NSObject
        let handle: NSObject
        let document: NSUUID
        let url: URL
    }
    private final class FrameSnapshotReply {
        var closed = false
        var received = false
        var object: AnyObject?
    }
    static func registeredFrameSnapshot(view: NSObject, source: URL, deadline: ContinuousClock.Instant,
                                        valid: @escaping @MainActor () -> Bool) async throws -> RegisteredFrameSnapshot {
        func check() throws {
            guard !Task.isCancelled, ContinuousClock.now < deadline, valid() else { throw AutomationError(code: .targetChanged) }
        }
        try check()
        var handleObject: AnyObject?
        guard SFRGetObject(view, "_mainFrame", &handleObject, nil).rawValue == 0,
              let handle = handleObject as? NSObject else { throw AutomationError(code: .targetChanged) }
        let reply = FrameSnapshotReply()
        defer { reply.closed = true }
        let status = SFRCallWithObjectCompletion(view, "_frameInfoFromHandle:completionHandler:", handle, { object in
            Task { @MainActor in
                guard !reply.closed, !reply.received else { return }
                reply.object = object as AnyObject?; reply.received = true
            }
        }, nil)
        guard status.rawValue == 0 else { throw AutomationError(code: .targetChanged) }
        while !reply.received {
            try check()
            try await Task.sleep(nanoseconds: 5_000_000)
            try check()
        }
        try check()
        guard let frame = reply.object else { throw AutomationError(code: .targetChanged) }
        var frameView: AnyObject?, requestObject: AnyObject?, documentObject: AnyObject?
        var main: ObjCBool = false
        guard SFRGetObject(frame, "webView", &frameView, nil).rawValue == 0, frameView === view,
              SFRGetBool(frame, "isMainFrame", &main, nil).rawValue == 0, main.boolValue,
              SFRGetObject(frame, "request", &requestObject, nil).rawValue == 0,
              let request = requestObject as? NSURLRequest, request.url == source,
              SFRGetObject(frame, "_documentIdentifier", &documentObject, nil).rawValue == 0,
              let document = documentObject as? NSUUID else { throw AutomationError(code: .targetChanged) }
        var latestHandle: AnyObject?
        guard SFRGetObject(view, "_mainFrame", &latestHandle, nil).rawValue == 0,
              let latestHandle = latestHandle as? NSObject, latestHandle.isEqual(handle) else { throw AutomationError(code: .targetChanged) }
        try check()
        return RegisteredFrameSnapshot(view: view, handle: handle, document: document, url: source)
    }

    @MainActor final class RegisteredNativePermit {
        let source: URL
        let epoch: UInt64
        var action: WKNavigationAction?
        var decision: ((WKNavigationActionPolicy) -> Void)?
        private(set) var sameDocumentSequence: UInt64 = 0
        private(set) var sameDocumentURL: URL?
        // A same-URL replace may precede the actual navigation; retain its sequence but keep waiting.
        var sameDocumentReady: Bool { sameDocumentURL != nil && sameDocumentURL != source }
        var sourceSnapshot: RegisteredFrameSnapshot?
        var allowsFullNavigation: Bool { !released && sameDocumentSequence == 0 }
        private func sameOrigin(_ a: URL, _ b: URL) -> Bool {
            guard InternalNavigationPolicy.isWebURL(a), InternalNavigationPolicy.isWebURL(b),
                  let scheme = a.scheme?.lowercased(), scheme == b.scheme?.lowercased(),
                  let host = a.host?.lowercased(), host == b.host?.lowercased() else { return false }
            let defaultPort = scheme == "https" ? 443 : 80
            return (a.port ?? defaultPort) == (b.port ?? defaultPort)
        }
        func recordSameDocument(view: NSObject?, expectedView: NSObject, epoch: UInt64, abi: Bool,
                                type: Int, request: URL?, current: URL?, baseline: RegisteredFrameSnapshot) -> Bool {
            guard !released, action == nil, decision == nil, epoch == self.epoch, abi, [1, 2].contains(type),
                  view === expectedView, baseline.view === expectedView, baseline.url == source,
                  let request, request == current, sameOrigin(source, request), sameDocumentSequence < UInt64.max else { return false }
            sameDocumentSequence += 1; sameDocumentURL = request
            return true
        }
        func acceptsSameDocument(snapshot: RegisteredFrameSnapshot, baseline: RegisteredFrameSnapshot,
                                 sequence: UInt64, epoch: UInt64, current: URL?, deadline: ContinuousClock.Instant) -> Bool {
            guard !released, action == nil, decision == nil, epoch == self.epoch, !Task.isCancelled,
                  ContinuousClock.now < deadline, sameDocumentReady, sequence > 0, sequence == sameDocumentSequence,
                  let target = sameDocumentURL, current == target, snapshot.url == target, baseline.url == source,
                  snapshot.view === baseline.view, snapshot.handle.isEqual(baseline.handle),
                  snapshot.document.isEqual(baseline.document), sameOrigin(source, target) else { return false }
            return true
        }
        private(set) var released = false
        private var inputWatchdog: Task<Void, Never>?
        func watchInput(until deadline: ContinuousClock.Instant, expired: @escaping @MainActor () -> Void) {
            inputWatchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard let self, !self.released else { return }
                expired()
            }
        }
        func cancelInputWatchdog() { inputWatchdog?.cancel(); inputWatchdog = nil }
        func releaseForNavigation() {
            cancelInputWatchdog()
            released = true
            decide(.allow)
        }
        init(source: URL, epoch: UInt64) { self.source = source; self.epoch = epoch }
        func decide(_ policy: WKNavigationActionPolicy) { let completion = decision; decision = nil; completion?(policy) }
    }
    private var registeredNativePermit: RegisteredNativePermit?
    #endif
    private var controlReleasePrepared = false
    private var boundFixture: URL?
    private var boundNavigationDelegate: BoundFixtureNavigationDelegate?
    private var fixtureReady = false
    private var boundPointerHeld = false
    #if SAFARIER_INTERNAL_TEST_APP
    private var boundCommittedURL: URL?
    private final class NativeNavigationPermit {
        let source: FinishedSourceProof
        let commandEpoch: UInt64
        let oldInput: NativePageInput
        let oldVersion: UInt64
        let expectedViewport: AutomationViewport
        let deadline: ContinuousClock.Instant
        var action: WKNavigationAction?
        var decision: ((WKNavigationActionPolicy) -> Void)?
        var released = false
        init(source: FinishedSourceProof, commandEpoch: UInt64, oldInput: NativePageInput, oldVersion: UInt64,
             expectedViewport: AutomationViewport, deadline: ContinuousClock.Instant) {
            self.source = source; self.commandEpoch = commandEpoch; self.oldInput = oldInput
            self.oldVersion = oldVersion; self.expectedViewport = expectedViewport; self.deadline = deadline
        }
        func decide(_ policy: WKNavigationActionPolicy) {
            let callback = decision; decision = nil; callback?(policy)
        }
    }
    private var nativeNavigationPermit: NativeNavigationPermit?
    private var knownNativeNavigations: [WKNavigation] = []
    #if !SAFARIER_WHEEL_OBSERVER_PROBE
    private enum BoundPresentation { case hidden, visibleObservation }
    private var boundPresentation: BoundPresentation = .hidden
    #endif
    private struct FinishedSourceProof {
        let navigation: WKNavigation
        let url: URL
        let pageEpoch: UInt64
    }
    private enum ContinuationKind: String { case finished, provisional }
    private struct PendingContinuation {
        let kind: ContinuationKind
        let source: FinishedSourceProof
        let action: WKNavigationAction
        let parent: WKNavigation
        let navigationEpoch: UInt64
        let pageEpoch: UInt64
        let expectedURL: URL
        let deadline: ContinuousClock.Instant
        let ticket: UUID
    }
    private var pendingContinuation: PendingContinuation?
    private var acceptedContinuationActions: [WKNavigationAction] = []
    private var continuationDeadline: ContinuousClock.Instant?
    private var continuationViewport: AutomationViewport?
    private var finishedDocumentURL: URL?
    private var committedDocumentURL: URL?
    private var lastFinishedSourceProof: FinishedSourceProof?
    #endif
    // Sequence is an additional fixture restriction, never a focus or identity proof.
    private var boundFormNext: BoundFixtureFormPolicy.FormOperation? = .clickButton

    private static func isBoundFixtureDragPoint(_ point: ViewportPoint) -> Bool {
        point.x >= 600 && point.x < 750 && point.y >= 240 && point.y < 295
    }
    #endif

    private init(session: BrowserSession, controller: BrowserWindowController, runnerInstanceID: UUID, input: NativePageInput?, identity: AutomationTargetIdentity? = nil) {
        self.session = session
        self.controller = controller
        self.webView = controller.webView
        self.window = controller.window
        self.input = input
        self.windowNumber = controller.window.windowNumber
        self.frame = controller.window.frame
        self.bounds = controller.webView.bounds
        self.scale = controller.window.backingScaleFactor
        self.zoom = controller.webView.pageZoom
        self.identity = identity ?? AutomationTargetIdentity(profileID: session.profile.id, runnerInstanceID: runnerInstanceID, windowID: UUID(), pageID: UUID())
    }

    static func attach(session: BrowserSession, controller: BrowserWindowController, runnerInstanceID: UUID) async throws -> OwnedBrowserAutomationPage {
        try NativePageInput.requireShippingAdmission()
        guard session.executionPolicy == .automationBackground,
              session.openControllers.contains(where: { $0 === controller }),
              controller.session === session,
              controller.onAutomationNavigation == nil, session.onAutomationUIBlocked == nil,
              !controller.isShowingStartPage,
              controller.webView.window === controller.window,
              controller.window.windowNumber > 0, !NSApp.isActive,
              !controller.window.isKeyWindow, !controller.window.isMainWindow,
              !controller.window.isVisible, controller.window.ignoresMouseEvents,
              controller.window.tabbingMode == .disallowed else {
            throw AutomationError(code: .targetChanged)
        }
        let input = try NativePageInput.open(webView: controller.webView, window: controller.window)
        let page = OwnedBrowserAutomationPage(session: session, controller: controller, runnerInstanceID: runnerInstanceID, input: input)
        controller.onAutomationNavigation = { [weak page] event in page?.handleNavigation(event) }
        session.onAutomationUIBlocked = { [weak page] request in page?.block(request) }
        do {
            try await input.waitUntilReady()
            _ = try page.viewport()
            return page
        } catch {
            _ = await page.destroy()
            throw error
        }
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    static func attachRegistered(session: BrowserSession, controller: BrowserWindowController,
                                 context: RunnerBinderContext, monitor: RegisteredTabMonitor?, generation: UUID) async throws -> OwnedBrowserAutomationPage {
        try await context.validate()
        guard context.profileID == session.profile.id,
              session.registeredTargetValid(controller, monitor: monitor),
              controller.session === session, controller.webView.window === controller.window,
              let url = controller.webView.url else {
            RegisteredAdmissionDiagnostic.check(false, .attachTarget)
            throw AutomationError(code: .interactionRequired)
        }
        guard RegisteredAdmissionDiagnostic.check(!controller.webView.isLoading, .loading) else { throw AutomationError(code: .interactionRequired) }
        let target = AutomationTargetIdentity(profileID: session.profile.id,
            runnerInstanceID: context.runnerInstanceID, windowID: controller.registeredWindowID,
            pageID: controller.registeredPageID)
        try context.sealRegisteredTarget(target)
        let input = try NativePageInput.prepareRegistered(webView: controller.webView, window: controller.window,
                                                          context: context, target: target)
        let generation = try session.beginRegisteredControl(controller: controller, monitor: monitor, generation: generation)
        let page = OwnedBrowserAutomationPage(session: session, controller: controller,
                                              runnerInstanceID: context.runnerInstanceID, input: input, identity: target)
        page.boundContext = context
        page.registeredBorrowed = true
        page.registeredGeneration = generation
        page.registeredURL = url
        page.configureRegisteredInput(input)
        let delegate = BoundFixtureNavigationDelegate(fixture: url, context: context, expectedWebView: controller.webView,
            event: { [weak page] event in page?.handleNavigation(event) }, blocked: { [weak page] in page?.block(.unknown) }, registered: true)
        #if SAFARIER_INTERNAL_TEST_APP
        delegate.retiredNavigation = { [weak page] navigation in page?.correlation.isRetired(navigation) == true }
        delegate.redirectMatches = { [weak page] navigation in
            guard let page else { return false }
            return page.correlation.matches(navigation, epoch: page.navigationEpoch)
        }
        delegate.nativePermitPresent = { [weak page] in page?.registeredNativePermit != nil }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        delegate.sameDocumentPermitSnapshot = { [weak page] sourceURL, targetURL in
            guard let page, let permit = page.registeredNativePermit else { return (false, false, false, false) }
            return (true, page.epoch == permit.epoch, sourceURL != nil && sourceURL == permit.source,
                    targetURL != nil && targetURL != permit.source)
        }
        delegate.sameDocumentCandidate = { [weak page] callbackView, navigation, type, request, current in
            guard let page, let permit = page.registeredNativePermit, let baseline = permit.sourceSnapshot,
                  page.navigating, !page.invalidated, page.epoch == permit.epoch,
                  let ownedView = page.webView, navigation != nil,
                  (try? context.checkLive()) != nil, (try? context.validateRegisteredTarget(page.identity)) != nil,
                  (try? page.checkedOwnedObjects()) != nil,
                  permit.recordSameDocument(view: callbackView, expectedView: ownedView, epoch: page.epoch,
                      abi: BoundFixtureNavigationDelegate.sameDocumentABI, type: type, request: request,
                      current: current, baseline: baseline) else {
                page?.block(.unknown, reason: "registered.sameDocumentRejected")
                return
            }
        }
        #endif
        delegate.nativePolicy = { [weak page] action, decision in
            var identityChecked = false, identityValid = false
            guard let page, let permit = page.registeredNativePermit, permit.allowsFullNavigation,
                  permit.action == nil, permit.decision == nil, page.navigating,
                  page.epoch == permit.epoch, !page.invalidated,
                  let webView = page.webView, action.sourceFrame.webView === webView,
                  action.sourceFrame.isMainFrame, action.targetFrame?.isMainFrame == true,
                  action.targetFrame?.webView === webView, action.sourceFrame.request.url == permit.source,
                  let url = action.request.url, InternalNavigationPolicy.isWebURL(url), !action.shouldPerformDownload,
                  ({ identityChecked = true; identityValid = (try? context.validateRegisteredTarget(page.identity)) != nil; return identityValid })() else {
                let permit = page?.registeredNativePermit
                let webView = page?.webView
                let target = action.targetFrame
                let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
                fputs("REGISTERED_NATIVE_DIAG phase=policy.rejected monotonic_ms=\(ms) epoch=\(permit?.epoch ?? 0) permitPresent=\(permit != nil) released=\(permit?.released == true) actionEmpty=\(permit != nil && permit?.action == nil) decisionEmpty=\(permit != nil && permit?.decision == nil) navigating=\(page?.navigating == true) epochMatches=\(permit != nil && page?.epoch == permit?.epoch) invalidated=\(page?.invalidated == true) sourceOwned=\(webView != nil && action.sourceFrame.webView === webView) sourceMain=\(action.sourceFrame.isMainFrame) targetPresent=\(target != nil) targetMain=\(target?.isMainFrame == true) targetOwned=\(webView != nil && target?.webView === webView) sourceMatches=\(permit != nil && action.sourceFrame.request.url == permit?.source) webURL=\(action.request.url.map { InternalNavigationPolicy.isWebURL($0) } ?? false) download=\(action.shouldPerformDownload) identityChecked=\(identityChecked) identityValid=\(identityValid)\n", stderr)
                return false
            }
            permit.action = action; permit.decision = decision
            registeredNativeTrace("policy.accepted", epoch: permit.epoch)
            return true
        }
        delegate.hasPendingContinuation = { [weak page] in page?.correlation.hasPendingContinuation == true }
        #endif
        page.boundNavigationDelegate = delegate
        controller.cancelPageRetry()
        controller.webView.navigationDelegate = delegate
        session.onAutomationUIBlocked = { [weak page] request in page?.block(request) }
        do {
            try context.validateRegisteredTarget(target)
            try await context.validate()
            guard controller.webView.url == url, !controller.webView.isLoading else { throw AutomationError(code: .targetChanged) }
            try session.presentRegisteredControl(controller: controller, generation: generation, input: input)
            try input.startRegistered()
            try await input.waitUntilReady()
            try await context.validate()
            try context.validateRegisteredTarget(target)
            _ = try page.viewport()
            return page
        } catch {
            // The prepared object exists before the window is locked, so even
            // a failure before native start has a verifiable rollback path.
            _ = await page.destroy()
            context.beginClosing()
            throw error
        }
    }

    private func configureRegisteredInput(_ input: NativePageInput) {
        input.registeredTargetValidator = { [weak self] in
            guard let self, let session = self.session, let controller = self.controller,
                  let generation = self.registeredGeneration else { return false }
            return session.registeredPresentationValid(controller: controller, generation: generation)
        }
    }

    static func attachBound(session: BrowserSession, controller: BrowserWindowController, context: RunnerBinderContext) async throws -> OwnedBrowserAutomationPage {
        try await context.validate()
        let fixture = try context.localFixtureURL()
        guard fixture.isFileURL, session.profile.id == context.profileID,
              session.executionPolicy == .automationBackground,
              session.openControllers.contains(where: { $0 === controller }),
              controller.session === session, controller.webView.window === controller.window,
              controller.webView.legacySystemDragBoundaryInstalled,
              !controller.isShowingStartPage, !NSApp.isActive, !controller.window.isVisible,
              !controller.window.isKeyWindow, !controller.window.isMainWindow,
              !controller.window.canBecomeKey, !controller.window.canBecomeMain,
              controller.window.ignoresMouseEvents, controller.window.tabbingMode == .disallowed else {
            let fixtureFile = fixture.isFileURL
            let profileMatch = session.profile.id == context.profileID
            let policy = session.executionPolicy == .automationBackground
            let controllerOwned = session.openControllers.contains(where: { $0 === controller })
            let controllerSession = controller.session === session
            let webViewWindow = controller.webView.window === controller.window
            let legacyBoundary = controller.webView.legacySystemDragBoundaryInstalled
            let startPageHidden = !controller.isShowingStartPage
            let appInactive = !NSApp.isActive
            let windowHidden = !controller.window.isVisible
            let notKey = !controller.window.isKeyWindow
            let notMain = !controller.window.isMainWindow
            let cannotKey = !controller.window.canBecomeKey
            let cannotMain = !controller.window.canBecomeMain
            let ignoresMouse = controller.window.ignoresMouseEvents
            let tabbingDisabled = controller.window.tabbingMode == .disallowed
            fputs("OPEN_DIAG phase=runner.attach_guard fixtureFile=\(fixtureFile) profileMatch=\(profileMatch) policy=\(policy) controllerOwned=\(controllerOwned) controllerSession=\(controllerSession) webViewWindow=\(webViewWindow) legacyBoundary=\(legacyBoundary) startPageHidden=\(startPageHidden)\n", stderr)
            fputs("OPEN_DIAG phase=runner.attach_window appInactive=\(appInactive) windowHidden=\(windowHidden) notKey=\(notKey) notMain=\(notMain) cannotKey=\(cannotKey) cannotMain=\(cannotMain) ignoresMouse=\(ignoresMouse) tabbingDisabled=\(tabbingDisabled)\n", stderr)
            throw AutomationError(code: .targetChanged)
        }
        let page = OwnedBrowserAutomationPage(session: session, controller: controller, runnerInstanceID: context.runnerInstanceID, input: nil)
        page.boundContext = context
        page.boundFixture = fixture
        let delegate = BoundFixtureNavigationDelegate(fixture: fixture, context: context, expectedWebView: controller.webView, event: { [weak page] event in page?.handleNavigation(event) }, blocked: { [weak page] in page?.block(.unknown) })
        #if SAFARIER_INTERNAL_TEST_APP
        delegate.nativePolicy = { [weak page] action, decision in
            page?.handleNativePolicy(action, decision: decision) == true
        }
        delegate.nativePermitPresent = { [weak page] in page?.nativeNavigationPermit != nil }
        delegate.reserveContinuation = { [weak page] action in
            page?.reserveContinuation(action) == true
        }
        delegate.confirmProvisionalRedirect = { [weak page] navigation in
            page?.confirmProvisionalContinuation(navigation, requireCommittedResponse: false) == true
        }
        delegate.hasPendingContinuation = { [weak page] in
            page?.correlation.hasPendingContinuation == true
        }
        delegate.redirectMatches = { [weak page] navigation in
            guard let page else { return false }
            return page.correlation.matches(navigation, epoch: page.navigationEpoch)
        }
        #endif
        page.boundNavigationDelegate = delegate
        controller.cancelPageRetry()
        controller.webView.navigationDelegate = delegate
        session.onAutomationUIBlocked = { [weak page] request in page?.block(request) }
        // Before navigation WebKit may report no URL. Any reported URL must be
        // exactly the bound fixture; after navigation it must be present.
        func checkPreparation(requireLoaded: Bool) throws {
            try context.checkLive()
            let expected = try context.localFixtureURL()
            let current = controller.webView.url
            guard !Task.isCancelled, !page.invalidated, expected == fixture,
                  page.boundFixture == fixture,
                  current == fixture || (!requireLoaded && current == nil) else {
                throw AutomationError(code: .targetChanged)
            }
        }
        do {
            try checkPreparation(requireLoaded: false)
            try await context.validate()
            try checkPreparation(requireLoaded: false)
            fputs("OPEN_DIAG phase=runner.fixture_load.before\n", stderr)
            #if SAFARIER_INTERNAL_TEST_APP
            guard page.knownNativeNavigations.count < AutomationLimits.replayEntries else { throw AutomationError(code: .targetChanged) }
            #endif
            guard let navigation = controller.webView.loadFileURL(fixture, allowingReadAccessTo: fixture) else { throw AutomationError(code: .backendUnavailable) }
            page.navigation = navigation
            page.navigationEpoch = page.correlation.begin(navigation)
            let deadline = ContinuousClock.now + .seconds(AutomationLimits.navigationSeconds)
            while page.navigationOutcome == nil {
                try checkPreparation(requireLoaded: false)
                try await context.validate()
                try checkPreparation(requireLoaded: false)
                guard !Task.isCancelled, !page.invalidated, ContinuousClock.now < deadline else { throw AutomationError(code: .targetChanged) }
                try await Task.sleep(nanoseconds: 10_000_000)
                try checkPreparation(requireLoaded: false)
            }
            try checkPreparation(requireLoaded: true)
            guard case .finished? = page.navigationOutcome,
                  page.correlation.finish(navigation, epoch: page.navigationEpoch), controller.webView.url == fixture else { throw AutomationError(code: .targetChanged) }
            page.navigation = nil
            page.fixtureReady = true
            #if SAFARIER_INTERNAL_TEST_APP
            page.boundCommittedURL = fixture
            page.lastFinishedSourceProof = FinishedSourceProof(navigation: navigation, url: fixture, pageEpoch: page.epoch)
            guard page.knownNativeNavigations.count < AutomationLimits.replayEntries else { throw AutomationError(code: .targetChanged) }
            page.knownNativeNavigations.append(navigation)
            #endif
            try checkPreparation(requireLoaded: true)
            fputs("OPEN_DIAG phase=runner.native_open.before\n", stderr)
            let input = try NativePageInput.open(webView: controller.webView, window: controller.window, context: context)
            page.input = input
            fputs("OPEN_DIAG phase=runner.native_open.after\n", stderr)
            try checkPreparation(requireLoaded: true)
            try await input.waitUntilReady()
            try checkPreparation(requireLoaded: true)
            try await context.validate()
            try checkPreparation(requireLoaded: true)
            _ = try page.viewport()
            #if SAFARIER_WHEEL_OBSERVER_PROBE
            let observerEpoch = page.epoch
            let observerViewport = try page.viewport()
            let probe = BoundWheelObserverProbe(webView: controller.webView, context: context) {
                try checkPreparation(requireLoaded: true)
                guard page.epoch == observerEpoch, page.input === input, page.webView === controller.webView,
                      input.activityReady, !input.activityClosed, let app = NSApp,
                      app.activationPolicy() == .prohibited, !app.isActive,
                      try page.viewport() == observerViewport else { throw AutomationError(code: .targetChanged) }
            }
            try await probe.run(epoch: observerEpoch)
            try checkPreparation(requireLoaded: true)
            guard page.epoch == observerEpoch, page.input === input,
                  try page.viewport() == observerViewport else { throw AutomationError(code: .targetChanged) }
            #endif
            #if SAFARIER_INTERNAL_TEST_APP && !SAFARIER_WHEEL_OBSERVER_PROBE
            let presentationEpoch = page.epoch
            let presentationViewport = try page.viewport()
            guard !Task.isCancelled, page.boundContext === context, page.epoch == presentationEpoch,
                  page.input === input, input.activityReady, !input.activityClosed,
                  input.activityStatus == .OK, !input.requiresOwnedTargetDestruction,
                  !page.boundPointerHeld, let app = NSApp, !app.isActive,
                  app.activationPolicy() == .prohibited,
                  page.window === controller.window, page.webView === controller.webView,
                  !controller.window.canBecomeKey, !controller.window.canBecomeMain else {
                throw AutomationError(code: .targetChanged)
            }
            try context.checkLive()
            guard app.setActivationPolicy(.accessory), app.activationPolicy() == .accessory,
                  !app.isActive, page.epoch == presentationEpoch, page.input === input,
                  input.activityReady, !input.activityClosed, input.activityStatus == .OK,
                  !input.requiresOwnedTargetDestruction, !page.boundPointerHeld,
                  try page.viewport() == presentationViewport else { throw AutomationError(code: .targetChanged) }
            try context.checkLive()
            controller.window.orderFront(nil)
            page.boundPresentation = .visibleObservation
            guard !Task.isCancelled, page.boundContext === context, page.epoch == presentationEpoch,
                  page.input === input, input.activityReady, !input.activityClosed,
                  input.activityStatus == .OK, !input.requiresOwnedTargetDestruction, !page.boundPointerHeld,
                  try page.viewport() == presentationViewport else { throw AutomationError(code: .targetChanged) }
            try context.checkLive()
            fputs("OBSERVE_DIAG phase=visibleObservation windowNumber=\(page.windowNumber) viewVersion=\(page.version) visible=true inactive=true key=false main=false\n", stderr)
            #endif
            return page
        } catch {
            context.beginClosing()
            _ = await page.destroy()
            throw error
        }
    }
    #endif

    private func checkedObjects() throws -> (BrowserSession, BrowserWindowController, BrowserWebView, NSWindow) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if let boundContext {
            try boundContext.checkLive()
            if registeredGeneration != nil {
                try boundContext.validateRegisteredTarget(identity)
                guard let current = webView?.url, current == registeredURL else { throw AutomationError(code: .targetChanged) }
                return try checkedOwnedObjects()
            }
            #if SAFARIER_INTERNAL_TEST_APP
            guard fixtureReady, let current = webView?.url, let delegate = boundNavigationDelegate,
                  navigating ? delegate.acceptsCurrentURL(current, previous: boundCommittedURL) : current == boundCommittedURL else {
                throw AutomationError(code: .targetChanged)
            }
            #else
            guard fixtureReady, webView?.url == boundFixture else { throw AutomationError(code: .targetChanged) }
            #endif
        }
        #endif
        return try checkedOwnedObjects()
    }

    private func checkedOwnedObjects() throws -> (BrowserSession, BrowserWindowController, BrowserWebView, NSWindow) {
        guard !invalidated, let session, let controller, let webView, let window,
              session.executionPolicy == .automationBackground,
              session.openControllers.contains(where: { $0 === controller }),
              controller.session === session, controller.webView === webView, controller.window === window,
              !controller.isShowingStartPage, webView.window === window, window.windowNumber == windowNumber,
              window.frame == frame, webView.bounds == bounds,
              window.backingScaleFactor == scale, webView.pageZoom == zoom,
              !NSApp.isActive, !window.isKeyWindow, !window.isMainWindow,
              window.ignoresMouseEvents, window.tabbingMode == .disallowed,
              presentationValid(window) else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            boundContext?.beginClosing()
            #endif
            throw AutomationError(code: .targetChanged)
        }
        return (session, controller, webView, window)
    }

    private func presentationValid(_ ownedWindow: NSWindow) -> Bool {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if let generation = registeredGeneration {
            guard let session, let controller, let webView, boundContext != nil,
                  window === ownedWindow, controller.window === ownedWindow,
                  controller.webView === webView, webView.window === ownedWindow else { return false }
            return session.registeredPresentationValid(controller: controller, generation: generation)
        }
        #endif
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP && !SAFARIER_WHEEL_OBSERVER_PROBE
        switch boundPresentation {
        case .hidden:
            return !ownedWindow.isVisible
        case .visibleObservation:
            return boundContext != nil && window === ownedWindow && NSApp.activationPolicy() == .accessory &&
                ownedWindow.isVisible && !ownedWindow.canBecomeKey && !ownedWindow.canBecomeMain
        }
        #else
        return !ownedWindow.isVisible
        #endif
    }

    private func viewport(version: UInt64) throws -> AutomationViewport {
        _ = try checkedObjects()
        return try viewportValue(version: version)
    }

    private func viewportValue(version: UInt64) throws -> AutomationViewport {
        let width = Double(bounds.width), height = Double(bounds.height), factor = Double(scale)
        guard width.isFinite, height.isFinite, factor.isFinite, width > 0, height > 0, factor > 0,
              width * factor <= Double(AutomationLimits.screenshotMaxEdge),
              height * factor <= Double(AutomationLimits.screenshotMaxEdge) else { throw AutomationError(code: .targetChanged) }
        let pixelWidth = Int((width * factor).rounded()), pixelHeight = Int((height * factor).rounded())
        let value = AutomationViewport(viewportWidthPoints: width, viewportHeightPoints: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scaleX: Double(pixelWidth) / width, scaleY: Double(pixelHeight) / height, pageZoom: Double(zoom), viewVersion: version)
        guard NativeInputPreflight.viewportValid(value) else { throw AutomationError(code: .targetChanged) }
        return value
    }

    func viewport() throws -> AutomationViewport { try viewport(version: version) }

    func readState(sessionState: AutomationSessionState, expectedViewport: AutomationViewport) throws -> AutomationState {
        guard try viewport() == expectedViewport else { throw AutomationError(code: .targetChanged) }
        guard let webView else { throw AutomationError(code: .targetChanged) }
        return AutomationState(target: identity, url: webView.url, loading: webView.isLoading, sessionState: sessionState, viewVersion: version)
    }

    func perform(_ action: AutomationAction, expectedViewport: AutomationViewport) async throws -> AutomationResult {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if registeredGeneration != nil {
            guard let boundContext else { throw AutomationError(code: .targetChanged) }
            try await boundContext.validate()
            try boundContext.validateRegisteredTarget(identity)
            switch action {
            case .navigate(let url):
                return try await navigateRegistered(url, expectedViewport: expectedViewport)
            case .navigateByInput(let trigger, let oldVersion):
                #if SAFARIER_INTERNAL_TEST_APP
                return try await navigateRegisteredByInput(trigger, oldVersion: oldVersion, expectedViewport: expectedViewport)
                #else
                throw AutomationError(code: .uiPolicyUnavailable)
                #endif
            #if SAFARIER_INTERNAL_TEST_APP
            case .insertText, .key:
                guard !boundPointerHeld, !navigating, let input, let webView else { throw AutomationError(code: .targetChanged) }
                return try await performInternalText(action, context: boundContext, input: input, webView: webView, viewport: expectedViewport)
            #endif
            default:
                break
            }
        } else
        if let boundContext {
            try await boundContext.validate()
            #if SAFARIER_INTERNAL_TEST_APP
            switch action {
            case .navigate, .navigateByInput:
                guard !boundPointerHeld else { throw AutomationError(code: .invalidPointerState) }
            case .move:
                break
            case .mouseDown:
                guard !boundPointerHeld else { throw AutomationError(code: .invalidPointerState) }
            case .mouseUp:
                guard boundPointerHeld else { throw AutomationError(code: .invalidPointerState) }
            case .click:
                guard !boundPointerHeld else { throw AutomationError(code: .invalidPointerState) }
            case .insertText, .key:
                guard !boundPointerHeld, !navigating, let input, let webView else { throw AutomationError(code: .targetChanged) }
                return try await performInternalText(action, context: boundContext, input: input, webView: webView, viewport: expectedViewport)
            default:
                throw AutomationError(code: .uiPolicyUnavailable)
            }
            #else
            switch action {
            case let .move(point, _):
                guard !boundPointerHeld || Self.isBoundFixtureDragPoint(point) else { throw AutomationError(code: .uiPolicyUnavailable) }
            case let .mouseDown(point, _):
                guard !boundPointerHeld else { throw AutomationError(code: .invalidPointerState) }
                guard Self.isBoundFixtureDragPoint(point) else { throw AutomationError(code: .uiPolicyUnavailable) }
            case let .mouseUp(point, _):
                guard boundPointerHeld else { throw AutomationError(code: .invalidPointerState) }
                guard Self.isBoundFixtureDragPoint(point) else { throw AutomationError(code: .uiPolicyUnavailable) }
            default:
                guard let operation = try BoundFixtureFormPolicy.validate(action, held: boundPointerHeld) else {
                    throw AutomationError(code: .uiPolicyUnavailable)
                }
                guard !navigating, try viewport() == expectedViewport, let input, let webView else {
                    throw AutomationError(code: .targetChanged)
                }
                return try await performBoundForm(action, operation: operation, context: boundContext,
                                                  input: input, webView: webView, expectedViewport: expectedViewport)
            }
            #endif
        }
        #endif
        if case let .navigate(url) = action {
            return try await navigate(url, expectedViewport: expectedViewport)
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        if case let .navigateByInput(trigger, oldVersion) = action {
            return try await navigate(nil, nativeTrigger: trigger, oldVersion: oldVersion, expectedViewport: expectedViewport)
        }
        #endif
        guard !navigating, try viewport() == expectedViewport, let input else { throw AutomationError(code: .targetChanged) }
        let currentEpoch = epoch
        let result = try await input.perform(action, viewVersion: expectedViewport.viewVersion)
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if boundContext != nil {
            switch action {
            case .mouseDown: boundPointerHeld = true
            case .mouseUp: boundPointerHeld = false
            default: break
            }
        }
        try await boundContext?.validate()
        #endif
        guard !Task.isCancelled, epoch == currentEpoch, try viewport() == expectedViewport else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
        return result
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    #if SAFARIER_INTERNAL_TEST_APP
    private func navigateRegisteredByInput(_ trigger: AutomationNavigationInput, oldVersion: UInt64,
                                           expectedViewport: AutomationViewport) async throws -> AutomationResult {
        var traceEpoch = epoch
        do {
        guard let context = boundContext, let source = registeredURL, let webView, let window, let oldInput = input,
              registeredGeneration != nil, !navigating, !boundPointerHeld, oldVersion == version, version < UInt64.max,
              expectedViewport.viewVersion == version + 1, try viewport(version: expectedViewport.viewVersion) == expectedViewport,
              webView.url == source, oldInput.activityReady, !oldInput.activityClosed else { throw AutomationError(code: .targetChanged) }
        if case let .click(point) = trigger, !(try viewport()).contains(point) { throw AutomationError(code: .outOfBounds) }
        if case .enter = trigger {
            registeredNativeTrace("eligibility.before", epoch: epoch)
            try await requireInternalTextEligibility(context: context, input: oldInput, webView: webView,
                viewport: try viewport(), epoch: epoch, deadline: ContinuousClock.now + .seconds(AutomationLimits.actionSeconds))
            registeredNativeTrace("eligibility.after", epoch: epoch)
        }
        registeredNativeTrace("identity.before", epoch: epoch)
        try await context.validate()
        try context.validateRegisteredTarget(identity)
        registeredNativeTrace("identity.after", epoch: epoch)
        guard !Task.isCancelled, try viewport() == viewportValue(version: version), webView.url == source else { throw AutomationError(code: .targetChanged) }
        navigating = true; epoch &+= 1
        let generation = epoch, deadline = ContinuousClock.now + .seconds(AutomationLimits.navigationSeconds)
        traceEpoch = generation
        let permit = RegisteredNativePermit(source: source, epoch: generation)
        registeredNativePermit = permit; navigationOutcome = nil
        registeredNativeTrace("permit_created", epoch: generation)
        do {
            let inputDeadline = min(deadline, ContinuousClock.now + .seconds(AutomationLimits.actionSeconds))
            func sameDocumentStateValid() -> Bool {
                guard !Task.isCancelled, !invalidated, navigating, epoch == generation,
                      registeredNativePermit === permit, self.input === oldInput, self.webView === webView,
                      ContinuousClock.now < inputDeadline,
                      (try? context.checkLive()) != nil, (try? context.validateRegisteredTarget(identity)) != nil,
                      (try? checkedOwnedObjects()) != nil,
                      (try? viewportValue(version: expectedViewport.viewVersion)) == expectedViewport else { return false }
                return webView.url == (permit.sameDocumentURL ?? source)
            }
            guard BoundFixtureNavigationDelegate.sameDocumentABI else { throw AutomationError(code: .targetChanged) }
            registeredNativeTrace("source_snapshot.before", epoch: generation)
            permit.sourceSnapshot = try await Self.registeredFrameSnapshot(view: webView, source: source, deadline: inputDeadline, valid: sameDocumentStateValid)
            registeredNativeTrace("source_snapshot.after", epoch: generation)
            guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged) }
            try await context.validate()
            guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged) }
            let action: AutomationAction
            switch trigger {
            case .enter: action = .key(name: .enter, shift: false)
            case let .click(point): action = .click(point: point, viewVersion: oldVersion, count: 1)
            }
            permit.watchInput(until: inputDeadline) { [weak self, weak permit] in
                guard let self, let permit, self.registeredNativePermit === permit else { return }
                registeredNativeTrace("watchdog.expired", epoch: permit.epoch)
                self.block(.unknown, reason: "registered.watchdog")
            }
            defer { permit.cancelInputWatchdog() }
            registeredNativeTrace("native.perform.before", epoch: generation)
            _ = try await oldInput.perform(action, viewVersion: oldVersion)
            guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            try await context.validate()
            guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            registeredNativeTrace("native.perform.after", epoch: generation)
            registeredNativeTrace("action_wait.before", epoch: generation)
            while permit.action == nil && !permit.sameDocumentReady {
                guard !Task.isCancelled, !invalidated, epoch == generation, ContinuousClock.now < inputDeadline else {
                    throw AutomationError(code: .timeout, sideEffects: .possible)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
                guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            }
            registeredNativeTrace("action_wait.after", epoch: generation)
            if permit.sameDocumentReady {
                guard sameDocumentStateValid(), let baseline = permit.sourceSnapshot else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                registeredNativeTrace("same_document.close.before", epoch: generation)
                oldInput.closeActivity()
                try await oldInput.waitUntilClosed()
                registeredNativeTrace("same_document.close.after", epoch: generation)
                guard sameDocumentStateValid(), oldInput.buttonMask == 0, oldInput.activityStatus == .OK,
                      !oldInput.requiresOwnedTargetDestruction else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                var finalURL: URL?
                var acceptedSequence: UInt64 = 0
                while finalURL == nil {
                    guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                    if !permit.sameDocumentReady {
                        try await Task.sleep(nanoseconds: 10_000_000)
                        guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                        continue
                    }
                    guard let candidate = permit.sameDocumentURL else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                    let sequence = permit.sameDocumentSequence
                    do {
                        let snapshot = try await Self.registeredFrameSnapshot(view: webView, source: candidate, deadline: inputDeadline, valid: sameDocumentStateValid)
                        guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                        try await context.validate()
                        guard sameDocumentStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                        // A newer callback during the asynchronous frame query supersedes this snapshot.
                        if sequence != permit.sameDocumentSequence { continue }
                        guard permit.acceptsSameDocument(snapshot: snapshot, baseline: baseline, sequence: sequence,
                            epoch: epoch, current: webView.url, deadline: inputDeadline) else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                        finalURL = candidate; acceptedSequence = sequence
                        registeredNativeTrace("same_document.snapshot.accepted", epoch: generation)
                    } catch {
                        if sameDocumentStateValid(), sequence != permit.sameDocumentSequence { continue }
                        throw error
                    }
                }
                guard let finalURL else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                let next = try NativePageInput.prepareRegistered(webView: webView, window: window, context: context,
                                                                  target: identity, viewVersion: expectedViewport.viewVersion)
                configureRegisteredInput(next)
                func nextStateValid() -> Bool {
                    !Task.isCancelled && !invalidated && navigating && epoch == generation &&
                    registeredNativePermit === permit && input === next && self.webView === webView &&
                    permit.sameDocumentSequence == acceptedSequence && permit.sameDocumentURL == finalURL &&
                    webView.url == finalURL && ContinuousClock.now < inputDeadline &&
                    (try? context.checkLive()) != nil && (try? context.validateRegisteredTarget(identity)) != nil &&
                    (try? checkedOwnedObjects()) != nil &&
                    (try? viewportValue(version: expectedViewport.viewVersion)) == expectedViewport
                }
                input = next; try next.startRegistered(); try await next.waitUntilReady()
                guard nextStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                registeredNativeTrace("same_document.input.ready", epoch: generation)
                try await context.validate(); try context.validateRegisteredTarget(identity)
                guard nextStateValid() else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                permit.releaseForNavigation(); registeredNativePermit = nil; registeredURL = finalURL
                version = expectedViewport.viewVersion; navigating = false
                guard try viewport() == expectedViewport else { throw AutomationError(code: .targetChanged) }
                registeredNativeTrace("same_document.finished", epoch: generation)
                return .navigationFinished(viewVersion: version)
            }
            guard let request = permit.action, let target = request.request.url, permit.decision != nil,
                  let delegate = boundNavigationDelegate else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            registeredNativeTrace("input.close.before", epoch: generation)
            oldInput.closeActivity()
            try await oldInput.waitUntilClosed()
            registeredNativeTrace("input.close.after", epoch: generation)
            guard !Task.isCancelled, !invalidated, epoch == generation, oldInput.buttonMask == 0,
                  oldInput.activityStatus == .OK, !oldInput.requiresOwnedTargetDestruction else {
                throw AutomationError(code: .targetChanged, sideEffects: .possible)
            }
            try await context.validate(); try context.validateRegisteredTarget(identity)
            try delegate.beginNativeNavigation(target)
            registeredNavigationURL = target
            registeredNativeTrace("policy.release.before", epoch: generation)
            permit.releaseForNavigation()
            registeredNativeTrace("policy.release.after", epoch: generation)
            registeredNativeTrace("navigation.wait.before", epoch: generation)
            while navigationOutcome == nil {
                guard !Task.isCancelled, !invalidated, epoch == generation, ContinuousClock.now < deadline else {
                    throw AutomationError(code: .timeout, sideEffects: .possible)
                }
                try await context.validate(); try context.validateRegisteredTarget(identity)
                _ = try checkedOwnedObjects()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            registeredNativeTrace("navigation.wait.after", epoch: generation)
            guard case .finished? = navigationOutcome, let actual = navigation, let finalURL = webView.url,
                  delegate.canFinishExplicitNavigation(finalURL), correlation.finish(actual, epoch: navigationEpoch),
                  delegate.finishExplicitNavigation(finalURL), !invalidated, epoch == generation else {
                throw AutomationError(code: .targetChanged, sideEffects: .possible)
            }
            registeredURL = finalURL; registeredNavigationURL = nil; registeredNativePermit = nil
            navigation = nil; navigationOutcome = nil
            let next = try NativePageInput.prepareRegistered(webView: webView, window: window, context: context,
                                                              target: identity, viewVersion: expectedViewport.viewVersion)
            configureRegisteredInput(next)
            input = next; try next.startRegistered(); try await next.waitUntilReady()
            try await context.validate(); try context.validateRegisteredTarget(identity)
            guard !Task.isCancelled, !invalidated, epoch == generation else { throw AutomationError(code: .targetChanged) }
            version = expectedViewport.viewVersion; navigating = false
            guard try viewport() == expectedViewport else { throw AutomationError(code: .targetChanged) }
            return .navigationFinished(viewVersion: version)
        } catch {
            permit.decide(.cancel); registeredNativePermit = nil; block(.unknown, reason: "registered.catch"); throw error
        }
        } catch {
            registeredNativeTrace("catch", epoch: traceEpoch, result: registeredNativeError(error))
            throw error
        }
    }
    #endif
    private func navigateRegistered(_ url: URL, expectedViewport: AutomationViewport) async throws -> AutomationResult {
        #if SAFARIER_INTERNAL_TEST_APP
        guard let context = boundContext, registeredGeneration != nil, !navigating, !boundPointerHeld,
              let oldInput = input, let webView, let window, version < UInt64.max,
              expectedViewport.viewVersion == version + 1,
              try viewport(version: expectedViewport.viewVersion) == expectedViewport else {
            throw AutomationError(code: .targetChanged)
        }
        try context.validateRegisteredTarget(identity)
        try await context.validate()
        guard !Task.isCancelled, try viewport(version: expectedViewport.viewVersion) == expectedViewport else {
            throw AutomationError(code: .targetChanged)
        }
        navigating = true
        epoch &+= 1
        let currentEpoch = epoch
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.navigationSeconds)
        do {
            oldInput.closeActivity()
            try await oldInput.waitUntilClosed()
            guard !oldInput.requiresOwnedTargetDestruction, oldInput.buttonMask == 0,
                  oldInput.activityStatus == .OK, !Task.isCancelled else { throw AutomationError(code: .targetChanged) }
            try await context.validate()
            try context.validateRegisteredTarget(identity)
            _ = try checkedOwnedObjects()
            guard !Task.isCancelled, epoch == currentEpoch, !invalidated else { throw AutomationError(code: .targetChanged) }
            guard let delegate = boundNavigationDelegate else { throw AutomationError(code: .targetChanged) }
            try delegate.beginExplicitNavigation(url)
            registeredNavigationURL = url
            navigationOutcome = nil
            guard let first = webView.load(URLRequest(url: url)) else {
                throw AutomationError(code: .backendUnavailable, sideEffects: .possible)
            }
            navigation = first
            navigationEpoch = correlation.begin(first)
            var retries = 0
            while true {
                while navigationOutcome == nil {
                    guard !Task.isCancelled, !invalidated, epoch == currentEpoch, ContinuousClock.now < deadline else {
                        throw AutomationError(code: .timeout, sideEffects: .possible)
                    }
                    try await context.validate()
                    try context.validateRegisteredTarget(identity)
                    _ = try checkedOwnedObjects()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard case let .failed(error, provisional)? = navigationOutcome else { break }
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                guard let delay = NavigationRetryPolicy.delay(error: error, url: url, provisional: provisional,
                    knownGET: delegate.canRetryOriginalGET(url), retries: retries, remaining: seconds,
                    cancelled: Task.isCancelled), let parent = navigation else { break }
                let failure = error as NSError
                fputs("NAV_DIAG phase=registeredRetryScheduled attempt=\(retries + 2) domain=\(failure.domain) code=\(failure.code)\n", stderr)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try await context.validate()
                try context.validateRegisteredTarget(identity)
                _ = try checkedOwnedObjects()
                guard !Task.isCancelled, !invalidated, epoch == currentEpoch, ContinuousClock.now < deadline,
                      correlation.canReplaceFailedProvisional(parent, epoch: navigationEpoch),
                      case .failed(_, true)? = navigationOutcome, delegate.prepareRetry(url) else {
                    throw AutomationError(code: .targetChanged, sideEffects: .possible)
                }
                guard let child = webView.load(URLRequest(url: url)),
                      let nextEpoch = correlation.replaceFailedProvisional(parent, with: child, epoch: navigationEpoch) else {
                    throw AutomationError(code: .backendUnavailable, sideEffects: .possible)
                }
                navigation = child; navigationEpoch = nextEpoch; navigationOutcome = nil; retries += 1
                fputs("NAV_DIAG phase=registeredRetryStarted attempt=\(retries + 1) domain=\(failure.domain) code=\(failure.code)\n", stderr)
            }
            guard case .finished? = navigationOutcome, let actual = navigation, let finalURL = webView.url,
                  delegate.canFinishExplicitNavigation(finalURL),
                  correlation.finish(actual, epoch: navigationEpoch), !invalidated,
                  epoch == currentEpoch, ContinuousClock.now < deadline else {
                throw AutomationError(code: .targetChanged, sideEffects: .possible)
            }
            guard delegate.finishExplicitNavigation(finalURL) else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            registeredURL = finalURL
            registeredNavigationURL = nil
            navigation = nil
            navigationOutcome = nil
            let next = try NativePageInput.prepareRegistered(webView: webView, window: window, context: context,
                                                              target: identity, viewVersion: expectedViewport.viewVersion)
            configureRegisteredInput(next)
            input = next
            try next.startRegistered()
            try await next.waitUntilReady()
            try await context.validate()
            try context.validateRegisteredTarget(identity)
            guard !Task.isCancelled, !invalidated, epoch == currentEpoch else { throw AutomationError(code: .targetChanged) }
            version = expectedViewport.viewVersion
            navigating = false
            guard try viewport() == expectedViewport else { throw AutomationError(code: .targetChanged) }
            return .navigationFinished(viewVersion: version)
        } catch {
            block(.unknown)
            throw error
        }
        #else
        throw AutomationError(code: .uiPolicyUnavailable)
        #endif
    }
    #endif

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    /// Only redacted fixed-fixture observations cross the JS boundary.
    private struct FormObservation: Decodable {
        let hit: Bool, textActive: Bool
        let valueCode: Int, start: Int, end: Int, buttonClicks: Int
        let buttonTrusted: Int, focusTrusted: Int, inputTrusted: Int, downTrusted: Int, upTrusted: Int
    }

    @MainActor private final class FormObservationWaiter {
        private var result: Result<String, Error>?
        private var continuation: CheckedContinuation<String, Error>?
        var timer: Task<Void, Never>?
        func install(_ value: CheckedContinuation<String, Error>) {
            if let result { value.resume(with: result) } else { continuation = value }
        }
        func finish(_ value: Result<String, Error>) {
            guard result == nil else { return }
            result = value
            timer?.cancel(); timer = nil
            let current = continuation; continuation = nil
            current?.resume(with: value)
        }
    }

    private func checkFormLocal(context: RunnerBinderContext, input expectedInput: NativePageInput,
                                webView expectedWebView: BrowserWebView, viewport expected: AutomationViewport,
                                epoch expectedEpoch: UInt64, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline, !invalidated, !navigating, epoch == expectedEpoch,
              boundContext === context, input === expectedInput, webView === expectedWebView,
              try viewport() == expected else { throw AutomationError(code: .targetChanged) }
    }

    private func validateFormContext(context: RunnerBinderContext, input: NativePageInput,
                                     webView: BrowserWebView, viewport: AutomationViewport,
                                     epoch: UInt64, deadline: ContinuousClock.Instant) async throws {
        try checkFormLocal(context: context, input: input, webView: webView, viewport: viewport, epoch: epoch, deadline: deadline)
        try await context.validate()
        try checkFormLocal(context: context, input: input, webView: webView, viewport: viewport, epoch: epoch, deadline: deadline)
    }

    private func requireTextResponder(_ expectedWebView: BrowserWebView) throws {
        guard let window, let target = window.firstResponder as? NSView,
              target.isDescendant(of: expectedWebView), target is NSTextInputClient else {
            throw AutomationError(code: .targetChanged)
        }
    }

    #if SAFARIER_INTERNAL_TEST_APP
    private func requireInternalTextEligibility(context: RunnerBinderContext, input: NativePageInput,
                                                webView: BrowserWebView, viewport: AutomationViewport,
                                                epoch currentEpoch: UInt64, deadline: ContinuousClock.Instant) async throws {
        try await validateFormContext(context: context, input: input, webView: webView, viewport: viewport, epoch: currentEpoch, deadline: deadline)
        try requireTextResponder(webView)
        let waiter = FormObservationWaiter()
        let result: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                if Task.isCancelled { waiter.finish(.failure(AutomationError(code: .cancelled))); return }
                waiter.timer = Task { @MainActor [weak waiter] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    waiter?.finish(.failure(AutomationError(code: .timeout)))
                }
                webView.callAsyncJavaScript("""
                    const e = document.activeElement;
                    return !!e && !e.disabled && !e.readOnly &&
                      (e instanceof HTMLTextAreaElement ||
                       (e instanceof HTMLInputElement && ['text', 'search'].includes(e.type)));
                    """, arguments: [:], in: nil, in: .world(name: "SafarierInputPolicy"), completionHandler: { value in
                    switch value {
                    case .success(let allowed): waiter.finish(.success((allowed as? Bool) == true ? "allowed" : "denied"))
                    case .failure: waiter.finish(.failure(AutomationError(code: .targetChanged)))
                    }
                })
            }
        }, onCancel: { Task { @MainActor in waiter.finish(.failure(AutomationError(code: .cancelled))) } })
        guard result == "allowed" else { throw AutomationError(code: .uiPolicyUnavailable) }
        try await validateFormContext(context: context, input: input, webView: webView, viewport: viewport, epoch: currentEpoch, deadline: deadline)
        try requireTextResponder(webView)
    }

    private func performInternalText(_ action: AutomationAction, context: RunnerBinderContext,
                                     input: NativePageInput, webView: BrowserWebView,
                                     viewport: AutomationViewport) async throws -> AutomationResult {
        if case let .insertText(text) = action,
           text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw AutomationError(code: .uiPolicyUnavailable)
        }
        if case let .key(name, shift) = action {
            guard !shift, [.backspace, .delete, .left, .right, .home, .end].contains(name) else {
                throw AutomationError(code: .uiPolicyUnavailable)
            }
        }
        let currentEpoch = epoch
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.actionSeconds)
        try await requireInternalTextEligibility(context: context, input: input, webView: webView, viewport: viewport,
                                                 epoch: currentEpoch, deadline: deadline)
        let delivered = try await input.perform(action, viewVersion: viewport.viewVersion)
        do {
            try await validateFormContext(context: context, input: input, webView: webView, viewport: viewport, epoch: currentEpoch, deadline: deadline)
        } catch {
            context.beginClosing()
            block(.unknown)
            throw AutomationError(code: .targetChanged, sideEffects: .possible)
        }
        return delivered
    }
    #endif

    private func readFormObservation(webView: BrowserWebView, point: ViewportPoint, button: Bool,
                                     deadline: ContinuousClock.Instant) async throws -> FormObservation {
        // Coordinates have already passed the fixed-rectangle policy; no caller text is interpolated.
        let target = button ? "button" : "text"
        let script = """
        (() => {
          const t = document.getElementById('text'), target = document.getElementById('\(target)');
          if (!t || !target || typeof window.probeSnapshot !== 'function') return null;
          const s = window.probeSnapshot();
          if (!s || !Array.isArray(s.records)) return null;
          const count = (type, id) => s.records.filter(e => e.type === type && e.id === id && e.trusted === true).length;
          const valueCode = ['', 'native-123', 'native-12', 'native-12中文'].indexOf(t.value);
          return JSON.stringify({hit:document.elementFromPoint(\(point.x),\(point.y)) === target,
            textActive:document.activeElement === t, valueCode, start:t.selectionStart, end:t.selectionEnd,
            buttonClicks:s.clicks, buttonTrusted:count('click','button'), focusTrusted:count('focus','text'),
            inputTrusted:count('input','text'), downTrusted:count('keydown','text'), upTrusted:count('keyup','text')});
        })()
        """
        let waiter = FormObservationWaiter()
        let json: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                if Task.isCancelled { waiter.finish(.failure(AutomationError(code: .cancelled))); return }
                waiter.timer = Task { @MainActor [weak waiter] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    waiter?.finish(.failure(AutomationError(code: .timeout)))
                }
                webView.evaluateJavaScript(script) { value, error in
                    guard error == nil, let json = value as? String else {
                        waiter.finish(.failure(AutomationError(code: .targetChanged))); return
                    }
                    waiter.finish(.success(json))
                }
            }
        }, onCancel: {
            Task { @MainActor in waiter.finish(.failure(AutomationError(code: .cancelled))) }
        })
        guard let data = json.data(using: .utf8), let observation = try? JSONDecoder().decode(FormObservation.self, from: data) else {
            throw AutomationError(code: .targetChanged)
        }
        return observation
    }

    private func performBoundForm(_ action: AutomationAction, operation: BoundFixtureFormPolicy.FormOperation,
                                  context: RunnerBinderContext, input: NativePageInput, webView: BrowserWebView,
                                  expectedViewport: AutomationViewport) async throws -> AutomationResult {
        let currentEpoch = epoch
        // This local cap can only shorten the existing controller action deadline;
        // the controller continues to cancel its worker at the original deadline.
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.actionSeconds)
        let point: ViewportPoint
        if case let .click(value, _, _) = action { point = value } else { point = ViewportPoint(x: 100, y: 160) }
        let button = operation == .clickButton
        let needsTextResponder = operation != .clickButton && operation != .clickText
        let diagnosticOperation: String
        switch operation {
        case .clickButton: diagnosticOperation = "clickButton"
        case .clickText: diagnosticOperation = "clickText"
        case .insertASCII: diagnosticOperation = "insertASCII"
        case .backspace: diagnosticOperation = "backspace"
        case .left: diagnosticOperation = "left"
        case .right: diagnosticOperation = "right"
        case .insertChinese: diagnosticOperation = "insertChinese"
        }
        var diagnosticPhase = "sequence"
        do {
            guard boundFormNext == operation else { throw AutomationError(code: .uiPolicyUnavailable) }
            diagnosticPhase = "pre-context"
            try await validateFormContext(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
            try checkFormLocal(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
            diagnosticPhase = "pre-read"
            let before = try await readFormObservation(webView: webView, point: point, button: button, deadline: deadline)
            try checkFormLocal(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
            try await validateFormContext(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
            diagnosticPhase = "precondition"
            let beforeValue: Int, beforeSelection: Int
            switch operation {
            case .clickButton, .clickText, .insertASCII: beforeValue = 0; beforeSelection = 0
            case .backspace: beforeValue = 1; beforeSelection = 10
            case .left, .insertChinese: beforeValue = 2; beforeSelection = 9
            case .right: beforeValue = 2; beforeSelection = 8
            }
            guard before.hit, before.valueCode == beforeValue, before.start == beforeSelection, before.end == beforeSelection,
                  !needsTextResponder || before.textActive else { throw AutomationError(code: .targetChanged) }
            if needsTextResponder { try requireTextResponder(webView) }
            // Preserve the original Core check immediately before the actual input.
            diagnosticPhase = "native"
            try await validateFormContext(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
            if needsTextResponder { try requireTextResponder(webView) }
            let result = try await input.perform(action, viewVersion: expectedViewport.viewVersion)
            diagnosticPhase = "post-read"
            try checkFormLocal(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
            try await validateFormContext(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
            if needsTextResponder { try requireTextResponder(webView) }
            while true {
                diagnosticPhase = "post-read"
                let after = try await readFormObservation(webView: webView, point: point, button: button, deadline: deadline)
                try checkFormLocal(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
                try await validateFormContext(context: context, input: input, webView: webView, viewport: expectedViewport, epoch: currentEpoch, deadline: deadline)
                diagnosticPhase = "effect"
                guard after.hit else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                let matched: Bool
                switch operation {
                case .clickButton:
                    matched = after.buttonClicks == before.buttonClicks + 1 && after.buttonTrusted > before.buttonTrusted
                case .clickText:
                    matched = after.textActive && after.valueCode == 0 && after.start == 0 && after.end == 0 && after.focusTrusted > before.focusTrusted
                case .insertASCII:
                    matched = after.textActive && after.valueCode == 1 && after.start == 10 && after.end == 10 && after.inputTrusted > before.inputTrusted
                case .backspace:
                    matched = after.textActive && after.valueCode == 2 && after.start == 9 && after.end == 9 && after.inputTrusted > before.inputTrusted && after.downTrusted > before.downTrusted && after.upTrusted > before.upTrusted
                case .left:
                    matched = after.textActive && after.valueCode == 2 && after.start == 8 && after.end == 8 && after.downTrusted > before.downTrusted && after.upTrusted > before.upTrusted
                case .right:
                    matched = after.textActive && after.valueCode == 2 && after.start == 9 && after.end == 9 && after.downTrusted > before.downTrusted && after.upTrusted > before.upTrusted
                case .insertChinese:
                    matched = after.textActive && after.valueCode == 3 && after.start == 11 && after.end == 11 && after.inputTrusted > before.inputTrusted
                }
                if matched {
                    if operation != .clickButton { try requireTextResponder(webView) }
                    switch operation {
                    case .clickButton: boundFormNext = .clickText
                    case .clickText: boundFormNext = .insertASCII
                    case .insertASCII: boundFormNext = .backspace
                    case .backspace: boundFormNext = .left
                    case .left: boundFormNext = .right
                    case .right: boundFormNext = .insertChinese
                    case .insertChinese: boundFormNext = nil
                    }
                    fputs("FORM_DIAG phase=effect op=\(diagnosticOperation) valueCode=\(after.valueCode) selectionStart=\(after.start) selectionEnd=\(after.end) textActive=\(after.textActive) buttonTrusted=\(after.buttonTrusted) focusTrusted=\(after.focusTrusted) inputTrusted=\(after.inputTrusted) downTrusted=\(after.downTrusted) upTrusted=\(after.upTrusted)\n", stderr)
                    return result
                }
            }
        } catch {
            let code = (error as? AutomationError)?.code.rawValue ?? "unknown"
            fputs("FORM_DIAG phase=\(diagnosticPhase) op=\(diagnosticOperation) code=\(code)\n", stderr)
            // Never retry an input after an uncertain observation or stale target.
            context.beginClosing()
            block(.unknown)
            throw error
        }
    }
    #endif

    func captureSnapshot(expectedViewport: AutomationViewport) async throws -> RunnerAutomationPageSnapshot {
        guard !navigating, try viewport() == expectedViewport, let input else { throw AutomationError(code: .targetChanged) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        try await boundContext?.validate()
        #endif
        let currentEpoch = epoch
        let snapshot = try await input.captureSnapshot(viewVersion: expectedViewport.viewVersion)
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        try await boundContext?.validate()
        #endif
        guard !Task.isCancelled, epoch == currentEpoch, try viewport() == expectedViewport, snapshot.viewport == expectedViewport else { throw AutomationError(code: .targetChanged) }
        return RunnerAutomationPageSnapshot(png: snapshot.png, viewport: snapshot.viewport)
    }

    private func navigate(_ url: URL?, nativeTrigger: AutomationNavigationInput? = nil, oldVersion: UInt64? = nil,
                          expectedViewport: AutomationViewport) async throws -> AutomationResult {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticPhase = "closeActivity"
        #endif
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.navigationSeconds)
        guard !navigating, version < UInt64.max, expectedViewport.viewVersion == version + 1,
              try viewport(version: expectedViewport.viewVersion) == expectedViewport,
              let webView, let window else { throw AutomationError(code: .targetChanged) }
        guard !Task.isCancelled else { throw AutomationError(code: .cancelled) }
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        let sourceBefore = lastFinishedSourceProof
        if let nativeTrigger {
            guard url == nil, oldVersion == version, !boundPointerHeld, let context = boundContext,
                  let sourceBefore, sourceBefore.pageEpoch == epoch, sourceBefore.url == boundCommittedURL,
                  webView.url == sourceBefore.url, let oldInput = input, oldInput.activityReady,
                  !oldInput.activityClosed, oldInput.activityStatus == .OK, !oldInput.requiresOwnedTargetDestruction,
                  try viewport() == viewportValue(version: version) else { throw AutomationError(code: .targetChanged) }
            if case let .click(point) = nativeTrigger {
                guard (try viewport()).contains(point) else { throw AutomationError(code: .outOfBounds) }
            }
            if case .enter = nativeTrigger {
                let eligibilityDeadline = min(deadline, ContinuousClock.now + .seconds(AutomationLimits.actionSeconds))
                try await requireInternalTextEligibility(context: context, input: oldInput, webView: webView,
                                                         viewport: try viewport(), epoch: epoch, deadline: eligibilityDeadline)
            }
            guard !Task.isCancelled, !navigating, !invalidated, oldVersion == version,
                  sourceBefore.pageEpoch == epoch, sourceBefore.url == boundCommittedURL, webView.url == sourceBefore.url,
                  input === oldInput, oldInput.activityReady, !oldInput.activityClosed, !boundPointerHeld,
                  try viewport(version: expectedViewport.viewVersion) == expectedViewport else { throw AutomationError(code: .targetChanged) }
        } else { guard url != nil else { throw AutomationError(code: .invalidRequest) } }
        #else
        guard url != nil, nativeTrigger == nil else { throw AutomationError(code: .invalidRequest) }
        #endif
        navigating = true
        epoch &+= 1
        let currentEpoch = epoch
        do {
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let boundContext { try await boundContext.validate() }
            #endif
            guard let oldInput = input else { throw AutomationError(code: .targetChanged) }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let nativeTrigger, let sourceBefore, let oldVersion, let boundContext {
                let permit = NativeNavigationPermit(source: sourceBefore, commandEpoch: currentEpoch, oldInput: oldInput,
                                                    oldVersion: oldVersion, expectedViewport: expectedViewport, deadline: deadline)
                nativeNavigationPermit = permit
                navigationOutcome = nil
                continuationDeadline = deadline; continuationViewport = expectedViewport
                finishedDocumentURL = nil; committedDocumentURL = nil; lastFinishedSourceProof = nil
                let deliveryDeadline = min(deadline, ContinuousClock.now + .seconds(AutomationLimits.actionSeconds))
                let timeout = Task { @MainActor [weak self, weak permit] in
                    do { try await Task.sleep(until: deliveryDeadline, clock: .continuous) } catch { return }
                    guard let self, let permit, self.nativeNavigationPermit === permit else { return }
                    self.block(.unknown)
                }
                defer { timeout.cancel() }
                let nativeAction: AutomationAction
                switch nativeTrigger {
                case .enter: nativeAction = .key(name: .enter, shift: false)
                case .click(let point): nativeAction = .click(point: point, viewVersion: oldVersion, count: 1)
                }
                fputs("NAV_DIAG phase=nativeDispatch\n", stderr)
                _ = try await withTaskCancellationHandler(operation: {
                    try await oldInput.perform(nativeAction, viewVersion: oldVersion)
                }, onCancel: { [weak self] in
                    Task { @MainActor [weak self] in self?.block(.unknown) }
                })
                guard ContinuousClock.now < deliveryDeadline, !invalidated, nativeNavigationPermit === permit else { throw AutomationError(code: .timeout, sideEffects: .possible) }
                timeout.cancel()
                fputs("NAV_DIAG phase=nativeDeliveryComplete\n", stderr)
                while permit.action == nil {
                    guard !Task.isCancelled, !invalidated, epoch == currentEpoch, ContinuousClock.now < deadline,
                          nativeNavigationPermit === permit else { throw AutomationError(code: .timeout, sideEffects: .possible) }
                    try await boundContext.validate()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                oldInput.closeActivity()
                try await oldInput.waitUntilClosed()
                guard !Task.isCancelled, oldInput.activityClosed, oldInput.activityStatus == .OK,
                      !oldInput.requiresOwnedTargetDestruction, nativeNavigationPermit === permit else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                fputs("NAV_DIAG phase=nativeActivityClosed\n", stderr)
                try await boundContext.validate()
                guard let action = permit.action, permit.decision != nil,
                      nativePermitValid(permit, action: action, requiresClosed: true),
                      let target = action.request.url, let boundNavigationDelegate else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                try boundNavigationDelegate.beginNativeNavigation(target)
                permit.released = true
                fputs("NAV_DIAG phase=nativePolicyAllowed\n", stderr)
                permit.decide(.allow)
            }
            #endif
            if nativeTrigger == nil {
            oldInput.closeActivity()
            guard !oldInput.requiresOwnedTargetDestruction, oldInput.activityStatus == .OK else {
                throw AutomationError(code: .targetChanged)
            }
            try await oldInput.waitUntilClosed()
            guard !Task.isCancelled, epoch == currentEpoch, !invalidated,
                  !oldInput.requiresOwnedTargetDestruction, oldInput.activityStatus == .OK,
                  try viewport(version: expectedViewport.viewVersion) == expectedViewport else {
                throw AutomationError(code: .targetChanged)
            }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            // Preserve the confirmed closed lease for cleanup if navigation fails
            // before a replacement activity is attempted.
            if boundContext == nil { input = nil }
            #else
            input = nil
            #endif
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "prepareNavigation"
            #endif
            navigationOutcome = nil
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            continuationDeadline = deadline
            continuationViewport = expectedViewport
            finishedDocumentURL = nil
            committedDocumentURL = nil
            lastFinishedSourceProof = nil
            #endif
            guard ContinuousClock.now < deadline else { throw AutomationError(code: .timeout) }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let boundContext {
                try await boundContext.validate()
                guard !Task.isCancelled, epoch == currentEpoch, !invalidated,
                      let boundNavigationDelegate else { throw AutomationError(code: .targetChanged) }
                guard let url else { throw AutomationError(code: .invalidRequest) }
                try boundNavigationDelegate.beginExplicitNavigation(url)
            }
            #endif
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "load"
            #endif
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            guard knownNativeNavigations.count < AutomationLimits.replayEntries else { throw AutomationError(code: .targetChanged) }
            #endif
            guard let url, let navigation = webView.load(URLRequest(url: url)) else {
                throw AutomationError(code: .backendUnavailable, sideEffects: .possible)
            }
            self.navigation = navigation
            navigationEpoch = correlation.begin(navigation)
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            guard knownNativeNavigations.count < AutomationLimits.replayEntries,
                  !knownNativeNavigations.contains(where: { $0 === navigation }) else { throw AutomationError(code: .targetChanged) }
            knownNativeNavigations.append(navigation)
            #endif
            }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "waitNavigation"
            #endif
            while true {
                guard !Task.isCancelled, epoch == currentEpoch, !invalidated else { throw AutomationError(code: .targetChanged) }
                #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
                if let boundContext { try await boundContext.validate() }
                #endif
                _ = try checkedObjects()
                guard ContinuousClock.now < deadline else { throw AutomationError(code: .timeout, sideEffects: .possible) }
                if case .failed? = navigationOutcome { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
                let hasPending = correlation.hasPendingContinuation || pendingContinuation != nil || nativeNavigationPermit != nil
                #else
                let hasPending = false
                #endif
                if case .finished? = navigationOutcome, !hasPending { break }
                do { try await Task.sleep(nanoseconds: 10_000_000) }
                catch { throw AutomationError(code: .cancelled, sideEffects: .possible) }
            }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "finishNavigation"
            #endif
            guard !Task.isCancelled, epoch == currentEpoch, !invalidated,
                  let latestNavigation = self.navigation, case .finished? = navigationOutcome,
                  try viewport(version: expectedViewport.viewVersion) == expectedViewport,
                  ContinuousClock.now < deadline else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            // The loop's last context validation may have allowed a continuation to
            // start; all checks and the finish below run without another suspension.
            guard !correlation.hasPendingContinuation, pendingContinuation == nil else {
                throw AutomationError(code: .targetChanged, sideEffects: .possible)
            }
            let newInput: NativePageInput
            if let boundContext {
                guard input === oldInput, oldInput.activityClosed, oldInput.activityStatus == .OK,
                      !oldInput.requiresOwnedTargetDestruction, !boundPointerHeld,
                      let finalURL = webView.url, finishedDocumentURL == finalURL,
                      let boundNavigationDelegate,
                      boundNavigationDelegate.canFinishExplicitNavigation(finalURL),
                      correlation.finish(latestNavigation, epoch: navigationEpoch),
                      boundNavigationDelegate.finishExplicitNavigation(finalURL) else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                boundCommittedURL = finalURL
                self.navigation = nil
                navigationOutcome = nil
                continuationDeadline = nil
                continuationViewport = nil
                input = nil
                newInput = try NativePageInput.open(webView: webView, window: window, context: boundContext, viewVersion: expectedViewport.viewVersion)
            } else {
                guard correlation.finish(latestNavigation, epoch: navigationEpoch) else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
                self.navigation = nil
                navigationOutcome = nil
                newInput = try NativePageInput.open(webView: webView, window: window, viewVersion: expectedViewport.viewVersion)
            }
            #else
            guard correlation.finish(latestNavigation, epoch: navigationEpoch) else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            self.navigation = nil
            navigationOutcome = nil
            let newInput = try NativePageInput.open(webView: webView, window: window, viewVersion: expectedViewport.viewVersion)
            #endif
            input = newInput
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "waitInputReady"
            #endif
            try await newInput.waitUntilReady()
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let boundContext { try await boundContext.validate() }
            #endif
            guard !Task.isCancelled, epoch == currentEpoch,
                  try viewport(version: expectedViewport.viewVersion) == expectedViewport else { throw AutomationError(code: .targetChanged, sideEffects: .possible) }
            guard ContinuousClock.now < deadline else { throw AutomationError(code: .timeout, sideEffects: .possible) }
            version = expectedViewport.viewVersion
            navigating = false
            return .navigationFinished(viewVersion: version)
        } catch {
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - diagnosticStart) / 1_000_000
            fputs("NAV_DIAG phase=\(diagnosticPhase) elapsedMs=\(elapsedMs) \(internalNavigationErrorFields(error))\n", stderr)
            #endif
            block(.unknown)
            navigating = false
            correlation.invalidate()
            self.navigation = nil
            input?.closeActivity()
            throw error
        }
    }

    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    private func detachNativeNavigationDecision() -> ((WKNavigationActionPolicy) -> Void)? {
        let permit = nativeNavigationPermit
        nativeNavigationPermit = nil
        let callback = permit?.decision
        permit?.decision = nil
        permit?.action = nil
        return callback
    }

    private func nativePermitValid(_ permit: NativeNavigationPermit, action: WKNavigationAction, requiresClosed: Bool) -> Bool {
        guard nativeNavigationPermit === permit, navigating, !invalidated, epoch == permit.commandEpoch,
              permit.source.pageEpoch &+ 1 == permit.commandEpoch, version == permit.oldVersion,
              ContinuousClock.now < permit.deadline, let context = boundContext, (try? context.checkLive()) != nil,
              input === permit.oldInput, permit.oldInput.activityStatus == .OK,
              !permit.oldInput.requiresOwnedTargetDestruction, !boundPointerHeld,
              requiresClosed ? permit.oldInput.activityClosed : (permit.oldInput.activityReady && !permit.oldInput.activityClosed),
              boundCommittedURL == permit.source.url, let webView,
              action.navigationType != .backForward, !action.shouldPerformDownload,
              action.sourceFrame.isMainFrame, action.targetFrame?.isMainFrame == true,
              action.sourceFrame.webView === webView, action.targetFrame?.webView === webView,
              action.sourceFrame.request.url == permit.source.url,
              let target = action.request.url, InternalNavigationPolicy.isWebURL(target),
              let current = webView.url, let delegate = boundNavigationDelegate,
              current == permit.source.url || current == target || delegate.acceptsCurrentURL(current, previous: boundCommittedURL),
              (try? checkedOwnedObjects()) != nil,
              (try? viewportValue(version: permit.expectedViewport.viewVersion)) == permit.expectedViewport else { return false }
        return true
    }

    private func handleNativePolicy(_ action: WKNavigationAction, decision: @escaping (WKNavigationActionPolicy) -> Void) -> Bool {
        guard let permit = nativeNavigationPermit else { return false }
        guard !permit.released, permit.action == nil, permit.decision == nil,
              !acceptedContinuationActions.contains(where: { $0 === action }),
              acceptedContinuationActions.count < AutomationLimits.replayEntries,
              nativePermitValid(permit, action: action, requiresClosed: false) else {
            block(.unknown); decision(.cancel); return true
        }
        acceptedContinuationActions.append(action)
        permit.action = action; permit.decision = decision
        fputs("NAV_DIAG phase=nativePolicyHeld\n", stderr)
        return true
    }

    private enum ContinuationValidation {
        case policy(WKNavigationAction)
        case pending(WKNavigationAction)
    }

    private func continuationStateValid(parent: WKNavigation, navigationEpoch expectedEpoch: UInt64,
                                        pageEpoch: UInt64, deadline: ContinuousClock.Instant,
                                        kind: ContinuationKind, source: FinishedSourceProof,
                                        validation: ContinuationValidation) -> Bool {
        guard navigating, !invalidated, epoch == pageEpoch, source.pageEpoch == pageEpoch,
              ContinuousClock.now < deadline,
              let context = boundContext, (try? context.checkLive()) != nil,
              let input, input.activityClosed, input.activityStatus == .OK,
              !input.requiresOwnedTargetDestruction, !boundPointerHeld,
              let expectedViewport = continuationViewport,
              navigation === parent, navigationEpoch == expectedEpoch,
              correlation.matches(parent, epoch: expectedEpoch),
              let latest = lastFinishedSourceProof, latest.navigation === source.navigation,
              latest.url == source.url, latest.pageEpoch == source.pageEpoch else { return false }
        switch kind {
        case .finished:
            guard source.navigation === parent, case .finished? = navigationOutcome,
                  finishedDocumentURL == source.url else { return false }
        case .provisional:
            guard navigationOutcome == nil, correlation.isRetired(source.navigation),
                  correlation.isUncommittedContinuation(parent, epoch: expectedEpoch) else { return false }
        }
        let action: WKNavigationAction
        switch validation {
        case let .policy(value), let .pending(value): action = value
        }
        guard let webView, action.navigationType == .other, !action.shouldPerformDownload,
              action.sourceFrame.isMainFrame, action.targetFrame?.isMainFrame == true,
              action.sourceFrame.webView === webView, action.targetFrame?.webView === webView,
              action.sourceFrame.request.url == source.url,
              let target = action.request.url, InternalNavigationPolicy.isWebURL(target),
              fixtureReady, let current = webView.url, let delegate = boundNavigationDelegate,
              (try? checkedOwnedObjects()) != nil,
              (try? viewportValue(version: expectedViewport.viewVersion)) == expectedViewport else { return false }
        let currentAllowed = delegate.acceptsCurrentURL(current, previous: boundCommittedURL)
        let currentEqualsActionTarget = current == target
        switch validation {
        case .policy:
            guard currentAllowed || currentEqualsActionTarget else { return false }
            if !currentAllowed && currentEqualsActionTarget {
                fputs("NAV_DIAG phase=continuationPolicyCandidate currentAllowed=\(currentAllowed) currentEqualsActionTarget=\(currentEqualsActionTarget)\n", stderr)
            }
        case .pending:
            guard currentAllowed else { return false }
        }
        return true
    }

    private func reserveContinuation(_ action: WKNavigationAction) -> Bool {
        var diagnosticReason = "guard"
        var finishedState: Bool?
        var provisionalState: Bool?
        var accepted = false
        defer {
            if !accepted {
                func state(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "notEvaluated" }
                func pathKind(_ url: URL?) -> String {
                    switch url?.path {
                    case "/search": return "search"
                    case "/retry/enablejs": return "retryEnableJS"
                    default: return "other"
                    }
                }
                let sourceURL = action.sourceFrame.request.url
                let targetURL = action.request.url
                let proof = lastFinishedSourceProof
                let sourceMatchesProof = sourceURL != nil && proof != nil && sourceURL == proof?.url
                let sourceMatchesCurrent = sourceURL != nil && webView?.url != nil && sourceURL == webView?.url
                let currentAllowed = webView?.url.map { boundNavigationDelegate?.acceptsCurrentURL($0, previous: boundCommittedURL) == true } ?? false
                let currentEqualsActionTarget = targetURL != nil && webView?.url != nil && targetURL == webView?.url
                let sourceWeb = sourceURL.map { InternalNavigationPolicy.isWebURL($0) } ?? false
                let targetWeb = targetURL.map { InternalNavigationPolicy.isWebURL($0) } ?? false
                let uncommitted = navigation.map { correlation.isUncommittedContinuation($0, epoch: navigationEpoch) } ?? false
                let proofRetired = proof.map { correlation.isRetired($0.navigation) } ?? false
                let inputClosed = input.map { $0.activityClosed && $0.activityStatus == .OK && !$0.requiresOwnedTargetDestruction } ?? false
                fputs("NAV_DIAG phase=continuationRejected reason=\(diagnosticReason) pending=\(pendingContinuation != nil) helperPending=\(correlation.hasPendingContinuation) budgetAvailable=\(acceptedContinuationActions.count < AutomationLimits.replayEntries) replay=\(acceptedContinuationActions.contains { $0 === action }) parentPresent=\(navigation != nil) deadlinePresent=\(continuationDeadline != nil) sourceProofPresent=\(proof != nil)\n", stderr)
                fputs("NAV_DIAG phase=continuationRejectedFrames other=\(action.navigationType == .other) download=\(action.shouldPerformDownload) sourceMain=\(action.sourceFrame.isMainFrame) targetMain=\(action.targetFrame?.isMainFrame == true) sourceOwned=\(webView != nil && action.sourceFrame.webView === webView) targetOwned=\(webView != nil && action.targetFrame?.webView === webView) sourceEqualsProof=\(sourceMatchesProof) sourceEqualsCurrent=\(sourceMatchesCurrent) currentAllowed=\(currentAllowed) currentEqualsActionTarget=\(currentEqualsActionTarget) sourceWeb=\(sourceWeb) targetWeb=\(targetWeb) sourceKind=\(pathKind(sourceURL)) targetKind=\(pathKind(targetURL))\n", stderr)
                fputs("NAV_DIAG phase=continuationRejectedState finishedStateValid=\(state(finishedState)) provisionalStateValid=\(state(provisionalState)) nativeUncommitted=\(uncommitted) proofRetired=\(proofRetired) inputClosed=\(inputClosed) contextPresent=\(boundContext != nil) viewportPresent=\(continuationViewport != nil) navigating=\(navigating) invalidated=\(invalidated) pointerHeld=\(boundPointerHeld)\n", stderr)
            }
        }
        guard pendingContinuation == nil, !correlation.hasPendingContinuation,
              acceptedContinuationActions.count < AutomationLimits.replayEntries,
              !acceptedContinuationActions.contains(where: { $0 === action }),
              let parent = navigation, let deadline = continuationDeadline,
              let sourceProof = lastFinishedSourceProof,
              let webView, action.navigationType == .other, !action.shouldPerformDownload,
              action.sourceFrame.isMainFrame, action.targetFrame?.isMainFrame == true,
              action.sourceFrame.webView === webView, action.targetFrame?.webView === webView,
              action.sourceFrame.request.url == sourceProof.url,
              let target = action.request.url, InternalNavigationPolicy.isWebURL(target) else { return false }
        let kind: ContinuationKind
        let ticket: UUID?
        diagnosticReason = "state"
        let finishedValid = continuationStateValid(parent: parent, navigationEpoch: navigationEpoch, pageEpoch: epoch,
                                                   deadline: deadline, kind: .finished, source: sourceProof, validation: .policy(action))
        finishedState = finishedValid
        if finishedValid {
            kind = .finished
            ticket = correlation.reserveContinuation(parent: parent, epoch: navigationEpoch)
        } else {
            let provisionalValid = continuationStateValid(parent: parent, navigationEpoch: navigationEpoch, pageEpoch: epoch,
                                                          deadline: deadline, kind: .provisional, source: sourceProof, validation: .policy(action))
            provisionalState = provisionalValid
            guard provisionalValid else { return false }
            kind = .provisional
            ticket = correlation.reserveProvisionalContinuation(parent: parent, epoch: navigationEpoch)
        }
        diagnosticReason = "ticket"
        guard let ticket else { return false }
        acceptedContinuationActions.append(action)
        pendingContinuation = PendingContinuation(kind: kind, source: sourceProof, action: action, parent: parent,
                                                  navigationEpoch: navigationEpoch, pageEpoch: epoch,
                                                  expectedURL: target, deadline: deadline, ticket: ticket)
        fputs("NAV_DIAG phase=continuationReserved kind=\(kind.rawValue) count=\(acceptedContinuationActions.count) navEpoch=\(navigationEpoch)\n", stderr)
        accepted = true
        return true
    }

    private func confirmProvisionalContinuation(_ candidate: WKNavigation, requireCommittedResponse: Bool) -> Bool {
        guard let pending = pendingContinuation, pending.kind == .provisional,
              candidate === pending.parent,
              continuationStateValid(parent: pending.parent, navigationEpoch: pending.navigationEpoch,
                                     pageEpoch: pending.pageEpoch, deadline: pending.deadline,
                                     kind: pending.kind, source: pending.source, validation: .pending(pending.action)) else { return false }
        if requireCommittedResponse {
            guard webView?.url == pending.expectedURL,
                  boundNavigationDelegate?.isAcceptedResponseURL(pending.expectedURL) == true else { return false }
        }
        guard correlation.confirmProvisionalContinuation(ticket: pending.ticket, parent: pending.parent,
                                                        epoch: pending.navigationEpoch) else { return false }
        pendingContinuation = nil
        let callback = requireCommittedResponse ? "commit" : "redirect"
        fputs("NAV_DIAG phase=continuationConfirmed kind=provisional callback=\(callback) navEpoch=\(navigationEpoch)\n", stderr)
        return true
    }
    #endif

    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
    private func registeredCallbackRejected(_ reason: StaticString, candidate: WKNavigation?) {
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let matches = candidate.map { correlation.matches($0, epoch: navigationEpoch) } ?? false
        fputs("REGISTERED_NATIVE_DIAG phase=callback.rejected monotonic_ms=\(ms) reason=\(reason) epoch=\(epoch) navigationEpoch=\(navigationEpoch) candidatePresent=\(candidate != nil) candidateMatches=\(matches) navigating=\(navigating) registeredURLPresent=\(registeredNavigationURL != nil)\n", stderr)
        block(.unknown, reason: reason)
    }
    #endif

    private func handleNavigation(_ event: BrowserAutomationNavigationEvent) {
        guard !invalidated else { return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if registeredGeneration != nil {
            #if SAFARIER_INTERNAL_TEST_APP
            switch event {
            case let .started(candidate), let .committed(candidate), let .finished(candidate), let .failed(candidate, _, _):
                if let candidate, correlation.isRetired(candidate) { return }
            case .processTerminated, .closed: break
            }
            guard navigating, registeredNavigationURL != nil else { registeredCallbackRejected("registered.state", candidate: nil); return }
            switch event {
            case .processTerminated:
                registeredCallbackRejected("registered.processTerminated", candidate: nil)
            case .closed:
                registeredCallbackRejected("registered.closed", candidate: nil)
            case let .started(candidate):
                if let permit = registeredNativePermit, permit.released {
                    guard let candidate, permit.epoch == epoch, permit.decision == nil else { registeredCallbackRejected("registered.started.permit", candidate: candidate); return }
                    navigation = candidate
                    navigationEpoch = correlation.begin(candidate)
                    registeredNativePermit = nil
                    return
                }
                guard let candidate, correlation.matches(candidate, epoch: navigationEpoch), navigationOutcome == nil else { registeredCallbackRejected("registered.started.correlation", candidate: candidate); return }
            case let .committed(candidate):
                guard let candidate, let url = webView?.url,
                      boundNavigationDelegate?.isAcceptedResponseURL(url) == true, navigationOutcome == nil,
                      correlation.noteCommitted(candidate, epoch: navigationEpoch) else { registeredCallbackRejected("registered.committed", candidate: candidate); return }
            case let .finished(candidate):
                guard let candidate, let url = webView?.url,
                      boundNavigationDelegate?.isAcceptedResponseURL(url) == true, navigationOutcome == nil,
                      correlation.noteFinished(candidate, epoch: navigationEpoch) else { registeredCallbackRejected("registered.finished", candidate: candidate); return }
                navigationOutcome = .finished
            case let .failed(candidate, error, provisional):
                if let candidate, correlation.isRetired(candidate) { return }
                guard let candidate, correlation.matches(candidate, epoch: navigationEpoch), navigationOutcome == nil else { registeredCallbackRejected("registered.failed", candidate: candidate); return }
                navigationOutcome = .failed(error, provisional: provisional)
            }
            #else
            block(.unknown)
            #endif
            return
        }
        #endif
        switch event {
        case .processTerminated, .closed:
            block(.unknown)
        case let .started(candidate):
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let permit = nativeNavigationPermit {
                guard permit.released, let action = permit.action, let candidate,
                      !knownNativeNavigations.contains(where: { $0 === candidate }),
                      knownNativeNavigations.count < AutomationLimits.replayEntries,
                      nativePermitValid(permit, action: action, requiresClosed: true), webView?.url == action.request.url else {
                    block(.unknown); return
                }
                knownNativeNavigations.append(candidate)
                nativeNavigationPermit = nil
                navigation = candidate; navigationEpoch = correlation.begin(candidate); navigationOutcome = nil
                fputs("NAV_DIAG phase=nativeRootStarted\n", stderr)
                return
            }
            if let candidate, correlation.isRetired(candidate) {
                fputs("NAV_DIAG phase=retiredCallback navEpoch=\(navigationEpoch)\n", stderr)
                return
            }
            if let pending = pendingContinuation {
                guard let candidate, candidate !== pending.parent,
                      knownNativeNavigations.count < AutomationLimits.replayEntries,
                      !knownNativeNavigations.contains(where: { $0 === candidate }),
                      continuationStateValid(parent: pending.parent, navigationEpoch: pending.navigationEpoch,
                                             pageEpoch: pending.pageEpoch, deadline: pending.deadline,
                                             kind: pending.kind, source: pending.source, validation: .pending(pending.action)),
                      webView?.url == pending.expectedURL,
                      let childEpoch = correlation.adoptContinuation(candidate, ticket: pending.ticket,
                                                                     parent: pending.parent, epoch: pending.navigationEpoch) else {
                    block(.unknown); return
                }
                guard knownNativeNavigations.count < AutomationLimits.replayEntries else { block(.unknown); return }
                knownNativeNavigations.append(candidate)
                pendingContinuation = nil
                navigation = candidate
                navigationEpoch = childEpoch
                navigationOutcome = nil
                finishedDocumentURL = nil
                committedDocumentURL = nil
                fputs("NAV_DIAG phase=continuationAdopted count=\(acceptedContinuationActions.count) navEpoch=\(navigationEpoch)\n", stderr)
                return
            }
            #endif
            guard let candidate, correlation.matches(candidate, epoch: navigationEpoch), navigationOutcome == nil else { block(.unknown); return }
        case let .committed(candidate):
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let candidate, correlation.isRetired(candidate) {
                fputs("NAV_DIAG phase=retiredCallback navEpoch=\(navigationEpoch)\n", stderr)
                return
            }
            #endif
            guard let candidate, correlation.matches(candidate, epoch: navigationEpoch), navigationOutcome == nil else {
                #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
                let eventKind: String
                if case .started = event { eventKind = "started" } else { eventKind = "committed" }
                let correlationMatches = candidate.map { correlation.matches($0, epoch: navigationEpoch) } ?? false
                fputs("NAV_DIAG phase=callbackRejected event=\(eventKind) correlationMatches=\(correlationMatches)\n", stderr)
                #endif
                block(.unknown); return
            }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if navigating, boundContext != nil {
                if pendingContinuation != nil {
                    guard confirmProvisionalContinuation(candidate, requireCommittedResponse: true) else { block(.unknown); return }
                }
                guard let url = webView?.url, boundNavigationDelegate?.isAcceptedResponseURL(url) == true,
                      correlation.noteCommitted(candidate, epoch: navigationEpoch) else { block(.unknown); return }
                committedDocumentURL = url
            }
            #endif
        case let .finished(candidate):
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let candidate, correlation.isRetired(candidate) {
                fputs("NAV_DIAG phase=retiredCallback navEpoch=\(navigationEpoch)\n", stderr)
                return
            }
            #endif
            guard let candidate, correlation.matches(candidate, epoch: navigationEpoch), navigationOutcome == nil else {
                #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
                let correlationMatches = candidate.map { correlation.matches($0, epoch: navigationEpoch) } ?? false
                fputs("NAV_DIAG phase=callbackRejected event=finished correlationMatches=\(correlationMatches)\n", stderr)
                #endif
                block(.unknown); return
            }
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if navigating, boundContext != nil {
                guard pendingContinuation == nil, !correlation.hasPendingContinuation,
                      let url = webView?.url, url == committedDocumentURL,
                      boundNavigationDelegate?.isAcceptedResponseURL(url) == true,
                      correlation.noteFinished(candidate, epoch: navigationEpoch) else { block(.unknown); return }
                finishedDocumentURL = url
                lastFinishedSourceProof = FinishedSourceProof(navigation: candidate, url: url, pageEpoch: epoch)
            }
            #endif
            navigationOutcome = .finished
        case let .failed(candidate, error, provisional):
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if let candidate, correlation.isRetired(candidate) {
                fputs("NAV_DIAG phase=retiredCallback navEpoch=\(navigationEpoch)\n", stderr)
                return
            }
            #endif
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            let correlationMatches = candidate.map { correlation.matches($0, epoch: navigationEpoch) } ?? false
            fputs("NAV_DIAG phase=callbackFailed correlationMatches=\(correlationMatches) \(internalNavigationErrorFields(error))\n", stderr)
            #endif
            guard let candidate, correlation.matches(candidate, epoch: navigationEpoch), navigationOutcome == nil else { block(.unknown); return }
            navigationOutcome = .failed(error, provisional: provisional)
        }
    }

    private func block(_ request: BackgroundUIRequest, reason: StaticString = "unknown") {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        registeredNativePermit?.decide(.cancel)
        registeredNativePermit = nil
        let nativeDecision = detachNativeNavigationDecision()
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        fputs("NAV_DIAG phase=block monotonic_ms=\(ms) reason=\(reason) request=\(request.rawValue) invalidated=\(invalidated)\n", stderr)
        #endif
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        boundContext?.beginClosing()
        #endif
        let wasInvalidated = invalidated
        if !invalidated {
            invalidated = true
            epoch &+= 1
            correlation.invalidate()
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            pendingContinuation = nil
            continuationDeadline = nil
            continuationViewport = nil
            finishedDocumentURL = nil
            committedDocumentURL = nil
            lastFinishedSourceProof = nil
            acceptedContinuationActions.removeAll()
            knownNativeNavigations.removeAll()
            #endif
        }
        input?.closeActivity()
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        nativeDecision?(.cancel)
        #endif
        if !wasInvalidated { onBlocked?(request) }
    }

    func quiesceInput() {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        if nativeNavigationPermit != nil { block(.unknown); return }
        #endif
        input?.closeActivity()
    }

    func prepareControlRelease() async throws {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        guard !controlReleasePrepared, !invalidated, !navigating, !boundPointerHeld,
              let context = boundContext, let input, input.buttonMask == 0,
              !input.requiresOwnedTargetDestruction else { throw AutomationError(code: .sessionBusy) }
        #if SAFARIER_INTERNAL_TEST_APP
        guard registeredNativePermit == nil, nativeNavigationPermit == nil, pendingContinuation == nil,
              !correlation.hasPendingContinuation else { throw AutomationError(code: .sessionBusy) }
        #endif
        _ = try checkedObjects()
        try await context.validate()
        guard !Task.isCancelled, self.input === input, !invalidated, !navigating,
              !boundPointerHeld, input.buttonMask == 0 else { throw AutomationError(code: .cancelled) }
        input.closeActivity()
        try await input.waitUntilClosed()
        try await context.validate()
        guard !Task.isCancelled, self.input === input, !invalidated, !navigating,
              !boundPointerHeld, input.buttonMask == 0, input.activityClosed,
              input.activityStatus == .OK, !input.requiresOwnedTargetDestruction else {
            throw AutomationError(code: .targetChanged)
        }
        _ = try checkedObjects()
        controlReleasePrepared = true
        #else
        throw AutomationError(code: .uiPolicyUnavailable)
        #endif
    }

    func commitControlRelease() throws {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        guard controlReleasePrepared, !Task.isCancelled, !navigating, !boundPointerHeld,
              let context = boundContext, let input, input.activityClosed,
              input.activityStatus == .OK, !input.requiresOwnedTargetDestruction,
              input.buttonMask == 0 else { throw AutomationError(code: .targetChanged) }
        try context.checkLive()
        let (session, controller, _, _) = try checkedObjects()
        if let generation = registeredGeneration {
            #if SAFARIER_INTERNAL_TEST_APP
            guard registeredNativePermit == nil else { throw AutomationError(code: .sessionBusy) }
            #endif
            try context.validateRegisteredTarget(identity)
            guard session.restoreRegisteredControl(controller: controller, generation: generation, input: input) else {
                throw AutomationError(code: .uiPolicyUnavailable)
            }
        } else {
            guard session.enableRetainedManualInteraction(controller: controller) else { throw AutomationError(code: .uiPolicyUnavailable) }
        }
        invalidated = true
        epoch &+= 1
        onBlocked = nil
        boundNavigationDelegate = nil
        #else
        throw AutomationError(code: .uiPolicyUnavailable)
        #endif
    }

    func finishControlRelease() throws {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        guard controlReleasePrepared, invalidated, let input, input.activityClosed,
              input.activityStatus == .OK, !input.requiresOwnedTargetDestruction,
              let session, let controller, let webView, let window,
              session.executionPolicy == .interactive,
              session.openControllers.contains(where: { $0 === controller }),
              controller.session === session, controller.window === window,
              controller.webView === webView, webView.window === window,
              window.windowNumber == windowNumber, NSApp.isRunning else {
            throw AutomationError(code: .targetChanged)
        }
        self.input = nil
        boundContext = nil
        registeredGeneration = nil
        registeredURL = nil
        #else
        throw AutomationError(code: .uiPolicyUnavailable)
        #endif
    }

    func detachBorrowedControl() async -> Bool {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        guard registeredBorrowed, registeredGeneration != nil else { return false }
        return await destroy()
        #else
        return false
        #endif
    }

    func destroy() async -> Bool {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if registeredBorrowed && registeredGeneration == nil { return false }
        if let generation = registeredGeneration {
            #if SAFARIER_INTERNAL_TEST_APP
            registeredNativePermit?.decide(.cancel)
            registeredNativePermit = nil
            #endif
            invalidated = true
            epoch &+= 1
            correlation.invalidate()
            navigation = nil
            navigationOutcome = nil
            guard let session, let controller, let input,
                  await session.quiesceAndRestoreRegisteredControl(controller: controller, generation: generation, input: input) else {
                return false
            }
            onBlocked = nil
            self.input = nil
            boundContext = nil
            boundNavigationDelegate = nil
            registeredGeneration = nil
            registeredURL = nil
            self.session = nil
            self.controller = nil
            webView = nil
            window = nil
            return true
        }
        #endif
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        let nativeDecision = detachNativeNavigationDecision()
        #endif
        invalidated = true
        epoch &+= 1
        correlation.invalidate()
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        pendingContinuation = nil
        continuationDeadline = nil
        continuationViewport = nil
        finishedDocumentURL = nil
        committedDocumentURL = nil
        lastFinishedSourceProof = nil
        acceptedContinuationActions.removeAll()
        knownNativeNavigations.removeAll()
        #endif
        navigation = nil
        navigationOutcome = nil
        let oldInput = input
        oldInput?.closeActivity()
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        nativeDecision?(.cancel)
        #endif
        var activityConfirmed = false
        if let oldInput {
            do {
                try await oldInput.waitUntilClosed()
                activityConfirmed = oldInput.activityStatus == .OK && !oldInput.requiresOwnedTargetDestruction
            } catch { activityConfirmed = false }
        }
        input = nil
        onBlocked = nil
        var closedOwnedWindow = false
        if let session, let controller, let webView, let window,
           session.openControllers.contains(where: { $0 === controller }),
           controller.session === session, controller.webView === webView, controller.window === window,
           webView.window === window, window.windowNumber == windowNumber {
            controller.onAutomationNavigation = nil
            session.onAutomationUIBlocked = nil
            webView.stopLoading()
            window.close()
            closedOwnedWindow = !session.openControllers.contains(where: { $0 === controller }) && !window.isVisible
        }
        session = nil
        controller = nil
        webView = nil
        window = nil
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if boundContext != nil { return activityConfirmed && closedOwnedWindow }
        #endif
        return false
    }
}

#if SAFARIER_BOUND_LOCAL_CANDIDATE
/// The original controller's policy rejects file URLs. This candidate-scoped
/// delegate replaces only navigation policy, retaining its UI delegate guards.
@MainActor
private final class BoundFixtureNavigationDelegate: NSObject, WKNavigationDelegate {
    private let fixture: URL
    private let registered: Bool
    private let context: RunnerBinderContext
    private weak var expectedWebView: WKWebView?
    private let event: (BrowserAutomationNavigationEvent) -> Void
    private let blocked: () -> Void
    private var admitted = false
    #if SAFARIER_INTERNAL_TEST_APP
    private var explicitURL: URL?
    private var allowedURLs: Set<URL> = []
    private var finalResponseURL: URL?
    private var redirectPending = false
    private var initialActionPending = false
    var nativePolicy: ((WKNavigationAction, @escaping (WKNavigationActionPolicy) -> Void) -> Bool)?
    var nativePermitPresent: (() -> Bool)?
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    var sameDocumentPermitSnapshot: ((URL?, URL?) -> (present: Bool, epochMatches: Bool, sourceMatches: Bool, targetDiffersFromSource: Bool))?
    var sameDocumentCandidate: ((WKWebView?, WKNavigation?, Int, URL?, URL?) -> Void)?
    #endif
    var retiredNavigation: ((WKNavigation) -> Bool)?
    var redirectMatches: ((WKNavigation) -> Bool)?
    var reserveContinuation: ((WKNavigationAction) -> Bool)?
    var confirmProvisionalRedirect: ((WKNavigation) -> Bool)?
    var hasPendingContinuation: (() -> Bool)?

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var sameDocumentABIReported = false
    private static let sameDocumentSelector = NSSelectorFromString("_webView:navigation:didSameDocumentNavigation:")
    static let sameDocumentABI: Bool = {
        guard let proto = objc_getProtocol("WKNavigationDelegatePrivate") else { return false }
        let descriptor = protocol_getMethodDescription(proto, sameDocumentSelector, false, true)
        guard descriptor.name != nil, let protocolTypes = descriptor.types,
              String(cString: protocolTypes) == "v40@0:8@16@24q32",
              let implementation = class_getInstanceMethod(BoundFixtureNavigationDelegate.self, sameDocumentSelector),
              let implementationTypes = method_getTypeEncoding(implementation) else { return false }
        return String(cString: implementationTypes) == String(cString: protocolTypes)
    }()

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == Self.sameDocumentSelector {
            let supported = registered && Self.sameDocumentABI
            if registered && !sameDocumentABIReported {
                sameDocumentABIReported = true
                fputs("REGISTERED_SAME_DOCUMENT_DIAG phase=abi monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) supported=\(supported)\n", stderr)
            }
            return supported
        }
        return super.responds(to: aSelector)
    }

    @objc(_webView:navigation:didSameDocumentNavigation:)
    private func observeSameDocument(_ callbackWebView: WKWebView?, navigation: AnyObject?, type: Int) {
        var frameObject: AnyObject?, requestObject: AnyObject?
        var frameStatus = -1, userStatus = -1, requestStatus = -1
        var userInitiated: ObjCBool = false
        let nav = navigation as? WKNavigation
        if let nav {
            frameStatus = Int(SFRGetObject(nav, "_initiatingFrame", &frameObject, nil).rawValue)
            userStatus = Int(SFRGetBool(nav, "_isUserInitiated", &userInitiated, nil).rawValue)
            requestStatus = Int(SFRGetObject(nav, "_request", &requestObject, nil).rawValue)
        }
        let frame = frameObject as? WKFrameInfo
        var frameViewObject: AnyObject?, frameRequestObject: AnyObject?
        var sourceObject: AnyObject?, targetObject: AnyObject?, currentObject: AnyObject?
        var frameViewStatus = -1, frameMainStatus = -1, frameRequestStatus = -1, sourceStatus = -1
        var targetStatus = -1, currentStatus = -1
        var sourceMain: ObjCBool = false
        if let frame {
            frameViewStatus = Int(SFRGetObject(frame, "webView", &frameViewObject, nil).rawValue)
            frameMainStatus = Int(SFRGetBool(frame, "isMainFrame", &sourceMain, nil).rawValue)
            frameRequestStatus = Int(SFRGetObject(frame, "request", &frameRequestObject, nil).rawValue)
        }
        if let request = frameRequestObject as? NSURLRequest { sourceStatus = Int(SFRGetObject(request, "URL", &sourceObject, nil).rawValue) }
        if let request = requestObject as? NSURLRequest { targetStatus = Int(SFRGetObject(request, "URL", &targetObject, nil).rawValue) }
        if let callbackWebView { currentStatus = Int(SFRGetObject(callbackWebView, "URL", &currentObject, nil).rawValue) }
        let sourceURL = sourceObject as? URL
        let targetURL = targetObject as? URL
        let currentURL = currentObject as? URL
        let snapshot = sameDocumentPermitSnapshot?(sourceURL, targetURL) ?? (present: false, epochMatches: false, sourceMatches: false, targetDiffersFromSource: false)
        let navClass = navigation == nil ? "none" : (nav != nil ? "WKNavigation" : "other")
        let callbackViewOwned = callbackWebView != nil && expectedWebView === callbackWebView
        let sourceOwned = expectedWebView != nil && (frameViewObject as? WKWebView) === expectedWebView
        fputs("REGISTERED_SAME_DOCUMENT_DIAG phase=callback monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) type=\(type) callbackViewPresent=\(callbackWebView != nil) callbackViewOwned=\(callbackViewOwned) navPresent=\(navigation != nil) navClass=\(navClass) framePresent=\(frame != nil) sourceOwned=\(sourceOwned) sourceMain=\(sourceMain.boolValue) sourceMatches=\(snapshot.sourceMatches) targetDiffersFromSource=\(snapshot.targetDiffersFromSource) currentURLmatchesRequest=\(currentURL != nil && targetURL != nil && currentURL == targetURL) userInitiated=\(userInitiated.boolValue) permitPresent=\(snapshot.present) epochMatches=\(snapshot.epochMatches) frameStatus=\(frameStatus) userStatus=\(userStatus) requestStatus=\(requestStatus) frameViewStatus=\(frameViewStatus) frameMainStatus=\(frameMainStatus) frameRequestStatus=\(frameRequestStatus) sourceStatus=\(sourceStatus) targetStatus=\(targetStatus) currentStatus=\(currentStatus)\n", stderr)
        if registered {
            let frameValid = frameStatus == 0 && (frameObject == nil || (frame != nil && sourceOwned && sourceMain.boolValue && snapshot.sourceMatches))
            sameDocumentCandidate?(callbackWebView, frameValid && requestStatus == 0 && targetStatus == 0 && currentStatus == 0 ? nav : nil, type, targetURL, currentURL)
        }
    }
    #endif

    private func isWebURL(_ url: URL) -> Bool {
        InternalNavigationPolicy.isWebURL(url)
    }
    private func logCancel(_ reason: String, mainFrame: Bool) {
        fputs("NAV_DIAG phase=policyCancel reason=\(reason) mainFrame=\(mainFrame) initialPending=\(initialActionPending) redirectPending=\(redirectPending)\n", stderr)
    }
    private var retryKnownGET = false
    func canRetryOriginalGET(_ url: URL) -> Bool { explicitURL == url && retryKnownGET }
    func prepareRetry(_ url: URL) -> Bool {
        guard canRetryOriginalGET(url) else { return false }
        retryKnownGET = false; initialActionPending = true; redirectPending = false; finalResponseURL = nil
        return true
    }
    func beginExplicitNavigation(_ url: URL) throws {
        guard admitted, explicitURL == nil, isWebURL(url), (try? context.checkLive()) != nil else {
            throw AutomationError(code: .targetChanged)
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        fputs("NAV_DIAG phase=explicitBegin\n", stderr)
        #endif
        retryKnownGET = false
        explicitURL = url
        allowedURLs = [url]
        finalResponseURL = nil
        redirectPending = false
        initialActionPending = true
    }
    func beginNativeNavigation(_ url: URL) throws {
        try beginExplicitNavigation(url)
        initialActionPending = false
    }
    func acceptsCurrentURL(_ url: URL, previous: URL?) -> Bool {
        url == previous || allowedURLs.contains(url)
    }
    func isAcceptedResponseURL(_ url: URL) -> Bool {
        explicitURL != nil && finalResponseURL == url && allowedURLs.contains(url) && isWebURL(url)
    }
    func canFinishExplicitNavigation(_ url: URL) -> Bool { isAcceptedResponseURL(url) }
    func finishExplicitNavigation(_ url: URL) -> Bool {
        guard canFinishExplicitNavigation(url) else { return false }
        explicitURL = nil
        redirectPending = false
        initialActionPending = false
        return true
    }
    #endif
    init(fixture: URL, context: RunnerBinderContext, expectedWebView: WKWebView, event: @escaping (BrowserAutomationNavigationEvent) -> Void, blocked: @escaping () -> Void, registered: Bool = false) {
        self.fixture = fixture; self.context = context; self.expectedWebView = expectedWebView; self.event = event; self.blocked = blocked; self.registered = registered
        self.admitted = registered
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === expectedWebView else { decisionHandler(.cancel); context.beginClosing(); blocked(); return }
        #if SAFARIER_INTERNAL_TEST_APP
        if action.navigationType == .backForward {
            logCancel("backForward", mainFrame: action.targetFrame?.isMainFrame == true)
            decisionHandler(.cancel); context.beginClosing(); blocked(); return
        }
        if admitted {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            var contextLive = false
            guard ({ contextLive = (try? context.checkLive()) != nil; return contextLive })(), let frame = action.targetFrame,
                  let url = action.request.url, !action.shouldPerformDownload else {
                if registered {
                    let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
                    fputs("REGISTERED_NATIVE_DIAG phase=actionAdmission monotonic_ms=\(ms) contextLive=\(contextLive) targetPresent=\(action.targetFrame != nil) urlPresent=\(action.request.url != nil) download=\(action.shouldPerformDownload)\n", stderr)
                }
                logCancel("actionAdmission", mainFrame: action.targetFrame?.isMainFrame == true)
                decisionHandler(.cancel); context.beginClosing(); blocked(); return
            }
            #else
            guard (try? context.checkLive()) != nil, let frame = action.targetFrame,
                  let url = action.request.url, !action.shouldPerformDownload else {
                logCancel("actionAdmission", mainFrame: action.targetFrame?.isMainFrame == true)
                decisionHandler(.cancel); context.beginClosing(); blocked(); return
            }
            #endif
            if !frame.isMainFrame {
                guard InternalNavigationPolicy.allowsFrameURL(url) else {
                    logCancel("subframeURL", mainFrame: false)
                    decisionHandler(.cancel); context.beginClosing(); blocked(); return
                }
                decisionHandler(.allow); return
            }
            if nativePermitPresent?() == true {
                if nativePolicy?(action, decisionHandler) != true { context.beginClosing(); blocked(); decisionHandler(.cancel) }
                return
            }
            guard hasPendingContinuation?() != true else {
                decisionHandler(.cancel); context.beginClosing(); blocked(); return
            }
            if explicitURL != nil, !initialActionPending, !redirectPending,
               reserveContinuation?(action) == true {
                allowedURLs.insert(url)
                finalResponseURL = nil
                decisionHandler(.allow); return
            }
            guard let explicitURL, isWebURL(url), (initialActionPending && url == explicitURL) || redirectPending else {
                logCancel("mainExplicitURL", mainFrame: true)
                #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
                let explicitURLPresent = explicitURL != nil
                let urlEqualsExplicit = explicitURL.map { url == $0 } ?? false
                let sourceURL = action.sourceFrame.request.url
                let sourceIsFixture = sourceURL == fixture
                let sourceURLMatchesCurrent = sourceURL.map { $0 == webView.url } ?? false
                fputs("NAV_DIAG phase=mainExplicitURLDetails navigationType=\(action.navigationType.rawValue) explicitURLPresent=\(explicitURLPresent) urlEqualsExplicit=\(urlEqualsExplicit) sourceIsFixture=\(sourceIsFixture) sourceURLMatchesCurrent=\(sourceURLMatchesCurrent) urlIsWebURL=\(isWebURL(url))\n", stderr)
                #endif
                decisionHandler(.cancel); context.beginClosing(); blocked(); return
            }
            if initialActionPending { retryKnownGET = action.request.httpMethod == "GET" && action.request.httpBody == nil && action.request.httpBodyStream == nil }
            else { retryKnownGET = false }
            allowedURLs.insert(url)
            redirectPending = false
            initialActionPending = false
            decisionHandler(.allow); return
        }
        #endif
        guard (try? context.checkLive()) != nil, !admitted, action.request.url == fixture,
              action.targetFrame?.isMainFrame == true, !action.shouldPerformDownload else {
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            logCancel("fixtureAction", mainFrame: action.targetFrame?.isMainFrame == true)
            #endif
            decisionHandler(.cancel); context.beginClosing(); blocked(); return
        }
        admitted = true
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === expectedWebView else { decisionHandler(.cancel); context.beginClosing(); blocked(); return }
        #if SAFARIER_INTERNAL_TEST_APP
        if admitted, let url = response.response.url, (registered || url != fixture) {
            let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            guard (try? context.checkLive()) != nil, response.canShowMIMEType,
                  !(response.isForMainFrame && disposition.hasPrefix("attachment")),
                  isWebURL(url) || (!response.isForMainFrame && InternalNavigationPolicy.allowsFrameURL(url)) else {
                logCancel("responseAdmission", mainFrame: response.isForMainFrame)
                decisionHandler(.cancel); context.beginClosing(); blocked(); return
            }
            if response.isForMainFrame {
                guard explicitURL != nil, allowedURLs.contains(url) || redirectPending else {
                    logCancel("responseMainExplicitURL", mainFrame: true)
                    decisionHandler(.cancel); context.beginClosing(); blocked(); return
                }
                allowedURLs.insert(url); finalResponseURL = url; redirectPending = false
            }
            decisionHandler(.allow); return
        }
        #endif
        guard (try? context.checkLive()) != nil, response.isForMainFrame, response.response.url == fixture, response.canShowMIMEType else {
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            logCancel("fixtureResponse", mainFrame: response.isForMainFrame)
            #endif
            decisionHandler(.cancel); context.beginClosing(); blocked(); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === expectedWebView else { context.beginClosing(); blocked(); return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        let matched = navigation.map { redirectMatches?($0) == true } ?? false
        fputs("NAV_DIAG phase=didStart redirectMatched=\(matched)\n", stderr)
        #endif
        event(.started(navigation))
    }
    #if SAFARIER_INTERNAL_TEST_APP
    @available(macOS 26.0, *)
    func webView(_ webView: WKWebView, shouldGoTo item: WKBackForwardListItem, willUseInstantBack: Bool,
                 completionHandler: @escaping (Bool) -> Void) {
        guard webView === expectedWebView else { completionHandler(false); context.beginClosing(); blocked(); return }
        completionHandler(false); context.beginClosing(); blocked()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if webView === expectedWebView, let navigation, retiredNavigation?(navigation) == true { return }
        guard webView === expectedWebView, let navigation, explicitURL != nil, redirectMatches?(navigation) == true,
              (try? context.checkLive()) != nil else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
            let correlationMatched = navigation.map { redirectMatches?($0) == true } ?? false
            fputs("NAV_DIAG phase=serverRedirectRejected navigationPresent=\(navigation != nil) explicitPresent=\(explicitURL != nil) correlationMatched=\(correlationMatched)\n", stderr)
            #endif
            context.beginClosing(); blocked(); return
        }
        if hasPendingContinuation?() == true {
            guard confirmProvisionalRedirect?(navigation) == true else { context.beginClosing(); blocked(); return }
            redirectPending = false
            return
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        fputs("NAV_DIAG phase=serverRedirect redirectMatched=true\n", stderr)
        #endif
        retryKnownGET = false
        redirectPending = true
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard webView === expectedWebView, (try? context.checkLive()) != nil,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            let serverTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            fputs("NAV_DIAG phase=authenticationCancel serverTrust=\(serverTrust)\n", stderr)
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil); context.beginClosing(); blocked(); return
        }
        completionHandler(.performDefaultHandling, nil)
    }
    #endif
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === expectedWebView else { context.beginClosing(); blocked(); return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        let matched = navigation.map { redirectMatches?($0) == true } ?? false
        fputs("NAV_DIAG phase=didCommit redirectMatched=\(matched)\n", stderr)
        #endif
        event(.committed(navigation))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === expectedWebView else { context.beginClosing(); blocked(); return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        let matched = navigation.map { redirectMatches?($0) == true } ?? false
        fputs("NAV_DIAG phase=didFinish redirectMatched=\(matched)\n", stderr)
        #endif
        event(.finished(navigation))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard webView === expectedWebView else { context.beginClosing(); blocked(); return }; event(.failed(navigation, error, provisional: false)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard webView === expectedWebView else { context.beginClosing(); blocked(); return }; event(.failed(navigation, error, provisional: true)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { guard webView === expectedWebView else { context.beginClosing(); blocked(); return }; context.beginClosing(); event(.processTerminated) }
}
#endif
