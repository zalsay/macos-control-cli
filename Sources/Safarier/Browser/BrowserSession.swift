import AppKit
import WebKit
import SafarierCore
import SafarierWebKit

/// 一个 Runner 进程 = 一个环境的浏览会话。所有窗口和标签共用同一个 WKWebViewConfiguration：
/// 同一个网站数据存储、同一个代理（或 sing-box）、同样的原生引擎接口设置和机型模拟。
@MainActor
final class BrowserSession: NSObject, NSApplicationDelegate, BrowserActions {
    static let defaultContentSize = NSSize(width: 1280, height: 800)

    private(set) var executionPolicy: BrowserExecutionPolicy
    var onAutomationUIBlocked: ((BackgroundUIRequest) -> Void)?
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var boundCleanupUnconfirmed = false
    private var manualHandoffPending = false
    private var registeredControl: (generation: UUID, controller: BrowserWindowController, state: BrowserWindowController.RegisteredWindowState, monitor: RegisteredTabMonitor?)?
    #endif
    let profile: Profile
    let workspace: SafarierWorkspace?
    var bookmarkWorkspace: SafarierWorkspace? { workspace }
    public let webCredentialStore: WebCredentialStore
    private let tabSessionStore: TabSessionStore?
    private var saveSessionTimer: Timer?
    private var isRestoringSession = false
    let configuration: WKWebViewConfiguration
    let device: MacDeviceModel?
    let isPrivate: Bool
    let accent: NSColor
    let startPageDetails: [String]
    let downloads = DownloadsController()
    private(set) var report: PrivacyCapabilityReport
    private let deviceSimulation: DeviceSimulation?
    private var controllers: [BrowserWindowController] = []
    private var sourceWindows: [PageSourceWindowController] = []
    private var reportPrinted = false
    private var promoteOnActivation: Bool
    let initialNonActivatingPresentation: Bool
    /// 默认打开：右键菜单直接有「检查元素」，和开了「开发」菜单的真 Safari 一样。只登记到本机的 Web Inspector，网页读不到。
    private(set) var inspectable = true
    /// 最近关闭的标签的网址（最新的在最后），⇧⌘T 依次恢复。
    private(set) var closedTabURLs: [URL] = []
    static let closedTabLimit = 20

