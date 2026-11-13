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

    init(workspace: SafarierWorkspace, quietStart: Bool = false) { self.workspace = workspace; self.automationManager = .shipping(workspace: workspace); self.promoteOnActivation = quietStart; super.init() }
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
        state.handle(.windowClosed(pendingCommands: ManagerAutomationHooks.combinedPendingWork)).contains(.terminate)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
            case .replyToTermination: NSApp.reply(toApplicationShouldTerminate: true)
            case .deferTermination: break
            }
        }
    }
    private func showManager(activate: Bool = true) {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        TestingLaunchTrace.logger.notice("phase=show_enter windowExists=\(self.window != nil, privacy: .public) policy=\(NSApp.activationPolicy().rawValue, privacy: .public)")
        #endif
        if window == nil {
            let model = ManagerModel(workspace: workspace)
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
            window.isOpaque = false
            window.backgroundColor = .clear
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
            let menu = ManagerMenu(model: model); self.menu = menu; NSApp.mainMenu = menu.make()
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
