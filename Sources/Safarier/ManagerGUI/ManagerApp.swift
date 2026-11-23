import AppKit
import SwiftUI
import SafarierCore
#if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
import OSLog

@MainActor
private enum TestingLaunchTrace {
    static let logger = Logger(subsystem: "sh.safarier.testing", category: "launch")
}
#endif

/// Single Manager owner; windows and menus are created only for explicit human intent.
@MainActor
enum ManagerGUI {
    nonisolated static func migrationAlertMessage(for error: Error, quietStart: Bool) -> String? {
        guard !quietStart, let migrationError = error as? WorkspaceMigrationError else { return nil }
        return """
        \(migrationError)

        关闭所有旧版 Manager、Runner、CLI，并确保以后不再打开旧版。确认只有旧工作区时，使用新版 sfa 执行：
        sfa workspace migrate --confirm-old-versions-stopped-and-will-not-reopen

        若新旧工作区同时存在，请保留两份并先人工处理，不要合并。详见工作区迁移文档。
        """
    }
    static func start() -> Never {
        let quietStart = CommandLine.arguments.dropFirst().contains(ExecutableRole.nonActivatingManagerArgument)
        let workspace: SafarierWorkspace
        do { workspace = try SafarierWorkspace.default() }
        catch {
            ManagerCLI.printError("无法打开元数据目录：\(error)")
            if let message = migrationAlertMessage(for: error, quietStart: quietStart) {
                showMigrationFailureWhenInteractive(message)
            }
            exit(1)
        }
        let app = NSApplication.shared
        let bundled = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        if bundled || quietStart { app.setActivationPolicy(.accessory) }
        let delegate = ManagerAppDelegate(workspace: workspace, quietStart: quietStart)
        app.delegate = delegate
        ManagerAutomationHooks.willHandleRequest = { [weak delegate] in delegate?.recordAutomation() }
        ManagerAutomationHooks.pendingCommandCountDidChange = { [weak delegate] in delegate?.pendingCountDidChange() }
        ManagerAutomationHooks.handleRequest = { [weak delegate] request, role, proof, uid in
            guard let delegate else { return await AutomationScriptService.handle(request, role: role, proof: proof, currentUID: uid) }
            return await delegate.automationManager.handle(request, role: role, proof: proof, currentUID: uid)
        }
        ManagerAutomationHooks.pendingAutomationWork = { [weak delegate] in delegate?.automationManager.pendingWorkCount ?? 0 }
        ManagerAutomationHooks.shutdownAutomation = { [weak delegate] in delegate?.automationManager.shutdown() }
        ManagerAutomationHooks.profilePermissionsChanged = { [weak delegate] allowed in delegate?.automationManager.profilePermissionsChanged(allowedProfileIDs: allowed) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        ManagerAutomationHooks.launchRegisteredInteractive = { [weak delegate] profile, spawner in
            guard let delegate else { throw AutomationError(code: .runnerExited) }
            try delegate.automationManager.launchRegisteredInteractive(profile, spawner: spawner, workspace: workspace)
        }
        #endif
        delegate.automationManager.onPendingWorkChanged = { [weak delegate] in delegate?.pendingCountDidChange() }
        if quietStart { delegate.recordInteractiveWithoutActivation() }
        else if !bundled { delegate.recordInteractive() }
        app.run()
        withExtendedLifetime(delegate) {}
        exit(0)
    }

    private static func showMigrationFailureWhenInteractive(_ message: String) {
        let app = NSApplication.shared
        let bundled = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        if bundled { app.setActivationPolicy(.accessory) }
        let delegate = ManagerMigrationFailureDelegate(message: message)
        app.delegate = delegate
        if !bundled { delegate.recordInteractive() }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class ManagerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let workspace: SafarierWorkspace
    private let hostService: ManagerHostDaemonService
    let automationManager: AutomationManager
    private var state = ManagerLaunchState()
    private var model: ManagerModel?
    private var window: NSWindow?
    private var menu: ManagerMenu?
    private var keyMonitor: Any?
    private var promoteOnActivation: Bool
    private let windowSize = ManagerWindowSize()
    private var normalWindowSize: ManagerNormalWindowSize?
    private var windowWasClosed = false
    private var hostTerminationPending = false
    private var systemTerminationWaitingOnExplicitExit = false
    private var explicitExitTerminationApproved = false
    private var explicitExitState = ManagerExplicitExitState()

    init(workspace: SafarierWorkspace, quietStart: Bool = false) {
        self.workspace = workspace
        self.hostService = ManagerHostDaemonService()
        self.automationManager = .shipping(workspace: workspace)
        self.promoteOnActivation = quietStart
        super.init()
    }
    func installEventHandlers() {
        let events = NSAppleEventManager.shared()
        // ascr/noop and aevt/oapp,rapp; these are public Apple Event codes.
        events.setEventHandler(self, andSelector: #selector(automationEvent(_:withReplyEvent:)), forEventClass: 0x61736372, andEventID: 0x6e6f6f70)
        events.setEventHandler(self, andSelector: #selector(openEvent(_:withReplyEvent:)), forEventClass: 0x61657674, andEventID: 0x6f617070)
        events.setEventHandler(self, andSelector: #selector(interactiveEvent(_:withReplyEvent:)), forEventClass: 0x61657674, andEventID: 0x72617070)
    }
    @objc private func automationEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) { recordAutomation() }
    @objc private func interactiveEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) { recordInteractive() }
    @objc private func openEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        handleLaunchEvent(.openApplication)
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        installEventHandlers()
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        TestingLaunchTrace.logger.notice("phase=handlers_installed running=\(NSApp.isRunning, privacy: .public) policy=\(NSApp.activationPolicy().rawValue, privacy: .public) finished=\(NSRunningApplication.current.isFinishedLaunching, privacy: .public)")
        #endif
    }
    func recordAutomation() { handleLaunchEvent(.automation) }
    func recordInteractive() { handleLaunchEvent(.interactive) }
    func recordInteractiveWithoutActivation() { handleLaunchEvent(.interactiveWithoutActivation) }
    func applicationDidBecomeActive(_ notification: Notification) {
        if promoteOnActivation { promoteOnActivation = false; NSApp.setActivationPolicy(.regular) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { handleLaunchEvent(.finishedLaunching) }
    private func handleLaunchEvent(_ event: ManagerLaunchEvent) {
        let effects = state.handle(event)
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        let name: String
        switch event {
        case .automation: name = "automation"
        case .interactive: name = "interactive"
        case .interactiveWithoutActivation: name = "interactiveWithoutActivation"
        case .openApplication: name = "openApplication"
        case .finishedLaunching: name = "finished"
        default: name = "other"
        }
        TestingLaunchTrace.logger.notice("phase=reducer event=\(name, privacy: .public) showManager=\(effects.contains(.showManager), privacy: .public) running=\(NSApp.isRunning, privacy: .public) finished=\(NSRunningApplication.current.isFinishedLaunching, privacy: .public)")
        #endif
        apply(effects)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        recordInteractive()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if explicitExitTerminationApproved {
            explicitExitTerminationApproved = false
            let pending = ManagerAutomationHooks.combinedPendingWork
            guard pending == 0 else {
                hostService.resumeAfterCancelledExplicitExit()
                showPendingWorkExitRefusal(pending)
                return .terminateCancel
            }
            return .terminateNow
        }
        if hostTerminationPending { return .terminateLater }
        if explicitExitState.isShutdownInFlight {
            systemTerminationWaitingOnExplicitExit = true
            return .terminateLater
        }
        let effects = state.handle(.quitRequested(pendingCommands: ManagerAutomationHooks.combinedPendingWork))
        if effects.contains(.deferTermination) {
            if effects.contains(.cancelPending) {
                // The system must receive terminateLater before deferred command
                // resumes or the final reply-to-termination can be delivered.
                DispatchQueue.main.async { [weak self] in
                    ManagerAutomationHooks.cancelPending()
                    self?.pendingCountDidChange()
                }
            }
            return .terminateLater
        }
        if effects.contains(.cancelPending) { ManagerAutomationHooks.cancelPending() }
        if effects.contains(.terminate), hostService.needsTerminationCheck {
            beginHostTerminationReply()
            return .terminateLater
        }
        return .terminateNow
    }
    func pendingCountDidChange() {
        apply(state.handle(.pendingCommandsChanged(ManagerAutomationHooks.combinedPendingWork)))
    }
    func applicationWillTerminate(_ notification: Notification) {
        DshService.shared.stop()
        saveManagerWindowSize()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        ManagerAutomationHooks.willHandleRequest = nil
        ManagerAutomationHooks.pendingCommandCountDidChange = nil
        ManagerAutomationHooks.pendingCommandCount = nil
        ManagerAutomationHooks.cancelPendingCommands = nil
        ManagerAutomationHooks.handleRequest = nil
        ManagerAutomationHooks.pendingAutomationWork = nil
        ManagerAutomationHooks.shutdownAutomation = nil
        ManagerAutomationHooks.profilePermissionsChanged = nil
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        ManagerAutomationHooks.launchRegisteredInteractive = nil
        #endif
        automationManager.onPendingWorkChanged = nil
        automationManager.shutdown()
    }
    private func saveManagerWindowSize() {
        guard let window, !windowWasClosed else { return }
        observeManagerWindowSize(window)
        if let normalWindowSize { windowSize.save(normalWindowSize.size) }
    }
    private func observeManagerWindowSize(_ window: NSWindow) {
        normalWindowSize?.observe(window.frame.size, fullScreen: window.styleMask.contains(.fullScreen), miniaturized: window.isMiniaturized)
    }
    func windowWillClose(_ notification: Notification) {
        saveManagerWindowSize()
        windowWasClosed = true
        _ = state.handle(.windowClosed(pendingCommands: ManagerAutomationHooks.combinedPendingWork))
    }
    func windowWillEnterFullScreen(_ notification: Notification) { normalWindowSize?.changingFullScreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { normalWindowSize?.changingFullScreen = false }
    func windowWillExitFullScreen(_ notification: Notification) { normalWindowSize?.changingFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        normalWindowSize?.changingFullScreen = false
        if let window { observeManagerWindowSize(window) }
    }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        observeManagerWindowSize(window)
    }
    private func apply(_ effects: [ManagerLaunchEffect]) {
        for effect in effects {
            switch effect {
            case .showManager: showManager()
            case .showManagerWithoutActivation: showManager(activate: false)
            case .terminate: NSApp.terminate(nil)
            case .cancelPending: ManagerAutomationHooks.cancelPending()
            case .replyToTermination: beginHostTerminationReply()
            case .deferTermination: break
            }
        }
    }
    private func showManager(activate: Bool = true) {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        TestingLaunchTrace.logger.notice("phase=show_enter windowExists=\(self.window != nil, privacy: .public) policy=\(NSApp.activationPolicy().rawValue, privacy: .public)")
        #endif
        if window == nil {
            let model = ManagerModel(workspace: workspace, hostService: hostService)
            self.model = model
            let content = NSHostingController(rootView: SafarierAppView(model: model).frame(minWidth: 920, minHeight: 580))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Safarier AI"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = nil
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.minSize = NSSize(width: 920, height: 580)
            window.isReleasedWhenClosed = false
            window.contentViewController = content
            let size = ManagerWindowSize.resolve(windowSize.load(), screen: NSScreen.main?.visibleFrame.size)
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            window.center()
            self.window = window
            normalWindowSize = ManagerNormalWindowSize(size: window.frame.size)
            window.delegate = self
            let menu = ManagerMenu(
                model: model,
                onClosePanel: { [weak self] in self?.closeManagerPanel() },
                onExplicitExit: { [weak self] in self?.requestExplicitExit() },
                explicitExitInFlight: { [weak self] in
                    guard let self else { return true }
                    return explicitExitState.isShutdownInFlight || hostTerminationPending
                }
            )
            self.menu = menu; NSApp.mainMenu = menu.make()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let forward = WindowCycler.direction(for: event), !(forward && event.charactersIgnoringModifiers == "`") else { return event }
                MainActor.assumeIsolated { if !WindowCycler.activateOtherSafarier(forward: forward) { NSSound.beep() } }
                return nil
            }
        }
        if windowWasClosed, let window {
            let screen = window.screen ?? NSScreen.main
            let size = ManagerWindowSize.resolve(windowSize.load(), screen: screen?.visibleFrame.size)
            var frame = NSRect(origin: window.frame.origin, size: size)
            if let screen { frame = window.constrainFrameRect(frame, to: screen) }
            window.setFrame(frame, display: false)
            normalWindowSize = ManagerNormalWindowSize(size: window.frame.size)
            windowWasClosed = false
        }
        if activate {
            promoteOnActivation = false
            NSApp.setActivationPolicy(.regular)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFront(nil)
        }
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        TestingLaunchTrace.logger.notice("phase=show_return visible=\(self.window?.isVisible ?? false, privacy: .public) key=\(self.window?.isKeyWindow ?? false, privacy: .public) main=\(self.window?.isMainWindow ?? false, privacy: .public) policy=\(NSApp.activationPolicy().rawValue, privacy: .public)")
        #endif
    }

    private func beginHostTerminationReply() {
        guard !hostTerminationPending else { return }
        hostTerminationPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await hostService.stopOwnedChildrenForTermination()
                guard !hostService.hasOwnedChildren else {
                    throw ManagerHostFailure.unavailable("至少一个 GUI-owned Host 子进程或 socket 尚未确认停止；Manager 保持运行。请查询状态后重试。")
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                hostTerminationPending = false
                _ = state.handle(.terminationCancelled)
                presentHostTerminationFailure(error)
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    private func closeManagerPanel() {
        window?.close()
    }

    private func requestExplicitExit() {
        guard !explicitExitState.isShutdownInFlight, !hostTerminationPending else { return }
        let pending = ManagerAutomationHooks.combinedPendingWork
        guard pending == 0 else {
            showPendingWorkExitRefusal(pending)
            return
        }

        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "退出并停止 Backend？"
        confirmation.informativeText = "将先停止 Safarier 管理的 Backend，确认停止后退出 Manager。不会取消待处理自动化，也不会主动关闭已打开的浏览器窗口或停止独立运行的 DSH；Safarier 原有的 DSH 退出清理仍会照常执行。"
        confirmation.addButton(withTitle: "退出并停止 Backend")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        switch explicitExitState.request(pendingWork: ManagerAutomationHooks.combinedPendingWork) {
        case .refusePendingWork:
            showPendingWorkExitRefusal(ManagerAutomationHooks.combinedPendingWork)
            return
        case .alreadyInFlight:
            return
        case .beginShutdown:
            break
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pending = ManagerAutomationHooks.combinedPendingWork
                guard pending == 0 else {
                    explicitExitState.shutdownFailed()
                    cancelDeferredSystemTermination()
                    showPendingWorkExitRefusal(pending)
                    return
                }
                try await hostService.stopBackendsForExplicitExit()
                let pendingAfterStop = ManagerAutomationHooks.combinedPendingWork
                guard pendingAfterStop == 0 else {
                    explicitExitState.shutdownFailed()
                    hostService.resumeAfterCancelledExplicitExit()
                    cancelDeferredSystemTermination()
                    showPendingWorkExitRefusal(pendingAfterStop)
                    return
                }
                guard explicitExitState.shutdownSucceeded() else { return }
                guard !hostService.needsTerminationCheck else {
                    explicitExitState.shutdownFailed()
                    hostService.resumeAfterCancelledExplicitExit()
                    presentExplicitExitFailure(ManagerHostFailure.unavailable("Manager-owned Host 尚未确认全部停止。Manager 保持运行，请检查状态后重试。"))
                    cancelDeferredSystemTermination()
                    return
                }
                if systemTerminationWaitingOnExplicitExit {
                    finishDeferredSystemTermination()
                } else {
                    explicitExitTerminationApproved = true
                    NSApp.terminate(nil)
                }
            } catch {
                explicitExitState.shutdownFailed()
                cancelDeferredSystemTermination()
                presentExplicitExitFailure(error)
            }
        }
    }

    private func finishDeferredSystemTermination() {
        guard systemTerminationWaitingOnExplicitExit else { return }
        systemTerminationWaitingOnExplicitExit = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func cancelDeferredSystemTermination() {
        guard systemTerminationWaitingOnExplicitExit else { return }
        systemTerminationWaitingOnExplicitExit = false
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    private func showPendingWorkExitRefusal(_ pending: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法退出并停止 Backend"
        alert.informativeText = "当前有 \(pending) 项待处理自动化。Manager 不会替你取消这些工作；请等待完成后再尝试。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentExplicitExitFailure(_ error: Error) {
        if model == nil { model = ManagerModel(workspace: workspace, hostService: hostService) }
        apply(state.handle(.interactive))
        model?.message = ManagerModel.Message(
            title: "无法退出并停止 Backend",
            detail: "\(error.localizedDescription)\n\nManager 保持运行；处理上述问题后可重新打开面板并重试。"
        )
    }

    private func presentHostTerminationFailure(_ error: Error) {
        if model == nil { model = ManagerModel(workspace: workspace, hostService: hostService) }
        apply(state.handle(.interactive))
        model?.message = ManagerModel.Message(
            title: "无法退出 Safarier",
            detail: "\(error.localizedDescription)\n\nManager 保持运行以避免遗留 GUI-owned Host。处理上述情况后，可再次退出。"
        )
    }
}

struct ManagerMigrationFailureState {
    private var launch = ManagerLaunchState()
    mutating func handle(_ event: ManagerLaunchEvent) -> Bool {
        launch.handle(event).contains(.showManager)
    }
}

@MainActor
private final class ManagerMigrationFailureDelegate: NSObject, NSApplicationDelegate {
    private let message: String
    private var state = ManagerMigrationFailureState()
    private var shown = false
    init(message: String) { self.message = message }
    func applicationWillFinishLaunching(_ notification: Notification) {
        let events = NSAppleEventManager.shared()
        events.setEventHandler(self, andSelector: #selector(automationEvent(_:withReplyEvent:)), forEventClass: 0x61736372, andEventID: 0x6e6f6f70)
        events.setEventHandler(self, andSelector: #selector(openEvent(_:withReplyEvent:)), forEventClass: 0x61657674, andEventID: 0x6f617070)
        events.setEventHandler(self, andSelector: #selector(interactiveEvent(_:withReplyEvent:)), forEventClass: 0x61657674, andEventID: 0x72617070)
    }
    @objc private func automationEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) { handle(.automation) }
    @objc private func openEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) { handle(.openApplication) }
    @objc private func interactiveEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) { handle(.interactive) }
    func recordInteractive() { handle(.interactive) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        handle(.finishedLaunching)
        // Allow a late Launch Services open event without keeping an unattended failure alive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.shown == false { exit(1) }
        }
    }
    private func handle(_ event: ManagerLaunchEvent) {
        guard state.handle(event), !shown else { return }
        shown = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要迁移 Safarier 工作区"
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        exit(1)
    }
}