    /// 和管理器里环境头像一样的配色（按 id 固定），方便认出窗口属于哪个环境。
    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemGreen, .systemIndigo, .systemMint, .systemBrown]

    init(profile: Profile, output: WebViewConfigurationFactory.Output, outboundDescription: String, diagnostics: SPIDiagnostics, promoteOnActivation: Bool = false, workspace: SafarierWorkspace? = nil) {
        self.promoteOnActivation = promoteOnActivation
        self.initialNonActivatingPresentation = promoteOnActivation
        self.executionPolicy = output.executionPolicy
        self.profile = profile
        self.workspace = workspace
        if let workspace, output.executionPolicy == .interactive, profile.mode == .persistent {
            self.tabSessionStore = TabSessionStore(workspace: workspace, profileID: profile.id)
        } else {
            self.tabSessionStore = nil
        }
        if let workspace, profile.mode == .ephemeral {
            try? TabSessionStore(workspace: workspace, profileID: profile.id).clear()
        }
        self.webCredentialStore = WebCredentialStore(workspace: workspace, profileID: profile.id, isEphemeral: profile.mode == .ephemeral)
        self.configuration = output.configuration
        self.report = output.report
        self.device = profile.deviceModel.flatMap(MacDeviceModel.preset)
        self.isPrivate = profile.mode == .ephemeral
        self.accent = Self.palette[Int(profile.id.uuid.0) % Self.palette.count]
        self.deviceSimulation = device.map { DeviceSimulation(model: $0, diagnostics: diagnostics) }
        var details = [isPrivate ? "临时环境 · 关闭窗口后不留任何网站数据" : "持久环境 · 网站数据保存在这个环境里", "出站：\(outboundDescription)"]
        if let device { details.append("机型：\(device.name)") }
        // 跟随代理时 profile 里已经是按出口 IP 解析出的语言和时区（RunnerMain 传进来的 effectiveProfile）。
        let region = [
            profile.languages.isEmpty ? nil : "语言：\(profile.languages.joined(separator: ", "))",
            profile.timeZoneIdentifier.map { "时区：\($0)" },
        ].compactMap { $0 }
        if !region.isEmpty {
            let source = profile.followProxyLanguages || profile.followProxyTimeZone ? "（跟随代理出口）" : ""
            details.append(region.joined(separator: " · ") + source)
        }
        self.startPageDetails = details
        super.init()
        if output.executionPolicy == .interactive {
            output.configuration.userContentController.addUserScript(FormAutofillBridge.userScript)
            output.configuration.userContentController.add(WeakScriptMessageHandler(self), name: FormAutofillBridge.messageHandlerName)
        }
        downloads.onChange = { [weak self] in self?.controllers.forEach { $0.downloadsChanged() } }
    }

    func routeUI<T>(_ request: BackgroundUIRequest, perform: () -> T, deny: () -> T) -> T {
        BackgroundPagePolicy(mode: executionPolicy).route(request, onBlocked: { [weak self] request in
            self?.onAutomationUIBlocked?(request)
        }, perform: perform, deny: deny)
    }

    func controllerPolicy(_ controller: BrowserWindowController) -> BrowserExecutionPolicy {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if let current = registeredControl, current.monitor != nil, current.controller !== controller {
            return .interactive
        }
        #endif
        return executionPolicy
    }

    func routeControllerUI<T>(_ request: BackgroundUIRequest, controller: BrowserWindowController, perform: () -> T, deny: () -> T) -> T {
        BackgroundPagePolicy(mode: controllerPolicy(controller)).route(request, onBlocked: { [weak self] request in
            self?.onAutomationUIBlocked?(request)
        }, perform: perform, deny: deny)
    }

    @discardableResult
    func allowUI(_ request: BackgroundUIRequest) -> Bool {
        routeUI(request, perform: { true }, deny: { false })
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private weak var registeredInitialController: BrowserWindowController?
    private var registeredLaunchFinished = false
    private var registeredInitialPresentationAttempted = false
    private(set) var registeredInitialPresentationConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        registeredLaunchFinished = true
        presentRegisteredInitialWindowIfReady()
    }

    private func presentRegisteredInitialWindowIfReady() {
        guard registeredLaunchFinished, !registeredInitialPresentationAttempted,
              let controller = registeredInitialController,
              controllers.contains(where: { $0 === controller }) else { return }
        guard registeredControl == nil, executionPolicy == .interactive else { return }
        let window = controller.window
        guard !NSApp.isHidden, !window.isMiniaturized, NSEvent.pressedMouseButtons == 0,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) else { return }
        registeredInitialPresentationAttempted = true
        if initialNonActivatingPresentation {
            // CLI launch is an explicit request to bring the environment forward.
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        registeredInitialPresentationConfirmed = BrowserWindowController.registeredWindowOnCurrentScreen(window)
        controller.traceRegisteredPresentation("initialShown", confirmed: registeredInitialPresentationConfirmed)
    }

    func startRegisteredInteractive(url: URL?) {
        guard executionPolicy == .interactive, controllers.isEmpty else { return }
        if let tabSessionStore, profile.mode == .persistent,
           let saved = try? tabSessionStore.load(),
           saved.windows.contains(where: { !$0.tabs.isEmpty }) {
            restoreSession(saved, explicitURL: url)
            registeredInitialController = keyController ?? frontmostController ?? controllers.first
            presentRegisteredInitialWindowIfReady()
            return
        }
        let controller = makeNewWindowController(configuration: nil)
        controller.window.center()
        registeredInitialController = controller
        controller.loadRegisteredInitial(url)
        presentRegisteredInitialWindowIfReady()
        scheduleDebouncedSaveSessionState()
    }

    func makeRegisteredAutomationService(workspace: SafarierWorkspace, context: RunnerBinderContext) throws -> RunnerAutomationService {
        try context.checkLive()
        guard profile.id == context.profileID, executionPolicy == .interactive else { throw AutomationError(code: .profileNotAllowed) }
        let profileID = profile.id, root = workspace.root
        return RunnerAutomationService(profileID: profileID, runnerInstanceID: context.runnerInstanceID,
            permissionReader: {
                do {
                    try await context.validatePermissionFirst()
                    let allowed = await RunnerAutomationService.repositoryPermission(profileID: profileID, root: root)
                    try await context.validatePermissionSecond()
                    return allowed
                } catch { return false }
            },
            pageFactory: { [weak self] in
                try await context.validate()
                guard let self, self.profile.id == profileID else { throw AutomationError(code: .targetChanged) }
                return try await self.makeRegisteredAutomationPage(context: context)
            }, snapshotFactory: { try AutomationSnapshotStore(workspaceRoot: root) },
            cleanupVerifier: { [weak self] in self.map { !$0.boundCleanupUnconfirmed && $0.registeredControl == nil } ?? false },
            localCandidate: true, pageOwnership: .borrowed)
    }

    func makeRegisteredAutomationPage(context: RunnerBinderContext) async throws -> OwnedBrowserAutomationPage {
        try await context.validate()
        guard profile.id == context.profileID, executionPolicy == .interactive,
              let first = controllers.first else {
            RegisteredAdmissionDiagnostic.check(false, .session)
            throw AutomationError(code: .interactionRequired)
        }
        let generation = UUID()
        let (controller, monitor) = try selectRegisteredTarget(first: first, onRevoke: { context.beginClosing() }, onInvalidated: { [weak self] in
            if self?.registeredControl?.generation == generation { self?.onAutomationUIBlocked?(.unknown) }
        })
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        fputs("REGISTERED_RESTORE_DIAG phase=target.selected monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) windowID=\(controller.registeredWindowID.uuidString) pageID=\(controller.registeredPageID.uuidString) initialController=\(registeredInitialController === controller)\n", stderr)
        #endif
        // Attach must not retry startup presentation or change window ordering.
        guard RegisteredAdmissionDiagnostic.check(registeredInitialPresentationConfirmed, .initialPresentation) else { throw AutomationError(code: .interactionRequired) }
        if registeredInitialController === controller {
            registeredInitialController = nil // Only the first attach may wait for startup.
            let webView = controller.webView, window = controller.window
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            let loadTraceStart = DispatchTime.now().uptimeNanoseconds
            func traceInitialLoad(_ phase: StaticString, result: String = "ok") {
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = now >= loadTraceStart ? (now - loadTraceStart) / 1_000_000 : 0
                fputs("REGISTERED_LOAD_DIAG phase=\(phase) monotonic_ms=\(now / 1_000_000) elapsed_ms=\(elapsed) loading=\(webView.isLoading) urlPresent=\(webView.url != nil) result=\(result)\n", stderr)
            }
            traceInitialLoad("before")
            #endif
            do {
            try await Self.waitForRegisteredInitialLoad(deadline: .now + .seconds(AutomationLimits.actionSeconds), validate: {
                try await context.validate()
                guard self.executionPolicy == .interactive, self.registeredTargetValid(controller, monitor: monitor),
                      controller.session === self,
                      controller.webView === webView, controller.window === window,
                      webView.window === window else { throw AutomationError(code: .targetChanged) }
                try controller.validateRegisteredAdmission(allowLoading: true, allowTabGroup: monitor != nil)
            }, ready: { !webView.isLoading && webView.url != nil })
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            traceInitialLoad("after")
            #endif
            } catch {
                #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
                traceInitialLoad("catch", result: (error as? AutomationError)?.code.rawValue ?? "other")
                #endif
                throw error
            }
        }
        return try await OwnedBrowserAutomationPage.attachRegistered(session: self, controller: controller, context: context, monitor: monitor, generation: generation)
    }

    private func registeredWindows() -> [(NSWindow, UUID)] { controllers.map { ($0.window, $0.registeredWindowID) } }

    func selectRegisteredTarget(first: BrowserWindowController, onRevoke: @escaping @Sendable () -> Void,
                                onInvalidated: @escaping @MainActor () -> Void) throws -> (BrowserWindowController, RegisteredTabMonitor?) {
        guard RegisteredAdmissionDiagnostic.check(controllers.first === first, .targetSelection) else { throw AutomationError(code: .interactionRequired) }
        if controllers.count == 1 { return (first, nil) }
        guard let group = first.window.tabGroup else { RegisteredAdmissionDiagnostic.check(false, .targetNoGroup); throw AutomationError(code: .interactionRequired) }
        guard let monitor = RegisteredTabMonitor(group: group, windows: registeredWindows(), onRevoke: onRevoke, onInvalidated: onInvalidated) else { RegisteredAdmissionDiagnostic.check(false, .targetMonitor); throw AutomationError(code: .interactionRequired) }
        guard let selected = controllers.first(where: { $0.registeredWindowID == monitor.selectedID }) else { RegisteredAdmissionDiagnostic.check(false, .targetSelected); throw AutomationError(code: .interactionRequired) }
        return (selected, monitor)
    }

    #if SAFARIER_REGISTERED_TAB_TESTS
    func makeRegisteredTestController() -> BrowserWindowController {
        makeNewWindowController(configuration: nil)
    }
    @discardableResult func setRegisteredPolicyTestTarget(_ controller: BrowserWindowController, monitor: RegisteredTabMonitor, lease: RegisteredPresentationLease? = nil) -> UUID {
        guard let window = controller.window as? NonActivatingBrowserWindow else { preconditionFailure("test window type") }
        let generation = UUID()
        registeredControl = (generation, controller, lease ?? RegisteredPresentationLease(window: window), monitor)
        executionPolicy = .automationBackground
        return generation
    }
    #endif

    func registeredTargetValid(_ controller: BrowserWindowController, monitor: RegisteredTabMonitor?) -> Bool {
        guard controller.session === self, controllers.contains(where: { $0 === controller }) else { return false }
        if let monitor { return monitor.selectedID == controller.registeredWindowID && monitor.matches(windows: registeredWindows()) && monitor.isValid() }
        return controllers.count == 1 && controllers.first === controller
    }

    static func waitForRegisteredInitialLoad(deadline: ContinuousClock.Instant,
        validate: @MainActor () async throws -> Void, ready: @MainActor () -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            try await validate()
            guard RegisteredAdmissionDiagnostic.check(ContinuousClock.now < deadline, .loadingDeadline) else { throw AutomationError(code: .interactionRequired) }
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Invoked only after the registered target has been authenticated by the
    /// caller. A fresh generation prevents an old callback restoring a new one.
    func beginRegisteredControl(controller: BrowserWindowController, monitor: RegisteredTabMonitor?, generation: UUID) throws -> UUID {
        guard executionPolicy == .interactive, registeredControl == nil,
              !manualHandoffPending, !boundCleanupUnconfirmed,
              registeredTargetValid(controller, monitor: monitor),
              controller.session === self, onAutomationUIBlocked == nil else {
            RegisteredAdmissionDiagnostic.check(false, .sessionLease)
            throw AutomationError(code: .interactionRequired)
        }
        let state = try controller.beginRegisteredControl(allowTabGroup: monitor != nil)
        registeredControl = (generation, controller, state, monitor)
        executionPolicy = .automationBackground
        return generation
    }

    func registeredPresentationValid(controller: BrowserWindowController, generation: UUID) -> Bool {
        guard let current = registeredControl, current.generation == generation,
              current.controller === controller, registeredTargetValid(controller, monitor: current.monitor),
              controller.session === self, current.state.window === controller.window,
              executionPolicy == .automationBackground else { return false }
        return BrowserWindowController.registeredPresentationValid(window: controller.window,
            webView: controller.webView, leaseID: current.state.id)
    }

    /// Restore only after the exact native lease has confirmed release. Any
    /// failure leaves the generation blocked rather than claiming a handoff.
    func quiesceAndRestoreRegisteredControl(controller: BrowserWindowController,
                                             generation: UUID,
                                             input: NativePageInput) async -> Bool {
        guard let registeredControl, registeredControl.generation == generation,
              registeredControl.controller === controller, controller.session === self,
              input.window === controller.window, input.webView === controller.webView,
              executionPolicy == .automationBackground else { return false }
        input.closeActivity()
        do { try await input.waitUntilClosed() } catch { return false }
        return restoreRegisteredControl(controller: controller, generation: generation, input: input)
    }

    func presentRegisteredControl(controller: BrowserWindowController, generation: UUID, input: NativePageInput) throws {
        guard registeredInitialPresentationConfirmed,
              let current = registeredControl, current.generation == generation,
              current.controller === controller, registeredTargetValid(controller, monitor: current.monitor),
              controller.session === self, executionPolicy == .automationBackground,
              input.window === controller.window, input.webView === controller.webView,
              input.registeredPresentationNotStarted else { throw AutomationError(code: .targetChanged) }
        let confirmed = current.state.present()
        controller.traceRegisteredPresentation("attachShown", confirmed: confirmed)
        guard RegisteredAdmissionDiagnostic.check(confirmed, .presentation) else { throw AutomationError(code: .interactionRequired) }
    }

    func restoreRegisteredControl(controller: BrowserWindowController, generation: UUID,
                                  input: NativePageInput) -> Bool {
        fputs("RELEASE_DIAG phase=session.restore.before monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000)\n", stderr)
        guard let current = self.registeredControl, current.generation == generation,
              current.controller === controller, controllers.contains(where: { $0 === controller }), executionPolicy == .automationBackground,
              controller.restoreRegisteredControl(current.state, input: input) else { return false }
        current.monitor?.stop()
        fputs("RELEASE_DIAG phase=session.monitor.stopped monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000)\n", stderr)
        controller.webView.navigationDelegate = controller
        controller.webView.uiDelegate = controller
        controller.onAutomationNavigation = nil
        onAutomationUIBlocked = nil
        executionPolicy = .interactive
        self.registeredControl = nil
        fputs("RELEASE_DIAG phase=session.restore.after monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000)\n", stderr)
        return true
    }

    func enableRetainedManualInteraction(controller: BrowserWindowController) -> Bool {
        guard executionPolicy == .automationBackground,
              controllers.count == 1, controllers[0] === controller,
              controller.session === self, NSApp.isRunning, !NSApp.isActive,
              !controller.window.isKeyWindow, !controller.window.isMainWindow,
              controller.webView.window === controller.window else { return false }
        let originalPolicy = NSApp.activationPolicy()
        guard NSApp.setActivationPolicy(.regular), !NSApp.isActive else { return false }
        guard !controller.window.isKeyWindow, !controller.window.isMainWindow else {
            _ = NSApp.setActivationPolicy(originalPolicy)
            return false
        }
        guard controller.enableRetainedManualInteraction() else {
            _ = NSApp.setActivationPolicy(originalPolicy)
            return false
        }
        controller.webView.navigationDelegate = controller
        controller.webView.uiDelegate = controller
        controller.onAutomationNavigation = nil
        onAutomationUIBlocked = nil
        manualHandoffPending = true
        executionPolicy = .interactive
        NSApp.mainMenu = BrowserMenu.make()
        return controller.webView.navigationDelegate === controller &&
            controller.webView.uiDelegate === controller && executionPolicy == .interactive
    }

    func confirmRetainedControlFinished() {
        guard manualHandoffPending, executionPolicy == .interactive else { return }
        manualHandoffPending = false
        if controllers.isEmpty { NSApp.terminate(nil) }
    }
    #endif

    /// The fixed admission gate must run before creating any window or WebView.
    func makeAutomationPage(runnerInstanceID: UUID) async throws -> OwnedBrowserAutomationPage {
        try NativePageInput.requireShippingAdmission()
        guard executionPolicy == .automationBackground, controllers.isEmpty else { throw AutomationError(code: .backgroundLaunchUnverified) }
        let controller = makeNewWindowController(configuration: nil)
        controller.window.tabbingMode = .disallowed
        controller.window.ignoresMouseEvents = true
        controller.window.orderOut(nil)
        controller.updateState()
        controller.window.contentView?.layoutSubtreeIfNeeded()
        do {
            return try await OwnedBrowserAutomationPage.attach(session: self, controller: controller, runnerInstanceID: runnerInstanceID)
        } catch {
            // This is the controller allocated above, not a discovered or foreign window.
            controller.webView.stopLoading()
            controller.webView.navigationDelegate = nil
            controller.webView.uiDelegate = nil
            controller.window.delegate = nil
            controller.window.orderOut(nil)
            controller.window.close()
            controllerClosed(controller)
            throw error
        }
    }

    /// Composition only. Background profile/proxy/configuration preparation
    /// and real admission remain future gated prerequisites.
    func makeAutomationService(workspace: SafarierWorkspace, runnerInstanceID: UUID) throws -> RunnerAutomationService {
        try NativePageInput.requireShippingAdmission()
        guard executionPolicy == .automationBackground else { throw AutomationError(code: .backgroundLaunchUnverified) }
        let profileID = profile.id
        let root = workspace.root
        return RunnerAutomationService(profileID: profileID, runnerInstanceID: runnerInstanceID, permissionReader: {
            await RunnerAutomationService.repositoryPermission(profileID: profileID, root: root)
        }, pageFactory: { [weak self] in
            guard let self, self.executionPolicy == .automationBackground, self.profile.id == profileID else { throw AutomationError(code: .targetChanged) }
            return try await self.makeAutomationPage(runnerInstanceID: runnerInstanceID)
        }, snapshotFactory: {
            try AutomationSnapshotStore(workspaceRoot: root)
        })
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func makeBoundAutomationPage(context: RunnerBinderContext) async throws -> OwnedBrowserAutomationPage {
        try await context.validate()
        guard profile.id == context.profileID, executionPolicy == .automationBackground,
              controllers.isEmpty else { throw AutomationError(code: .targetChanged) }
        _ = try context.localFixtureURL()
        try context.checkLive()
        #if SAFARIER_WHEEL_OBSERVER_PROBE
        func checkObserverConfigurationOwner() throws {
            try context.checkLive()
            guard !Task.isCancelled, profile.id == context.profileID, executionPolicy == .automationBackground,
                  controllers.isEmpty, let app = NSApp, app.activationPolicy() == .prohibited, !app.isActive,
                  app.windows.allSatisfy({ !$0.isVisible && !$0.isKeyWindow && !$0.isMainWindow }) else {
                throw AutomationError(code: .targetChanged)
            }
        }
        try checkObserverConfigurationOwner()
        try await context.validate()
        try checkObserverConfigurationOwner()
        let observerFixture = try context.localFixtureURL()
        try BoundWheelObserverProbe.configure(configuration, fixture: observerFixture)
        try checkObserverConfigurationOwner()
        try await context.validate()
        try checkObserverConfigurationOwner()
        #endif
        let controller = makeNewWindowController(configuration: nil, nonActivating: true)
        controller.window.tabbingMode = .disallowed
        controller.window.ignoresMouseEvents = true
        controller.window.orderOut(nil)
        controller.updateState()
        controller.window.contentView?.layoutSubtreeIfNeeded()
        do {
            guard !controller.window.canBecomeKey, !controller.window.canBecomeMain else { throw AutomationError(code: .uiPolicyUnavailable) }
            return try await OwnedBrowserAutomationPage.attachBound(session: self, controller: controller, context: context)
        } catch {
            // A failed attach may have started native activity; never treat its
            // best-effort destruction as proof that the lock can be returned.
            boundCleanupUnconfirmed = true
            controller.webView.stopLoading()
            controller.webView.navigationDelegate = nil
            controller.webView.uiDelegate = nil
            controller.window.delegate = nil
            controller.window.orderOut(nil)
            controller.window.close()
            controllerClosed(controller)
            throw error
        }
    }

    func makeBoundAutomationService(workspace: SafarierWorkspace, context: RunnerBinderContext) throws -> RunnerAutomationService {
        try context.checkLive()
        guard executionPolicy == .automationBackground, profile.id == context.profileID else { throw AutomationError(code: .profileNotAllowed) }
        let profileID = profile.id, root = workspace.root
        return RunnerAutomationService(profileID: profileID, runnerInstanceID: context.runnerInstanceID, permissionReader: {
            do {
                try await context.validatePermissionFirst()
                let allowed = await RunnerAutomationService.repositoryPermission(profileID: profileID, root: root)
                try await context.validatePermissionSecond()
                return allowed
            } catch { return false }
        }, pageFactory: { [weak self] in
            try await context.validate()
            guard let self, self.profile.id == profileID else { throw AutomationError(code: .targetChanged) }
            return try await self.makeBoundAutomationPage(context: context)
        }, snapshotFactory: { try AutomationSnapshotStore(workspaceRoot: root) },
           cleanupVerifier: { [weak self] in self.map { !$0.boundCleanupUnconfirmed } ?? false },
           localCandidate: true)
    }
    #endif

    // MARK: - 窗口与标签

    func start(url: URL?) {
        guard allowUI(.start) else { return }
        if let tabSessionStore, executionPolicy == .interactive, profile.mode == .persistent,
           let saved = try? tabSessionStore.load(),
           saved.windows.contains(where: { !$0.tabs.isEmpty }) {
            restoreSession(saved, explicitURL: url)
            return
        }
        let controller = openWindow(url: url)
        controller.window.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreSession(_ saved: SavedSession, explicitURL: URL?) {
        let validWindows = saved.windows.filter { !$0.tabs.isEmpty }
        guard !validWindows.isEmpty else {
            let controller = openWindow(url: explicitURL)
            controller.window.center()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        isRestoringSession = true
        defer {
            isRestoringSession = false
        }

        var firstController: BrowserWindowController?

        for (windowIndex, windowConfig) in validWindows.enumerated() {
            var hostController: BrowserWindowController?
            var tabsInWindow: [BrowserWindowController] = []

            for (tabIndex, tabConfig) in windowConfig.tabs.enumerated() {
                if tabIndex == 0 {
                    let controller = openWindow(url: tabConfig.url)
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
                    fputs("REGISTERED_RESTORE_DIAG phase=tab.restored monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) windowOrdinal=\(windowIndex) tabOrdinal=\(tabIndex) windowID=\(controller.registeredWindowID.uuidString) pageID=\(controller.registeredPageID.uuidString) urlPresent=\(tabConfig.url != nil)\n", stderr)
                    #endif
                    hostController = controller
                    tabsInWindow.append(controller)
                    if firstController == nil { firstController = controller }
                } else if let host = hostController {
                    let anchor = tabsInWindow.last ?? host
                    let controller = openTab(in: host, attachTo: anchor, url: tabConfig.url, background: true)
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
                    fputs("REGISTERED_RESTORE_DIAG phase=tab.restored monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) windowOrdinal=\(windowIndex) tabOrdinal=\(tabIndex) windowID=\(controller.registeredWindowID.uuidString) pageID=\(controller.registeredPageID.uuidString) urlPresent=\(tabConfig.url != nil)\n", stderr)
                    #endif
                    tabsInWindow.append(controller)
                }
            }

            if let host = hostController, !tabsInWindow.isEmpty {
                let targetIndex = (windowConfig.selectedTabIndex >= 0 && windowConfig.selectedTabIndex < tabsInWindow.count)
                    ? windowConfig.selectedTabIndex
                    : 0
                let selectedWindow = tabsInWindow[targetIndex].window
                host.window.tabGroup?.selectedWindow = selectedWindow
            }
        }

        let explicitController: BrowserWindowController?
        if let explicitURL, explicitURL != profile.startURL {
            let host = frontmostController ?? firstController
            let controller = openTab(in: host, url: explicitURL, background: false)
            explicitController = controller
            #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
            fputs("REGISTERED_RESTORE_DIAG phase=tab.explicit monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) windowID=\(controller.registeredWindowID.uuidString) pageID=\(controller.registeredPageID.uuidString)\n", stderr)
            #endif
        } else { explicitController = nil }

        if let explicitController {
            explicitController.window.tabGroup?.selectedWindow = explicitController.window
            explicitController.window.makeKeyAndOrderFront(nil)
        } else if let firstWindowConfig = validWindows.first, let firstHost = firstController {
            let targetIndex = (firstWindowConfig.selectedTabIndex >= 0 && firstWindowConfig.selectedTabIndex < (firstHost.window.tabGroup?.windows.count ?? 1)) ? firstWindowConfig.selectedTabIndex : 0
            if let tabWindows = firstHost.window.tabGroup?.windows, targetIndex < tabWindows.count {
                tabWindows[targetIndex].makeKeyAndOrderFront(nil)
            } else if let tabbed = firstHost.window.tabbedWindows, targetIndex < tabbed.count {
                tabbed[targetIndex].makeKeyAndOrderFront(nil)
            } else {
                firstHost.window.makeKeyAndOrderFront(nil)
            }
        } else if let front = frontmostController ?? firstController {
            front.window.makeKeyAndOrderFront(nil)
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        let selectedWindow = firstController?.window.tabGroup?.selectedWindow ?? firstController?.window
        let selectedController = controllers.first { $0.window === selectedWindow }
        fputs("REGISTERED_RESTORE_DIAG phase=selection.final monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) selectedPresent=\(selectedController != nil) windowID=\(selectedController?.registeredWindowID.uuidString ?? "none") pageID=\(selectedController?.registeredPageID.uuidString ?? "none")\n", stderr)
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    // These nonoptional primitives are interactive-only. Every existing external callsite
    // is gated; background creation remains unsupported by the factory and these primitives.
    /// 新窗口。`configuration` 来自网页的 window.open（必须用它，opener 关系才在）；`contentSize` 是弹窗要求的尺寸。
    @discardableResult
    func openWindow(url: URL?, configuration popupConfiguration: WKWebViewConfiguration? = nil, contentSize: NSSize? = nil) -> BrowserWindowController {
        // 级联的参照窗口要在新窗口建出来之前取；当前是源代码窗口时退回最前面的浏览窗口，一个都没有就居中。
        let anchor = (keyController ?? frontmostController)?.window
        let controller = contentSize.map { makeController(configuration: popupConfiguration, contentSize: $0) }
            ?? makeNewWindowController(configuration: popupConfiguration)
        if let anchor {
            controller.window.setFrameTopLeftPoint(anchor.cascadeTopLeft(from: NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY)))
        } else {
            controller.window.center()
        }
        // 系统设置「首选标签页打开文稿」为「始终」时，.automatic 会把新窗口并进当前窗口当标签：
        // 显示前临时禁止合并，显示后恢复（⌘T、拖动合并、合并所有窗口照常），⌘N 永远是独立窗口。
        controller.window.tabbingMode = .disallowed
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.tabbingMode = .automatic
        show(controller, url: url, popup: popupConfiguration != nil, background: false)
        scheduleDebouncedSaveSessionState()
        return controller
    }

    /// 在 `host` 所在窗口里加一个标签。`background` 为 true 时不切过去（⌘点按链接）。
    @discardableResult
    func openTab(in host: BrowserWindowController?, attachTo: BrowserWindowController? = nil, url: URL?, configuration popupConfiguration: WKWebViewConfiguration? = nil, background: Bool = false) -> BrowserWindowController {
        guard let host else { return openWindow(url: url, configuration: popupConfiguration) }
        let controller = makeController(configuration: popupConfiguration, contentSize: host.window.contentLayoutRect.size)
        let anchorWindow = attachTo?.window ?? host.window
        anchorWindow.addTabbedWindow(controller.window, ordered: .above)
        // 显式设选中的标签：后台打开时留在原标签，前台打开时切到新标签。
        host.window.tabGroup?.selectedWindow = background ? host.window : controller.window
        if background {
            host.window.makeKeyAndOrderFront(nil)
        } else {
            controller.window.makeKeyAndOrderFront(nil)
        }
        show(controller, url: url, popup: popupConfiguration != nil, background: background)
        scheduleDebouncedSaveSessionState()
        return controller
    }

    /// 网页打开的视图（window.open、target=_blank、右键「在新标签页 / 新窗口中打开」）由 WebKit 自己载入：
    /// 不显示起始页，也不把焦点交给地址栏（否则地址栏停在空白编辑状态，后台标签切过去时还会被抢焦点）。
    private func show(_ controller: BrowserWindowController, url: URL?, popup: Bool, background: Bool) {
        guard popup else { return controller.load(url) }
        controller.updateState()
        if !background { controller.window.makeFirstResponder(controller.webView) }
    }

    private func makeController(configuration popupConfiguration: WKWebViewConfiguration?, contentSize: NSSize, nonActivating: Bool = false) -> BrowserWindowController {
        let webView = makeWebView(configuration: popupConfiguration)
        let controller = BrowserWindowController(session: self, webView: webView, contentSize: contentSize, isPopup: popupConfiguration != nil, nonActivating: nonActivating)
        if let deviceSimulation {
            let state = deviceSimulation.apply(to: webView)
            if !reportPrinted { report.set(state, for: .deviceModel) }
        }
        if !reportPrinted {
            reportPrinted = true
            for line in report.lines() { print("[capability] \(line)") }
        }
        controllers.append(controller)
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        registeredControl?.monitor?.invalidate()
        #endif
        if !downloads.items.isEmpty { controller.downloadsChanged() }
        return controller
    }

    private func makeWebView(configuration popupConfiguration: WKWebViewConfiguration?) -> BrowserWebView {
        let webView = BrowserWebView(frame: NSRect(origin: .zero, size: Self.defaultContentSize), configuration: popupConfiguration ?? configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = inspectable
        return webView
    }

    static func defaultWindowFrameSize(screen: NSSize?) -> NSSize {
        let preferred = NSSize(width: 1600, height: 1200)
        guard let screen, screen.width >= preferred.width, screen.height >= preferred.height else {
            return NSSize(width: 1280, height: 800)
        }
        return preferred
    }

    static func applyDefaultWindowFrameSize(_ size: NSSize, to window: NSWindow) {
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
    }

    private func makeNewWindowController(configuration: WKWebViewConfiguration?, nonActivating: Bool = false) -> BrowserWindowController {
        let sizing = newWindowContentSize()
        let controller = makeController(configuration: configuration, contentSize: sizing.content, nonActivating: nonActivating)
        if let frame = sizing.frame { Self.applyDefaultWindowFrameSize(frame, to: controller.window) }
        return controller
    }

    /// 机型和现有窗口沿用内容区；默认窗口在工具栏建好后按外框调整。
    private func newWindowContentSize() -> (content: NSSize, frame: NSSize?) {
        if let device {
            let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? device.viewportSize
            // 统一工具栏 52pt：和 Safari 实测一致（outerHeight − innerHeight = 52，单标签）。
            let available = CGSize(width: screen.width, height: screen.height - BrowserWindowController.chromeHeight)
            let viewport = device.viewport(fitting: available)
            let scaled = viewport == device.viewportSize ? "" : "（屏幕放不下，按比例缩小）"
            print("[device] \(device.name)：视口 \(Int(viewport.width))×\(Int(viewport.height))\(scaled)")
            return (viewport, nil)
        }
        if let key = NSApp.keyWindow, let controller = controllers.first(where: { $0.window === key }) {
            return (controller.window.contentLayoutRect.size, nil)
        }
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size
        return (Self.defaultContentSize, Self.defaultWindowFrameSize(screen: screen))
    }

    /// 还开着的标签（测试和诊断用）。
    var openControllers: [BrowserWindowController] { controllers }

    private(set) var isClosingWindow = false

    func beginClosingWindow() {
        isClosingWindow = true
    }

    func endClosingWindow() {
        isClosingWindow = false
    }

    func controllerClosed(_ controller: BrowserWindowController) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        registeredControl?.monitor?.invalidate()
        #endif
        controllers.removeAll { $0 === controller }
        if controllers.isEmpty {
            isClosingWindow = false
            cancelPendingSaveSessionState()
        } else if !isClosingWindow {
            scheduleDebouncedSaveSessionState()
        }
    }

    // MARK: - 标签页会话持久化与恢复

    func snapshotOpenWindows() -> [SavedSessionWindow] {
        var seenWindowIDs = Set<ObjectIdentifier>()
        var savedWindows: [SavedSessionWindow] = []

        var orderedWindows: [NSWindow] = []
        if !NSApp.orderedWindows.isEmpty {
            for win in NSApp.orderedWindows {
                if controllers.contains(where: { $0.window === win }) {
                    orderedWindows.append(win)
                }
            }
        }
        for controller in controllers where !orderedWindows.contains(where: { $0 === controller.window }) {
            orderedWindows.append(controller.window)
        }

        for window in orderedWindows {
            let winID = ObjectIdentifier(window)
            if seenWindowIDs.contains(winID) { continue }

            let tabWindows = window.tabbedWindows ?? (window.tabGroup?.windows ?? [window])
            for tw in tabWindows {
                seenWindowIDs.insert(ObjectIdentifier(tw))
            }

            let tabGroup = window.tabGroup
            let activeWindow = tabGroup?.selectedWindow ?? (window.isKeyWindow ? window : tabWindows.first)

            var savedTabs: [SavedTab] = []
            var selectedIndex = 0

            for (index, tabWindow) in tabWindows.enumerated() {
                if tabWindow === activeWindow {
                    selectedIndex = index
                }
                if let tabController = controllers.first(where: { $0.window === tabWindow }) {
                    savedTabs.append(SavedTab(url: tabController.displayURL, title: tabController.window.title))
                }
            }

            if !savedTabs.isEmpty {
                savedWindows.append(SavedSessionWindow(tabs: savedTabs, selectedTabIndex: selectedIndex))
            }
        }
        return savedWindows
    }

    func saveSessionState() {
        guard let tabSessionStore, executionPolicy == .interactive, profile.mode == .persistent, !isRestoringSession, !isClosingWindow else { return }
        let windows = snapshotOpenWindows()
        guard !windows.isEmpty else { return }
        try? tabSessionStore.save(SavedSession(windows: windows, updatedAt: Date()))
    }

    func scheduleDebouncedSaveSessionState(delay: TimeInterval = 0.25) {
        guard tabSessionStore != nil, executionPolicy == .interactive, profile.mode == .persistent, !isRestoringSession else { return }
        guard !controllers.isEmpty else {
            cancelPendingSaveSessionState()
            return
        }
        saveSessionTimer?.invalidate()
        saveSessionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.controllers.isEmpty else { return }
                self.saveSessionState()
            }
        }
    }

    func cancelPendingSaveSessionState() {
        saveSessionTimer?.invalidate()
        saveSessionTimer = nil
    }

    func tabStateChanged() {
        scheduleDebouncedSaveSessionState()
    }

    func tabSelectionChanged() {
        scheduleDebouncedSaveSessionState()
    }

    // MARK: - 最近关闭的标签

    /// 标签关闭时记下它的网址（起始页、about: 不记），最多留 `closedTabLimit` 个。
    func recordClosedTab(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme != "about" else { return }
        closedTabURLs.append(url)
        if closedTabURLs.count > Self.closedTabLimit { closedTabURLs.removeFirst(closedTabURLs.count - Self.closedTabLimit) }
    }

    /// ⇧⌘T：在 `host` 所在窗口（没有就是当前窗口，再没有就新建窗口）恢复最近关闭的标签。
    @discardableResult
    func reopenClosedTab(in host: BrowserWindowController?) -> BrowserWindowController? {
        guard allowUI(.reopen), let url = closedTabURLs.popLast() else { return nil }
        if let host = host ?? keyController ?? frontmostController {
            return openTab(in: host, url: url)
        }
        return openWindow(url: url)
    }

    private var keyController: BrowserWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return controllers.first { $0.window === key }
    }

    /// 最前面的浏览窗口（当前 key window 是源代码窗口等非浏览窗口时用它）；都不在屏幕上时取最后打开的。
    var frontmostController: BrowserWindowController? {
        for window in NSApp.orderedWindows {
            if let controller = controllers.first(where: { $0.window === window }) { return controller }
        }
        return controllers.last
    }

    // MARK: - 循环显示窗口

    /// 本环境可见的窗口组，从前到后。
    func windowGroups() -> [NSWindow] {
        // 源代码窗口也算本环境的窗口，⌘` 可以在它和浏览窗口之间切换。
        let mine = Set(controllers.map { ObjectIdentifier($0.window) } + sourceWindows.map { ObjectIdentifier($0.window) })
        return WindowCycler.groups(NSApp.orderedWindows.filter { mine.contains(ObjectIdentifier($0)) && $0.isVisible })
    }

    /// ⌘` / ⌘·：本环境有两个以上窗口时在它们之间轮换，否则切到别的 Safarier 进程（其它环境或管理器）。
    func cycleWindows(forward: Bool) {
        guard allowUI(.cycleWindow) else { return }
        let groups = windowGroups()
        if let target = WindowCycler.target(in: groups, forward: forward) {
            if !forward { groups.first?.orderBack(nil) }
            target.makeKeyAndOrderFront(nil)
        } else if !WindowCycler.activateOtherSafarier(forward: forward) {
            NSSound.beep()
        }
    }

    // MARK: - 页面源代码

    func showSource(_ source: String, title: String, url: URL?, relativeTo parent: NSWindow?) {
        guard allowUI(.openWindow) else { return }
        let controller = PageSourceWindowController(source: source, title: title, url: url)
        controller.onClose = { [weak self] closed in self?.sourceWindows.removeAll { $0 === closed } }
        sourceWindows.append(controller)
        controller.show(relativeTo: parent)
    }

    // MARK: - 没有窗口时的菜单动作

    @objc func newWindow(_ sender: Any?) { guard allowUI(.openWindow) else { return }; openWindow(url: nil) }
    /// 当前是源代码窗口时，⌘T / ⌘L 交给最前面的浏览窗口；一个浏览窗口都没有才新建窗口。
    @objc func newTab(_ sender: Any?) {
        guard allowUI(.openTab) else { return }
        if let host = frontmostController {
            openTab(in: host, url: nil)
        } else {
            openWindow(url: nil)
        }
    }
    @objc func focusLocation(_ sender: Any?) {
        guard allowUI(.openWindow) else { return }
        if let host = frontmostController {
            host.window.makeKeyAndOrderFront(nil)
            host.focusLocation(sender)
        } else {
            openWindow(url: nil)
        }
    }
    @objc func reopenClosedTab(_ sender: Any?) { reopenClosedTab(in: nil) }
    @objc func cycleWindowsForward(_ sender: Any?) { cycleWindows(forward: true) }
    @objc func cycleWindowsBackward(_ sender: Any?) { cycleWindows(forward: false) }

    /// 打开后右键菜单里有「检查元素」。对网页不可见。
    @objc func toggleInspectable(_ sender: Any?) {
        inspectable.toggle()
        controllers.forEach { $0.webView.isInspectable = inspectable }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleInspectable(_:)):
            item.state = inspectable ? .on : .off
            return true
        case #selector(reopenClosedTab(_:)):
            return !closedTabURLs.isEmpty
        case #selector(newWindow(_:)), #selector(newTab(_:)), #selector(focusLocation(_:)),
             #selector(cycleWindowsForward(_:)), #selector(cycleWindowsBackward(_:)):
            return true
        default:
            return false
        }
    }

    // MARK: - NSApplicationDelegate

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !controllers.isEmpty {
            saveSessionState()
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if manualHandoffPending { return false }
        #endif
        return executionPolicy == .interactive
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard allowUI(.reopen) else { return false }
        if !flag { openWindow(url: nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard promoteOnActivation, executionPolicy == .interactive else { return }
        promoteOnActivation = false
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelPendingSaveSessionState()
        if !controllers.isEmpty {
            saveSessionState()
        }
        if let workspace, profile.mode == .ephemeral {
            try? TabSessionStore(workspace: workspace, profileID: profile.id).clear()
        }
        RunnerMain.stopSingbox()
    }
}

extension BrowserSession: NSMenuItemValidation {}

extension BrowserSession: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView,
              let controller = (webView.window?.delegate as? BrowserWindowController) ??
                               controllers.first(where: { $0.webView === webView }) else { return }
        controller.handleAutofillScriptMessage(message)
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
