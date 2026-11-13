import AppKit
import SwiftUI
import WebKit
import SafarierCore
import SafarierWebKit
import SafarierObjCSupport

enum BrowserAutomationNavigationEvent {
    case started(WKNavigation?)
    case committed(WKNavigation?)
    case finished(WKNavigation?)
    case failed(WKNavigation?, Error, provisional: Bool)
    case processTerminated
    case closed
}

@MainActor
final class NonActivatingBrowserWindow: NSWindow {
    private(set) var manualInteractionEnabled = true
    override var canBecomeKey: Bool { manualInteractionEnabled && super.canBecomeKey }
    override var canBecomeMain: Bool { manualInteractionEnabled && super.canBecomeMain }
    func enableManualInteraction() { manualInteractionEnabled = true }
    func setManualInteractionEnabled(_ enabled: Bool) { manualInteractionEnabled = enabled }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    fileprivate var controlLeaseID: UUID?
    fileprivate var controlLeaseReady = false
    #endif

    private var browserController: BrowserWindowController? {
        guard manualInteractionEnabled else { return nil }
        return delegate as? BrowserWindowController
    }

    /// 鼠标事件处理：支持鼠标侧键后退（按钮 3 / XButton1）与前进（按钮 4 / XButton2）。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .otherMouseDown:
            if event.buttonNumber == 3 || event.buttonNumber == 4 {
                // 吞掉按下的瞬间，防止网页内选区或意外拖拽
                return
            }
        case .otherMouseUp:
            if event.buttonNumber == 3 {
                // 鼠标后退侧键
                if let controller = browserController, controller.canGoBack {
                    controller.goBack(nil)
                    return
                }
            } else if event.buttonNumber == 4 {
                // 鼠标前进侧键
                if let controller = browserController, controller.canGoForward {
                    controller.goForward(nil)
                    return
                }
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// 触控板/手势轻扫：向右轻扫后退，向左轻扫前进。
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            if let controller = browserController, controller.canGoBack {
                controller.goBack(nil)
                return
            }
        } else if event.deltaX < 0 {
            if let controller = browserController, controller.canGoForward {
                controller.goForward(nil)
                return
            }
        }
        super.swipe(with: event)
    }

    /// 键盘快捷键处理：
    /// - ⌘[ 与 ⌘]（Safari 原生快捷键，全场景生效）
    /// - ⌘← 与 ⌘→（Safari/Chrome 常用快捷键，非文本输入状态生效）
    /// - ⌥← 与 ⌥→（Chrome/Edge/跨平台常用快捷键，非文本输入状态生效）
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) {
            return true
        }

        guard let controller = browserController else { return false }

        // 如果用户正在地址栏或输入框内编辑文字，不截取方向键（保留光标移动功能）
        let isEditingText: Bool = {
            guard let responder = firstResponder else { return false }
            return responder is NSText || responder is NSTextField || responder is NSTextView
        }()

        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])

        // 1. ⌘[ (后退) 和 ⌘] (前进)
        if flags == .command {
            if event.charactersIgnoringModifiers == "[" {
                if controller.canGoBack {
                    controller.goBack(nil)
                    return true
                }
            } else if event.charactersIgnoringModifiers == "]" {
                if controller.canGoForward {
                    controller.goForward(nil)
                    return true
                }
            }
        }

        // 2. ⌘← 与 ⌘→
        if flags == .command && !isEditingText {
            let isLeft = event.specialKey == .leftArrow || event.charactersIgnoringModifiers == BrowserMenu.leftArrow
            let isRight = event.specialKey == .rightArrow || event.charactersIgnoringModifiers == BrowserMenu.rightArrow
            if isLeft {
                if controller.canGoBack {
                    controller.goBack(nil)
                    return true
                }
            } else if isRight {
                if controller.canGoForward {
                    controller.goForward(nil)
                    return true
                }
            }
        }

        // 3. ⌥← 与 ⌥→
        if flags == .option && !isEditingText {
            let isLeft = event.specialKey == .leftArrow || event.charactersIgnoringModifiers == BrowserMenu.leftArrow
            let isRight = event.specialKey == .rightArrow || event.charactersIgnoringModifiers == BrowserMenu.rightArrow
            if isLeft {
                if controller.canGoBack {
                    controller.goBack(nil)
                    return true
                }
            } else if isRight {
                if controller.canGoForward {
                    controller.goForward(nil)
                    return true
                }
            }
        }

        return false
    }
}

#if SAFARIER_BOUND_LOCAL_CANDIDATE
/// Presentation ownership is independent of input ownership. Restore is permitted
/// only after the caller proves the native lease drained on these same objects.
@MainActor final class RegisteredPresentationLease {
    let id = UUID()
    let window: NonActivatingBrowserWindow
    let originalPolicy: NSApplication.ActivationPolicy
    let originalManual: Bool
    let originalIgnoresMouseEvents: Bool
    let originalTabbingMode: NSWindow.TabbingMode
    private let readPolicy: () -> NSApplication.ActivationPolicy
    private let setPolicy: (NSApplication.ActivationPolicy) -> Bool
    private let isActive: () -> Bool
    private var restored = false
    private var presentationAttempted = false

    init(window: NonActivatingBrowserWindow,
         readPolicy: @escaping () -> NSApplication.ActivationPolicy = { NSApp.activationPolicy() },
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = { NSApp.setActivationPolicy($0) },
         isActive: @escaping () -> Bool = { NSApp.isActive }) {
        self.window = window; self.readPolicy = readPolicy; self.setPolicy = setPolicy; self.isActive = isActive
        originalPolicy = readPolicy(); originalManual = window.manualInteractionEnabled
        originalIgnoresMouseEvents = window.ignoresMouseEvents; originalTabbingMode = window.tabbingMode
    }

    func acquire() -> Bool {
        guard !restored, window.controlLeaseID == nil, !isActive(),
              !window.isKeyWindow, !window.isMainWindow else { return false }
        window.controlLeaseID = id
        window.controlLeaseReady = false
        window.setManualInteractionEnabled(false)
        window.ignoresMouseEvents = true; window.tabbingMode = .disallowed
        // AppKit returns false for a no-op policy assignment. Skip only an already matching policy.
        let switched = readPolicy() == .accessory || setPolicy(.accessory)
        window.controlLeaseReady = switched && readPolicy() == .accessory && !isActive() &&
            !window.canBecomeKey && !window.canBecomeMain && !window.isKeyWindow && !window.isMainWindow
        return window.controlLeaseReady
    }

    func present() -> Bool {
        guard !presentationAttempted, !restored, window.controlLeaseID == id,
              window.controlLeaseReady, readPolicy() == .accessory, !isActive(),
              !window.isKeyWindow, !window.isMainWindow, !window.manualInteractionEnabled,
              window.ignoresMouseEvents, NSEvent.pressedMouseButtons == 0,
              BrowserWindowController.registeredWindowOnCurrentScreen(window) else { return false }
        presentationAttempted = true
        // Startup already presented this window. Attach must preserve its stacking order.
        return window.controlLeaseID == id && window.controlLeaseReady &&
            readPolicy() == .accessory && !isActive() && !window.isKeyWindow && !window.isMainWindow &&
            !window.canBecomeKey && !window.canBecomeMain && NSEvent.pressedMouseButtons == 0 &&
            BrowserWindowController.registeredWindowOnCurrentScreen(window)
    }

    func restore(inputDrained: Bool) -> Bool {
        guard inputDrained, !restored, window.controlLeaseID == id,
              !window.manualInteractionEnabled, window.ignoresMouseEvents else { return false }
        // Match retained-browser handoff: restore app policy before enabling
        // manual interaction. Never activate, make key, or move global focus.
        guard (readPolicy() == originalPolicy || setPolicy(originalPolicy)), readPolicy() == originalPolicy,
              !isActive(), !window.isKeyWindow, !window.isMainWindow else { return false }
        window.setManualInteractionEnabled(originalManual)
        window.tabbingMode = originalTabbingMode
        window.ignoresMouseEvents = originalIgnoresMouseEvents
        window.controlLeaseReady = false; window.controlLeaseID = nil
        restored = true
        return window.manualInteractionEnabled == originalManual &&
            window.tabbingMode == originalTabbingMode && window.ignoresMouseEvents == originalIgnoresMouseEvents
    }
}
#endif

/// 一个标签页。用 macOS 原生窗口标签（每个标签是一个 NSWindow），所以 ⌘T、拖出成新窗口、合并窗口、
/// 标签概览都是系统现成的；只有一个标签时不显示标签栏，和 Safari 的「分离」布局一样。
@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation,
    NSMenuItemValidation, NSSharingServicePickerToolbarItemDelegate, WKNavigationDelegate, WKUIDelegate, BrowserActions {
    /// 统一工具栏（标题栏 + 工具栏）的高度。真 Safari 单标签窗口实测 outerHeight − innerHeight = 52。
    static let chromeHeight: CGFloat = 52
    /// Safari 的缩放档位。
    private static let zoomLevels: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    unowned let session: BrowserSession
    let window: NSWindow
    let webView: BrowserWebView
    /// 网页打开的视图（window.open、target=_blank、右键新标签 / 新窗口）：由 WebKit 载入，不显示起始页、不抢地址栏焦点。
    let isPopup: Bool
    var onAutomationNavigation: ((BrowserAutomationNavigationEvent) -> Void)?
    private var pageRetry = ControllerNavigationRetryState()
    private var pageRetryTask: Task<Void, Never>?
    private var pageRetryExpiryTask: Task<Void, Never>?
    private var retryNow: Double { ProcessInfo.processInfo.systemUptime }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
    private func traceRegisteredLoad(_ phase: StaticString, navigation: WKNavigation?, error: Error? = nil) {
        let nsError = error as NSError?
        let domain: String
        if let nsError {
            switch nsError.domain {
            case NSURLErrorDomain: domain = "url"
            case "WKErrorDomain", "WebKitErrorDomain": domain = "webkit"
            case NSCocoaErrorDomain: domain = "cocoa"
            case NSPOSIXErrorDomain: domain = "posix"
            default: domain = "other"
            }
        } else { domain = "none" }
        let retired = navigation.map { pageRetry.isRetired($0) } ?? false
        let matches = navigation.map { pageRetry.matches($0) } ?? false
        fputs("REGISTERED_PAGE_DIAG phase=\(phase) monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) windowID=\(registeredWindowID.uuidString) pageID=\(registeredPageID.uuidString) navPresent=\(navigation != nil) retired=\(retired) matches=\(matches) loading=\(webView.isLoading) urlPresent=\(webView.url != nil) errorDomain=\(domain) errorCode=\(nsError?.code ?? 0)\n", stderr)
    }
    private func traceRegisteredPolicy(_ phase: StaticString, action: WKNavigationAction) {
        fputs("REGISTERED_PAGE_DIAG phase=\(phase) monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) windowID=\(registeredWindowID.uuidString) pageID=\(registeredPageID.uuidString) navigationType=\(action.navigationType.rawValue) mainFrame=\(action.targetFrame?.isMainFrame == true) targetPresent=\(action.targetFrame != nil) download=\(action.shouldPerformDownload)\n", stderr)
    }
    #endif

    func cancelPageRetry() {
        pageRetryTask?.cancel(); pageRetryTask = nil
        pageRetryExpiryTask?.cancel(); pageRetryExpiryTask = nil
        pageRetry.cancel()
    }

    private func loadExplicitPage(_ url: URL) {
        cancelPageRetry()
        let startedAt = retryNow
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        traceRegisteredLoad("load.before", navigation: nil)
        #endif
        let startedNavigation = webView.load(URLRequest(url: url))
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        traceRegisteredLoad("load.after", navigation: startedNavigation)
        #endif
        guard let navigation = startedNavigation else { return }
        guard controllerPolicy == .interactive, webView.navigationDelegate === self else { return }
        guard pageRetry.begin(navigation, url: url, now: startedAt, budget: AutomationLimits.navigationSeconds),
              let ticket = pageRetry.expiryTicket else { return }
        pageRetryExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let remaining = self.flatMap({ $0.pageRetry.remaining(ticket, now: $0.retryNow) }) else { return }
                if remaining == 0 { self?.expirePageRetry(ticket); return }
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            }
        }
    }

    private func expirePageRetry(_ ticket: ControllerNavigationRetryState.ExpiryTicket) {
        guard pageRetry.isExpired(ticket, now: retryNow),
              let navigation = pageRetry.activeNavigation as? WKNavigation,
              pageRetry.matchesActive(ticket, navigation: navigation), let url = pageRetry.originalURL,
              controllerPolicy == .interactive, webView.navigationDelegate === self,
              webView.window === window else { return }
        cancelPageRetry()
        webView.stopLoading()
        targetURL = nil
        showErrorPage(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                              userInfo: [NSURLErrorFailingURLErrorKey: url]))
    }

    private func retryProvisional(_ navigation: WKNavigation?, error: Error) -> Bool {
        guard controllerPolicy == .interactive, webView.navigationDelegate === self, let navigation,
              let ticket = pageRetry.failed(navigation, error: error, provisional: true, now: retryNow) else { return false }
        let failure = error as NSError
        fputs("NAV_DIAG phase=pageRetryScheduled attempt=\(ticket.attempt) domain=\(failure.domain) code=\(failure.code)\n", stderr)
        pageRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(ticket.delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled, self.pageRetry.isPending(ticket) else { return }
            guard self.controllerPolicy == .interactive, self.webView.navigationDelegate === self,
                  self.webView.window === self.window else { self.cancelPageRetry(); return }
            guard !self.webView.isLoading else { self.cancelPageRetry(); return }
            let dispatchTime = self.retryNow
            guard self.pageRetry.mayDispatch(ticket, now: dispatchTime),
                  let url = self.pageRetry.originalURL else {
                self.cancelPageRetry(); self.showErrorPage(error); return
            }
            guard let child = self.webView.load(URLRequest(url: url)),
                  self.pageRetry.adopt(child, ticket: ticket, now: dispatchTime) else {
                self.cancelPageRetry(); self.showErrorPage(error); return
            }
            self.targetURL = url
            fputs("NAV_DIAG phase=pageRetryStarted attempt=\(ticket.attempt) domain=\(failure.domain) code=\(failure.code)\n", stderr)
        }
        return true
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    let registeredWindowID = UUID()
    let registeredPageID = UUID()
    #endif
    private let addressBar: AddressBar
    private let findBar = FindBar()
    private let startPage: StartPageView
    private let content = NSStackView()
    private var observations: [NSKeyValueObservation] = []
    private var downloadsPopover: NSPopover?
    private var bookmarksPopover: NSPopover?
    private var bookmarksListPopover: NSPopover?
    private var autofillPopover: NSPopover?
    private var passwordsWindow: NSWindow?
    private var passwordSaveBannerHost: NSHostingView<PasswordSaveBannerView>?
    private var hasAutofilledCurrentPage = false
    /// 当前正在导航或请求加载的网址，在 webView.url 尚未就绪（如会话恢复、页面载入中）时提供 displayURL。
    private(set) var targetURL: URL?
    /// 当前显示的是我们自己的出错页时，记下原本要打开的网址（重新载入时重试它）。
    private(set) var failedURL: URL?
    /// 新标签 / 新窗口要在成为 key window 之后再把焦点放进地址栏，早了会被系统重置。
    private(set) var wantsAddressFocus = false

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    /// A registered window remains the user's original NSWindow and WebView.
    /// The snapshot is consumed only after native input has been confirmed closed.
    typealias RegisteredWindowState = RegisteredPresentationLease

    func validateRegisteredAdmission(allowLoading: Bool = false, allowTabGroup: Bool = false) throws {
        guard let app = NSApp else { RegisteredAdmissionDiagnostic.check(false, .appMissing); throw AutomationError(code: .interactionRequired) }
        guard RegisteredAdmissionDiagnostic.check(!app.isActive, .appActive),
              RegisteredAdmissionDiagnostic.check(!window.isKeyWindow, .windowKey),
              RegisteredAdmissionDiagnostic.check(!window.isMainWindow, .windowMain),
              RegisteredAdmissionDiagnostic.check(Self.registeredWindowOnCurrentScreen(window), .windowScreen),
              RegisteredAdmissionDiagnostic.check(window.windowNumber > 0, .windowNumber),
              RegisteredAdmissionDiagnostic.check(window.attachedSheet == nil, .sheet),
              RegisteredAdmissionDiagnostic.check((window.tabbedWindows?.count ?? 1) == 1 || (allowTabGroup && window.tabGroup?.selectedWindow === window && window.tabGroup?.isOverviewVisible == false), .tabGroup),
              RegisteredAdmissionDiagnostic.check(NSEvent.pressedMouseButtons == 0, .mouseButtons),
              RegisteredAdmissionDiagnostic.check(allowLoading || !webView.isLoading, .loading),
              RegisteredAdmissionDiagnostic.check(webView.window === window, .webViewWindow),
              RegisteredAdmissionDiagnostic.check(webView.navigationDelegate === self, .navigationDelegate),
              RegisteredAdmissionDiagnostic.check(webView.uiDelegate === self, .uiDelegate),
              RegisteredAdmissionDiagnostic.check(onAutomationNavigation == nil, .automationNavigation),
              RegisteredAdmissionDiagnostic.check(allowLoading || !isShowingStartPage, .startPage),
              RegisteredAdmissionDiagnostic.check(!wantsAddressFocus, .addressFocus) else {
            throw AutomationError(code: .interactionRequired)
        }
        // Protocol conformance alone is not evidence of an edit: WKContentView
        // commonly conforms even when the user is only browsing.
        if Self.registeredResponderHasEditingConflict(window.firstResponder) {
            RegisteredAdmissionDiagnostic.check(false, .editing)
            throw AutomationError(code: .interactionRequired)
        }
    }

    func beginRegisteredControl(allowTabGroup: Bool = false) throws -> RegisteredWindowState {
        try validateRegisteredAdmission(allowTabGroup: allowTabGroup)
        guard let owned = window as? NonActivatingBrowserWindow,
              owned.controlLeaseID == nil, !window.ignoresMouseEvents else { RegisteredAdmissionDiagnostic.check(false, .windowLease); throw AutomationError(code: .interactionRequired) }
        let state = RegisteredWindowState(window: owned)
        let acquired = state.acquire()
        traceRegisteredPresentation("acquire", confirmed: acquired)
        // Even failed policy transitions retain the snapshot. The prepared input
        // must close/drain before page teardown restores this state.
        return state
    }

    func traceRegisteredPresentation(_ phase: String, confirmed: Bool) {
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        fputs("PRESENTATION_DIAG phase=\(phase) pid=\(ProcessInfo.processInfo.processIdentifier) visible=\(window.isVisible) mini=\(window.isMiniaturized) activeSpace=\(window.isOnActiveSpace) monotonic_ms=\(ms) confirmed=\(confirmed) policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) key=\(window.isKeyWindow) main=\(window.isMainWindow) canKey=\(window.canBecomeKey) canMain=\(window.canBecomeMain)\n", stderr)
    }

    static func registeredWindowOnCurrentScreen(_ window: NSWindow) -> Bool {
        !NSApp.isHidden && window.isVisible && !window.isMiniaturized && window.isOnActiveSpace &&
            NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
    }

    static func registeredLeaseID(window: NSWindow) -> UUID? {
        (window as? NonActivatingBrowserWindow)?.controlLeaseID
    }

    static func registeredPresentationValid(window: NSWindow, webView: BrowserWebView, leaseID: UUID) -> Bool {
        guard let owned = window as? NonActivatingBrowserWindow else { return false }
        return owned.controlLeaseID == leaseID && owned.controlLeaseReady &&
            !owned.manualInteractionEnabled && NSApp.activationPolicy() == .accessory && !NSApp.isActive &&
            registeredWindowOnCurrentScreen(owned) && !owned.canBecomeKey && !owned.canBecomeMain &&
            !owned.isKeyWindow && !owned.isMainWindow && owned.ignoresMouseEvents &&
            owned.tabbingMode == .disallowed && webView.window === owned
    }

    static func registeredResponderHasEditingConflict(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView, text.isFieldEditor { return true }
        if let client = responder as? any NSTextInputClient, client.hasMarkedText() { return true }
        return false
    }

    func restoreRegisteredControl(_ state: RegisteredWindowState, input: NativePageInput) -> Bool {
        guard input.window === window, input.webView === webView,
              input.activityClosed, input.activityStatus == .OK, input.buttonMask == 0,
              !input.requiresOwnedTargetDestruction, window.ignoresMouseEvents,
              webView.window === window else { return false }
        guard state.window === window else { return false }
        let restored = state.restore(inputDrained: true)
        traceRegisteredPresentation("restore", confirmed: restored)
        return restored
    }
    #endif

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func enableRetainedManualInteraction() -> Bool {
        guard let owned = window as? NonActivatingBrowserWindow,
              !owned.manualInteractionEnabled, !owned.isKeyWindow, !owned.isMainWindow,
              owned.ignoresMouseEvents, webView.window === owned else { return false }
        owned.enableManualInteraction()
        owned.ignoresMouseEvents = false
        owned.tabbingMode = .automatic
        return owned.canBecomeKey && owned.canBecomeMain && !owned.ignoresMouseEvents
    }
    #endif
    /// ⇧⌘H 回到起始页（环境没设起始网址时）：载入 about:blank 并显示起始页，直到导航到别的网址。
    private var showingHome = false
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var registeredInitialBlank = false

    func loadRegisteredInitial(_ url: URL?) {
        guard let url, url.absoluteString != "about:blank" else {
            registeredInitialBlank = true
            targetURL = nil
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            return
        }
        load(url)
    }
    #endif

    private enum Item {
        static let profile = NSToolbarItem.Identifier("profile")
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let address = NSToolbarItem.Identifier("address")
        static let autofill = NSToolbarItem.Identifier("autofill")
        static let bookmarks = NSToolbarItem.Identifier("bookmarks")
        static let bookmarksList = NSToolbarItem.Identifier("bookmarksList")
        static let share = NSToolbarItem.Identifier("share")
        static let downloads = NSToolbarItem.Identifier("downloads")
        static let newTab = NSToolbarItem.Identifier("newTab")
        static let tabOverview = NSToolbarItem.Identifier("tabOverview")
    }

    init(session: BrowserSession, webView: BrowserWebView, contentSize: NSSize, isPopup: Bool = false, nonActivating: Bool = false) {
        self.session = session
        self.webView = webView
        self.isPopup = isPopup
        addressBar = AddressBar(isPrivate: session.isPrivate)
        startPage = StartPageView(profile: session.profile, accent: session.accent, details: session.startPageDetails)
        let rect = NSRect(origin: .zero, size: contentSize)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let browserWindow = NonActivatingBrowserWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        browserWindow.setManualInteractionEnabled(!nonActivating)
        window = browserWindow
        super.init()
        webView.legacySystemDragPermission = { [weak self] in self?.allowUI(.systemDrag) ?? false }
        webView.setLegacySystemDragBoundaryInstalled(SFRInstallLegacySystemDragBoundary(BrowserWebView.self, nil) == .OK)
        buildWindow(contentSize: contentSize)
        observe()
    }

    private var controllerPolicy: BrowserExecutionPolicy { session.controllerPolicy(self) }

    private func routeUI<T>(_ request: BackgroundUIRequest, perform: () -> T, deny: () -> T) -> T {
        session.routeControllerUI(request, controller: self, perform: perform, deny: deny)
    }

    @discardableResult private func allowUI(_ request: BackgroundUIRequest) -> Bool {
        routeUI(request, perform: { true }, deny: { false })
    }

    // MARK: - 布局

    private func buildWindow(contentSize: NSSize) {
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.tabbingIdentifier = "safarier.\(session.profile.id.uuidString)"
        window.tabbingMode = .automatic
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = "起始页面"
        window.minSize = NSSize(width: 500, height: 300)

        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(closeWindow(_:))
        }

        let toolbar = NSToolbar(identifier: "SafarierBrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Item.address]
        window.toolbar = toolbar

        webView.navigationDelegate = self
        webView.uiDelegate = self

        findBar.isHidden = true
        findBar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFind() }

        webView.onSearchWeb = { [weak self] url in
            guard let self else { return }
            guard self.allowUI(.openTab) else { return }
            self.session.openTab(in: self, url: url)
        }

        addressBar.onSubmit = { [weak self] text in self?.navigate(to: text) }
        addressBar.onReload = { [weak self] in self?.reloadPage(nil) }
        addressBar.onStop = { [weak self] in self?.stopLoading(nil) }
        // Esc 取消编辑：在打开的网页上时把焦点还给网页。
        addressBar.onCancel = { [weak self] in
            guard let self, self.displayURL != nil else { return }
            self.window.makeFirstResponder(self.webView)
        }

        content.orientation = .vertical
        content.spacing = 0
        content.addArrangedSubview(findBar)
        content.addArrangedSubview(webView)
        for view in [findBar, webView] as [NSView] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        content.translatesAutoresizingMaskIntoConstraints = false
        startPage.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        container.addSubview(startPage)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            startPage.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            startPage.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            startPage.topAnchor.constraint(equalTo: webView.topAnchor),
            startPage.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
        window.contentView = container
        window.setContentSize(contentSize)
        configureToolbarTranslucency()
    }

    /// 在统一工具栏容器下挂载微半透明磨砂玻璃材质，与主管理窗口质感及主题色深度统一
    private func configureToolbarTranslucency() {
        guard let themeFrame = window.contentView?.superview else { return }
        for subview in themeFrame.subviews {
            if String(describing: type(of: subview)).contains("TitlebarContainer") {
                if subview.viewWithTag(ToolbarTranslucentBackgroundView.viewTag) != nil { return }
                let bg = ToolbarTranslucentBackgroundView()
                bg.frame = subview.bounds
                bg.autoresizingMask = [.width, .height]
                subview.addSubview(bg, positioned: .below, relativeTo: subview.subviews.first)
                break
            }
        }
    }

    private func observe() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTitle() } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateState() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.window.toolbar?.validateVisibleItems() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.window.toolbar?.validateVisibleItems() } },
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(handleFaviconUpdate(_:)), name: FaviconService.didUpdateFaviconNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleFaviconUpdate(_ notification: Notification) {
        guard let host = notification.userInfo?["host"] as? String else { return }
        if displayURL?.host?.lowercased() == host {
            updateFavicon()
        }
    }

    /// 起始页是不是正显示着（测试和诊断用）。
    var isShowingStartPage: Bool { !startPage.isHidden }

    /// 地址栏、标题、菜单用的当前网址：起始页（新标签或 ⇧⌘H）时为 nil。
    var displayURL: URL? {
        showingHome ? nil : (webView.url ?? targetURL)
    }

    func updateState() {
        // 后退 / 前进回到 ⇧⌘H 留下的 about:blank 时也显示起始页；网页打开的空白弹窗（isPopup）不算。
        if let url = webView.url {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if url.absoluteString != "about:blank" { registeredInitialBlank = false }
            showingHome = !isPopup && url.absoluteString == "about:blank" && !registeredInitialBlank
            #else
            showingHome = !isPopup && url.absoluteString == "about:blank"
            #endif
        }
        let url = displayURL
        startPage.isHidden = controllerPolicy == .automationBackground || isPopup || url != nil || (webView.isLoading && !showingHome)
        addressBar.update(url: url, isLoading: webView.isLoading && !showingHome, progress: webView.estimatedProgress, secure: webView.hasOnlySecureContent)
        updateTitle()
        updateBookmarkStar()
        session.tabStateChanged()
    }

    /// 标签上显示网页标题；没有标题时显示域名，和 Safari 一样。
    private func updateTitle() {
        if showingHome {
            window.title = "起始页面"
        } else if let title = webView.title, !title.isEmpty {
            window.title = title
        } else if let host = (webView.url ?? targetURL)?.host {
            window.title = host
        } else {
            let effective = webView.url ?? targetURL
            window.title = effective == nil ? "起始页面" : (effective?.absoluteString ?? "")
        }
        updateFavicon()
    }

    /// 动态更新标签页图标 (Favicon)
    private func updateFavicon() {
        guard !showingHome, let url = displayURL, let host = url.host?.lowercased(), !host.isEmpty else {
            window.tab.setFavicon(nil)
            return
        }

        if let cached = FaviconService.shared.getFavicon(for: url) {
            window.tab.setFavicon(cached)
            return
        }

        FaviconService.shared.extractFavicon(from: webView, for: url) { [weak self] image in
            guard let self, self.displayURL?.host?.lowercased() == host else { return }
            self.window.tab.setFavicon(image)
        }
    }

    // MARK: - 打开网页

    func load(_ url: URL?) {
        if let url {
            targetURL = url
            showingHome = false
            loadExplicitPage(url)
        } else {
            cancelPageRetry()
            targetURL = nil
            updateState()
            wantsAddressFocus = true
            if window.isKeyWindow { focusAddressIfWanted() }
        }
    }

    private func navigate(to text: String) {
        guard let url = AddressInput.url(for: text) else { return }
        open(url)
    }

    private func open(_ url: URL) {
        failedURL = nil
        showingHome = false
        targetURL = url
        loadExplicitPage(url)
        window.makeFirstResponder(webView)
    }

    private func find(_ text: String, backwards: Bool) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            self?.findBar.show(found: result.matchFound)
        }
    }

    private func hideFind() {
        findBar.isHidden = true
        window.makeFirstResponder(webView)
    }

    func downloadsChanged() {
        guard let toolbar = window.toolbar else { return }
        if !toolbar.items.contains(where: { $0.itemIdentifier == Item.downloads }),
           let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Item.newTab }) {
            toolbar.insertItem(withItemIdentifier: Item.downloads, at: index)
        }
        if let popover = downloadsPopover, popover.isShown {
            popover.contentViewController = session.downloads.makePopoverContent()
        }
    }

    // MARK: - 菜单 / 工具栏动作

    /// 同一窗口里的标签，按标签栏顺序。
    var tabs: [NSWindow] { window.tabGroup?.windows ?? [window] }

    @objc func newWindow(_ sender: Any?) { guard allowUI(.openWindow) else { return }; session.openWindow(url: nil) }
    @objc func newTab(_ sender: Any?) { guard allowUI(.openTab) else { return }; session.openTab(in: self, url: nil) }
    /// 标签栏右侧的 "+"。
    @objc func newWindowForTab(_ sender: Any?) { guard allowUI(.openTab) else { return }; session.openTab(in: self, url: nil) }
    @objc func reopenClosedTab(_ sender: Any?) { session.reopenClosedTab(in: self) }
    @objc func focusLocation(_ sender: Any?) { guard allowUI(.unknown) else { return }; addressBar.focus() }
    @objc func closeTab(_ sender: Any?) {
        guard allowUI(.windowClose) else { return }
        if windowShouldClose(window) {
            window.close()
        }
    }
    /// ⌥⌘W：关掉同一窗口里的其它标签。
    @objc func closeOtherTabs(_ sender: Any?) {
        guard allowUI(.windowClose) else { return }
        for tab in tabs where tab !== window {
            if let controller = tab.delegate as? BrowserWindowController {
                if controller.windowShouldClose(tab) { tab.close() }
            } else {
                tab.close()
            }
        }
    }

    private var isPerformingCloseWindow = false

    @objc func closeWindow(_ sender: Any?) {
        guard !isPerformingCloseWindow else { return }
        guard allowUI(.windowClose) else { return }
        isPerformingCloseWindow = true
        defer { isPerformingCloseWindow = false }
        session.saveSessionState()
        session.beginClosingWindow()
        let allTabs = window.tabbedWindows ?? (window.tabGroup?.windows ?? [window])
        for tab in allTabs {
            if let controller = tab.delegate as? BrowserWindowController {
                if controller.windowShouldClose(tab) {
                    tab.close()
                }
            } else {
                tab.close()
            }
        }
    }

    /// ⌘S：把当前页面（DOM）存成 .html。
    @objc func savePageAs(_ sender: Any?) {
        guard allowUI(.save) else { return }
        guard let url = displayURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = Self.fileName(title: webView.title, url: url, extension: "html")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.webView.documentHTML { [weak self] html in
                guard let html else { return NSSound.beep() }
                do { try Data(html.utf8).write(to: destination, options: .atomic) } catch { self?.presentError(error) }
            }
        }
    }

    /// 导出为 PDF…：整页（不只是可见区域）。
    @objc func exportPDF(_ sender: Any?) {
        guard allowUI(.save) else { return }
        guard let url = displayURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.fileName(title: webView.title, url: url, extension: "pdf")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.webView.createPDF { [weak self] result in
                do { try result.get().write(to: destination, options: .atomic) } catch { self?.presentError(error) }
            }
        }
    }

    /// 网页标题（没有就用域名）做文件名，去掉文件名里不能用的字符。
    static func fileName(title: String?, url: URL, extension ext: String) -> String {
        let base = (title?.isEmpty == false ? title! : (url.host ?? "页面"))
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? "页面" : String(base.prefix(120))).\(ext)"
    }

    private func presentError(_ error: Error) {
        guard allowUI(.unknown) else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    @objc func printPage(_ sender: Any?) {
        guard allowUI(.printPage) else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
    @objc func showFind(_ sender: Any?) {
        guard allowUI(.unknown) else { return }
        findBar.isHidden = false
        window.makeFirstResponder(findBar.searchField)
    }
    @objc func findNextMatch(_ sender: Any?) { findBar.isHidden ? showFind(sender) : findBar.findNext() }
    @objc func findPreviousMatch(_ sender: Any?) { findBar.isHidden ? showFind(sender) : findBar.findPrevious() }
    /// ⌘E：用页面里选中的文字查找（也放进系统的查找剪贴板，和其它 App 共用）。
    @objc func useSelectionForFind(_ sender: Any?) {
        guard allowUI(.unknown) else { return }
        webView.selectedText { [weak self] text in
            guard let self, let text, !text.isEmpty else { return NSSound.beep() }
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.findBar.searchField.stringValue = text
            self.findBar.isHidden = false
            self.find(text, backwards: false)
        }
    }
    @objc func stopLoading(_ sender: Any?) { cancelPageRetry(); webView.stopLoading() }
    @objc func reloadPage(_ sender: Any?) {
        cancelPageRetry()
        if let failedURL {
            self.failedURL = nil
            webView.load(URLRequest(url: failedURL))
        } else {
            webView.reload()
        }
    }
    /// ⌥⌘R：不用缓存，从服务器重新载入。
    @objc func reloadFromOrigin(_ sender: Any?) {
        cancelPageRetry()
        if let failedURL {
            self.failedURL = nil
            webView.load(URLRequest(url: failedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        } else {
            webView.reloadFromOrigin()
        }
    }
    /// ⌘0：页面缩放和文本缩放都回到 100%。
    @objc func actualSizePage(_ sender: Any?) {
        webView.pageZoom = 1
        WebViewSPI.setTextZoomFactor(1, on: webView)
    }
    @objc func zoomInPage(_ sender: Any?) {
        webView.pageZoom = Self.zoomLevels.first { $0 > webView.pageZoom + 0.001 } ?? webView.pageZoom
    }
    @objc func zoomOutPage(_ sender: Any?) {
        webView.pageZoom = Self.zoomLevels.last { $0 < webView.pageZoom - 0.001 } ?? webView.pageZoom
    }
    /// ⌥⌘+ / ⌥⌘-：只放大缩小文字（原生引擎桥接），档位和页面缩放一样。
    @objc func zoomTextIn(_ sender: Any?) { stepTextZoom(up: true) }
    @objc func zoomTextOut(_ sender: Any?) { stepTextZoom(up: false) }

    private func nextTextZoom(up: Bool) -> Double? {
        guard let current = WebViewSPI.textZoomFactor(of: webView) else { return nil }
        let levels = Self.zoomLevels.map(Double.init)
        return up ? levels.first { $0 > current + 0.001 } : levels.last { $0 < current - 0.001 }
    }

    private func stepTextZoom(up: Bool) {
        guard let next = nextTextZoom(up: up) else { return NSSound.beep() }
        WebViewSPI.setTextZoomFactor(next, on: webView)
    }

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }

    @objc func goBack(_ sender: Any?) {
        cancelPageRetry()
        failedURL = nil
        webView.goBack()
    }
    @objc func goForward(_ sender: Any?) {
        cancelPageRetry()
        failedURL = nil
        webView.goForward()
    }
    /// ⇧⌘H：打开环境的起始网址；没设时回到起始页。
    @objc func goHome(_ sender: Any?) {
        cancelPageRetry()
        if let start = session.profile.startURL {
            open(start)
        } else {
            failedURL = nil
            showingHome = true
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            updateState()
        }
    }
    @objc func copyPageURL(_ sender: Any?) {
        guard allowUI(.unknown) else { return }
        guard let url = displayURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }
    @objc func toggleInspectable(_ sender: Any?) { session.toggleInspectable(sender) }

    // MARK: 开发

    /// ⌥⌘I / ⌥⌘C：打开网页检查器 / JavaScript 控制台（原生引擎桥接）。
    @objc func showWebInspector(_ sender: Any?) { openInspector(.show) }
    @objc func showJavaScriptConsole(_ sender: Any?) { openInspector(.showConsole) }

    private func openInspector(_ action: WebViewSPI.InspectorAction) {
        guard allowUI(.unknown) else { return }
        if !session.inspectable { session.toggleInspectable(nil) }
        webView.isInspectable = true
        if case .failure(let failure) = WebViewSPI.inspector(action, on: webView) {
            FileHandle.standardError.write(Data("[inspector] \(action.rawValue) 失败：\(failure)\n".utf8))
            NSSound.beep()
        }
    }

    /// ⌥⌘U：显示服务器发来的页面原文（取不到时退回当前 DOM）。
    @objc func showPageSource(_ sender: Any?) {
        guard allowUI(.openWindow) else { return }
        guard let url = displayURL else { return }
        let title = webView.title?.isEmpty == false ? webView.title! : (url.host ?? url.absoluteString)
        let started = WebViewSPI.mainResourceData(of: webView) { [weak self] data in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.session.showSource(PageSourceWindowController.decode(data), title: title, url: url, relativeTo: self.window)
            } else {
                self.showSourceFromDOM(title: title, url: url)
            }
        }
        if case .failure = started { showSourceFromDOM(title: title, url: url) }
    }

    private func showSourceFromDOM(title: String, url: URL) {
        webView.documentHTML { [weak self] html in
            guard let self, let html else { return NSSound.beep() }
            self.session.showSource(html, title: title, url: url, relativeTo: self.window)
        }
    }

    // MARK: 窗口与标签

    @objc func cycleWindowsForward(_ sender: Any?) { session.cycleWindows(forward: true) }
    @objc func cycleWindowsBackward(_ sender: Any?) { session.cycleWindows(forward: false) }

    /// 复制标签页：在当前窗口新开一个标签，打开同一个网址。
    @objc func duplicateTab(_ sender: Any?) { guard allowUI(.openTab) else { return }; session.openTab(in: self, url: displayURL) }

    /// ⌘1…⌘8 切到第 1…8 个标签，⌘9 切到最后一个（菜单项的 tag 是数字）。
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag else { return }
        selectTab(number: number)
    }

    func selectTab(number: Int) {
        guard allowUI(.cycleWindow) else { return }
        let tabs = tabs
        guard let target = Self.tab(number: number, in: tabs) else { return }
        window.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    static func tab<T>(number: Int, in tabs: [T]) -> T? {
        if number >= 9 { return tabs.last }
        return number >= 1 && number <= tabs.count ? tabs[number - 1] : nil
    }

    @objc private func showTabOverview(_ sender: Any?) { guard allowUI(.unknown) else { return }; window.toggleTabOverview(sender) }

    /// ⌥⌘L：显示 / 收起下载列表。
    @objc func toggleDownloads(_ sender: Any?) {
        guard allowUI(.download) else { return }
        if let popover = downloadsPopover, popover.isShown {
            popover.performClose(sender)
        } else {
            showDownloads(sender)
        }
    }

    @objc private func showDownloads(_ sender: Any?) {
        guard allowUI(.download) else { return }
        downloadsChanged()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = session.downloads.makePopoverContent()
        if let view = sender as? NSView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.downloads }) {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: addressBar.bounds, of: addressBar, preferredEdge: .minY)
        }
        downloadsPopover = popover
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return webView.canGoBack && !arrowKeyWhileEditing(item)
        case #selector(goForward(_:)): return webView.canGoForward && !arrowKeyWhileEditing(item)
        case #selector(stopLoading(_:)): return webView.isLoading
        case #selector(actualSizePage(_:)): return webView.pageZoom != 1 || (WebViewSPI.textZoomFactor(of: webView) ?? 1) != 1
        case #selector(zoomInPage(_:)): return displayURL != nil && webView.pageZoom < (Self.zoomLevels.last ?? 3) - 0.001
        case #selector(zoomOutPage(_:)): return displayURL != nil && webView.pageZoom > (Self.zoomLevels.first ?? 0.5) + 0.001
        case #selector(zoomTextIn(_:)): return displayURL != nil && nextTextZoom(up: true) != nil
        case #selector(zoomTextOut(_:)): return displayURL != nil && nextTextZoom(up: false) != nil
        case #selector(printPage(_:)), #selector(reloadPage(_:)), #selector(reloadFromOrigin(_:)), #selector(savePageAs(_:)),
             #selector(exportPDF(_:)), #selector(copyPageURL(_:)), #selector(showPageSource(_:)), #selector(useSelectionForFind(_:)),
             #selector(showFind(_:)), #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)), #selector(duplicateTab(_:)):
            return displayURL != nil
        case #selector(goHome(_:)): return displayURL != nil || session.profile.startURL != nil
        case #selector(closeOtherTabs(_:)): return tabs.count > 1
        case #selector(reopenClosedTab(_:)): return !session.closedTabURLs.isEmpty
        case #selector(selectTabByNumber(_:)): return Self.tab(number: item.tag, in: tabs) != nil
        case #selector(showWebInspector(_:)), #selector(showJavaScriptConsole(_:)): return displayURL != nil && WebViewSPI.hasInspector(webView)
        case #selector(toggleInspectable(_:)): return session.validateMenuItem(item)
        case #selector(autofillCurrentPage(_:)): return displayURL != nil
        case #selector(showSavedPasswords(_:)): return true
        default: return true
        }
    }

    /// ⌘← / ⌘→ / ⌥← / ⌥→ 在地址栏、查找栏里是移到行首 / 行尾 / 上一词：这时让菜单不接，按键交给文本框。
    private func arrowKeyWhileEditing(_ item: NSMenuItem) -> Bool {
        guard [BrowserMenu.leftArrow, BrowserMenu.rightArrow].contains(item.keyEquivalent) else { return false }
        guard let responder = window.firstResponder else { return false }
        return responder is NSText || responder is NSTextField || responder is NSTextView
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.back: return webView.canGoBack
        case Item.forward: return webView.canGoForward
        case Item.autofill: return displayURL != nil || !session.webCredentialStore.all().isEmpty
        default: return true
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.profile, Item.back, Item.forward, .flexibleSpace, Item.address, .flexibleSpace, Item.autofill, Item.bookmarks, Item.bookmarksList, Item.share, Item.newTab, Item.tabOverview]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Item.downloads]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Item.profile:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = ProfileBadge(profile: session.profile, accent: session.accent, isPrivate: session.isPrivate)
            item.label = "环境"
            item.toolTip = session.startPageDetails.joined(separator: "\n")
            return item
        case Item.back:
            return button(identifier, symbol: "chevron.left", label: "后退", action: #selector(goBack(_:)))
        case Item.forward:
            return button(identifier, symbol: "chevron.right", label: "前进", action: #selector(goForward(_:)))
        case Item.address:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = addressBar
            item.label = "地址"
            item.visibilityPriority = .high
            return item
        case Item.autofill:
            let item = button(identifier, symbol: "key.fill", label: "自动填充", action: #selector(showAutofillPopover(_:)))
            item.toolTip = "自动填充与密码 (⌥⌘F)"
            return item
        case Item.bookmarks:
            guard controllerPolicy == .interactive, session.bookmarkWorkspace != nil else { return nil }
            let item = button(identifier, symbol: "star", label: "添加书签", action: #selector(addBookmark(_:)))
            item.toolTip = "添加或修改书签 (⌘D)"
            return item
        case Item.bookmarksList:
            guard controllerPolicy == .interactive, session.bookmarkWorkspace != nil else { return nil }
            let item = button(identifier, symbol: "books.vertical", label: "收藏夹", action: #selector(showBookmarksList(_:)))
            item.toolTip = "打开收藏夹列表 (⌥⌘B)"
            return item
        case Item.share:
            // Suppress the control during construction without reporting a share request.
            guard controllerPolicy == .interactive else { return nil }
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.delegate = self
            item.label = "共享"
            item.toolTip = "共享"
            return item
        case Item.downloads:
            return button(identifier, symbol: "arrow.down.circle", label: "下载", action: #selector(showDownloads(_:)))
        case Item.newTab:
            return button(identifier, symbol: "plus", label: "新建标签页", action: #selector(newTab(_:)))
        case Item.tabOverview:
            return button(identifier, symbol: "square.on.square", label: "显示所有标签页", action: #selector(showTabOverview(_:)))
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    @objc func addBookmark(_ sender: Any?) {
        showBookmarks(sender)
    }

    @objc private func showBookmarks(_ sender: Any?) {
        guard controllerPolicy == .interactive,
              (window as? NonActivatingBrowserWindow)?.manualInteractionEnabled == true,
              let workspace = session.bookmarkWorkspace else { return }

        if let existing = bookmarksPopover, existing.isShown {
            existing.performClose(nil)
            bookmarksPopover = nil
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient

        let bubbleView = BrowserBookmarkBubbleView(
            workspace: workspace,
            profileID: session.profile.id,
            currentURL: displayURL,
            currentTitle: webView.title ?? displayURL?.host ?? "网页",
            onNavigate: { [weak self] url in
                self?.bookmarksPopover?.performClose(nil)
                self?.open(url)
            },
            onStateChanged: { [weak self] in
                self?.updateBookmarkStar()
            },
            onOpenAllBookmarks: { [weak self] in
                self?.showBookmarksList(nil)
            },
            onClose: { [weak self] in
                self?.bookmarksPopover?.performClose(nil)
            }
        )

        popover.contentViewController = NSHostingController(rootView: bubbleView)

        if let view = sender as? NSView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.bookmarks }) {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: addressBar.bounds, of: addressBar, preferredEdge: .minY)
        }
        bookmarksPopover = popover
    }

    @objc func showBookmarksList(_ sender: Any?) {
        guard controllerPolicy == .interactive,
              (window as? NonActivatingBrowserWindow)?.manualInteractionEnabled == true,
              let workspace = session.bookmarkWorkspace else { return }

        if let existing = bookmarksListPopover, existing.isShown {
            existing.performClose(nil)
            bookmarksListPopover = nil
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient

        let listView = BrowserBookmarksListView(
            workspace: workspace,
            profile: session.profile,
            currentURL: displayURL,
            currentTitle: webView.title ?? displayURL?.host ?? "网页",
            onNavigate: { [weak self] url in
                self?.bookmarksListPopover?.performClose(nil)
                self?.open(url)
            },
            onOpenInNewTab: { [weak self] url in
                guard let self else { return }
                self.session.openTab(in: self, url: url, background: true)
            },
            onOpenStarBubble: { [weak self] in
                self?.bookmarksListPopover?.performClose(nil)
                self?.showBookmarks(sender)
            },
            onClose: { [weak self] in
                self?.bookmarksListPopover?.performClose(nil)
            }
        )

        popover.contentViewController = NSHostingController(rootView: listView)

        if let view = sender as? NSView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.bookmarksList }) {
            popover.show(relativeTo: item)
        } else if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.bookmarks }) {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: addressBar.bounds, of: addressBar, preferredEdge: .minY)
        }
        bookmarksListPopover = popover
    }

    func updateBookmarkStar() {
        guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.bookmarks }) else { return }
        guard let url = displayURL, let workspace = session.bookmarkWorkspace else {
            item.image = NSImage(systemSymbolName: "star", accessibilityDescription: "收藏夹")
            return
        }
        let isBookmarked: Bool
        if let snapshot = try? BookmarkStore(workspace: workspace, profileID: session.profile.id).load() {
            let normalized = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            isBookmarked = snapshot.items.contains {
                $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalized
            }
        } else {
            isBookmarked = false
        }
        item.image = NSImage(systemSymbolName: isBookmarked ? "star.fill" : "star", accessibilityDescription: isBookmarked ? "修改书签" : "添加书签")
    }

    private func bookmarkError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "无法处理收藏"; alert.informativeText = (error as? LocalizedError)?.errorDescription ?? "请重试。"; alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    // MARK: - 密码与表单自动填写

    func handleAutofillScriptMessage(_ message: WKScriptMessage) {
        guard controllerPolicy == .interactive,
              (window as? NonActivatingBrowserWindow)?.manualInteractionEnabled == true else { return }

        guard message.name == FormAutofillBridge.messageHandlerName,
              let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {
        case "credentialsSubmitted":
            guard let domain = dict["domain"] as? String,
                  let pass = dict["password"] as? String, !pass.isEmpty else { return }
            let user = (dict["username"] as? String) ?? ""
            promptSavePasswordIfNeeded(domain: domain, username: user, password: pass)

        case "fieldFocused", "requestAutofillOptions":
            guard let domain = dict["domain"] as? String, !domain.isEmpty else { return }
            let creds = session.webCredentialStore.credentials(for: domain)
            guard !creds.isEmpty else {
                webView.evaluateJavaScript("window.__safarierDismissAutofillPopup && window.__safarierDismissAutofillPopup();", completionHandler: nil)
                return
            }
            FormAutofillBridge.showAutofillOptions(in: webView, credentials: creds)

        default:
            break
        }
    }

    func promptSavePasswordIfNeeded(domain: String, username: String, password: String) {
        guard controllerPolicy == .interactive,
              (window as? NonActivatingBrowserWindow)?.manualInteractionEnabled == true else { return }

        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanDomain.isEmpty, !password.isEmpty else { return }

        guard !session.webCredentialStore.isNeverSave(for: cleanDomain) else { return }

        let existing = session.webCredentialStore.credentials(for: cleanDomain)
        if existing.contains(where: { $0.username == username && $0.password == password }) {
            return
        }

        showPasswordSaveBanner(domain: cleanDomain, username: username, password: password)
    }

    func showPasswordSaveBanner(domain: String, username: String, password: String) {
        dismissPasswordSaveBanner()

        guard let contentView = window.contentView else { return }

        let bannerView = PasswordSaveBannerView(
            domain: domain,
            username: username,
            password: password,
            onSave: { [weak self] in
                guard let self else { return }
                _ = try? self.session.webCredentialStore.save(domain: domain, username: username, password: password)
                self.dismissPasswordSaveBanner()
            },
            onNotNow: { [weak self] in
                self?.dismissPasswordSaveBanner()
            },
            onNever: { [weak self] in
                guard let self else { return }
                try? self.session.webCredentialStore.setNeverSave(for: domain)
                self.dismissPasswordSaveBanner()
            }
        )

        let host = NSHostingView(rootView: bannerView)
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host)

        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            host.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            host.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            host.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        ])

        passwordSaveBannerHost = host
    }

    func dismissPasswordSaveBanner() {
        guard let host = passwordSaveBannerHost else { return }
        passwordSaveBannerHost = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            host.animator().alphaValue = 0
        }, completionHandler: {
            host.removeFromSuperview()
        })
    }

    func autofillMatchingCredentialsIfAvailable(force: Bool = false) {
        guard controllerPolicy == .interactive,
              (window as? NonActivatingBrowserWindow)?.manualInteractionEnabled == true else { return }
        if !force && hasAutofilledCurrentPage { return }
        guard let domain = displayURL?.host ?? webView.url?.host, !domain.isEmpty else { return }
        let creds = session.webCredentialStore.credentials(for: domain)
        guard let best = creds.first else { return }
        FormAutofillBridge.fillCredentials(in: webView, credential: best) { [weak self] filled in
            if filled {
                self?.hasAutofilledCurrentPage = true
            }
        }
    }

    @objc func autofillCurrentPage(_ sender: Any?) {
        guard let domain = displayURL?.host ?? webView.url?.host, !domain.isEmpty else { return }
        let creds = session.webCredentialStore.credentials(for: domain)
        if creds.count == 1, let single = creds.first {
            FormAutofillBridge.fillCredentials(in: webView, credential: single) { [weak self] filled in
                if filled { self?.hasAutofilledCurrentPage = true }
            }
        } else {
            showAutofillPopover(sender)
        }
    }

    @objc func showAutofillPopover(_ sender: Any?) {
        guard controllerPolicy == .interactive,
              (window as? NonActivatingBrowserWindow)?.manualInteractionEnabled == true else { return }

        if let existing = autofillPopover, existing.isShown {
            existing.performClose(nil)
            autofillPopover = nil
            return
        }

        let domain = displayURL?.host ?? webView.url?.host ?? ""
        let creds = domain.isEmpty ? [] : session.webCredentialStore.credentials(for: domain)

        let popover = NSPopover()
        popover.behavior = .transient

        let bubbleView = AutofillBubbleView(
            domain: domain.isEmpty ? "当前页面" : domain,
            credentials: creds,
            onFill: { [weak self] cred in
                guard let self else { return }
                self.autofillPopover?.performClose(nil)
                FormAutofillBridge.fillCredentials(in: self.webView, credential: cred) { [weak self] filled in
                    if filled { self?.hasAutofilledCurrentPage = true }
                }
            },
            onOpenManager: { [weak self] in
                guard let self else { return }
                self.autofillPopover?.performClose(nil)
                self.showSavedPasswords(sender)
            }
        )

        popover.contentViewController = NSHostingController(rootView: bubbleView)

        if let view = sender as? NSView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Item.autofill }) {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: addressBar.bounds, of: addressBar, preferredEdge: .minY)
        }
        autofillPopover = popover
    }

    @objc func showSavedPasswords(_ sender: Any?) {
        guard controllerPolicy == .interactive else { return }

        if let existing = passwordsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "已保存密码 - \(session.profile.name)"
        win.center()
        win.isReleasedWhenClosed = false

        let passwordsView = SavedPasswordsView(
            profileName: session.profile.name,
            isEphemeral: session.profile.mode == .ephemeral || session.isPrivate,
            store: session.webCredentialStore,
            onDismiss: { [weak win] in
                win?.close()
            }
        )

        win.contentView = NSHostingView(rootView: passwordsView)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        passwordsWindow = win
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        fputs("SHARE_QUERY monotonic_ms=\(ms) background=\(controllerPolicy == .automationBackground) appActive=\(NSApp?.isActive ?? false) windowKey=\(window.isKeyWindow) windowMain=\(window.isMainWindow)\n", stderr)
        #endif
        guard controllerPolicy == .interactive else { return [] }
        return displayURL.map { [$0] } ?? []
    }

    /// AppKit may query toolbar contents without a user requesting a share.
    /// Suppress data in automation mode without reporting a UI action.
    static func sharingItems(session: BrowserSession, displayURL: URL?) -> [Any] {
        guard session.executionPolicy == .interactive else { return [] }
        return displayURL.map { [$0] } ?? []
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard allowUI(.windowClose) else { return false }
        if session.profile.mode == .persistent, !session.isClosingWindow, session.openControllers.count == 1 {
            session.saveSessionState()
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        configureToolbarTranslucency()
        focusAddressIfWanted()
        session.tabSelectionChanged()
    }

    /// 只有空白的新标签 / 新窗口才把焦点放进地址栏；网页打开的视图、已经开始载入的标签不抢焦点。
    private var shouldFocusAddress: Bool {
        wantsAddressFocus && !isPopup && webView.url == nil && !webView.isLoading
    }

    private func focusAddressIfWanted() {
        guard controllerPolicy == .interactive else { wantsAddressFocus = false; return }
        guard shouldFocusAddress else { wantsAddressFocus = false; return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.controllerPolicy == .interactive else { self.wantsAddressFocus = false; return }
            guard self.shouldFocusAddress else { self.wantsAddressFocus = false; return }
            self.wantsAddressFocus = false
            self.addressBar.focus()
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelPageRetry()
        if controllerPolicy == .automationBackground {
            onAutomationNavigation?(.closed)
            session.onAutomationUIBlocked?(.windowClose)
        }
        passwordSaveBannerHost?.removeFromSuperview()
        passwordSaveBannerHost = nil
        autofillPopover?.performClose(nil)
        autofillPopover = nil
        passwordsWindow?.close()
        passwordsWindow = nil
        session.recordClosedTab(displayURL)
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        session.controllerClosed(self)
    }

    // MARK: - WKUIDelegate

    /// 网页的 target=_blank / window.open：必须用 WebKit 给的 configuration 新建 WebView 并返回，
    /// window.opener 才在（第三方登录弹窗靠它）。带尺寸的 window.open 开成窗口，其它开成标签，和 Safari 一样。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard allowUI(navigationAction.targetFrame == nil ? .targetBlank : .windowOpen) else { return nil }
        let forcedWindow = self.webView.openNextAsWindow
        let forcedBackground = self.webView.openNextInBackgroundTab
        self.webView.openNextAsWindow = false
        self.webView.openNextInBackgroundTab = false
        if forcedWindow || windowFeatures.width != nil || windowFeatures.height != nil {
            let size = NSSize(
                width: CGFloat(windowFeatures.width?.doubleValue ?? Double(window.contentLayoutRect.width)),
                height: CGFloat(windowFeatures.height?.doubleValue ?? Double(window.contentLayoutRect.height))
            )
            return session.openWindow(url: nil, configuration: configuration, contentSize: size).webView
        }
        // ⌘点按 / 中键点按 target=_blank 链接也走这里：开在后台（加 ⇧ 切过去），和普通链接一致。
        let flags = navigationAction.modifierFlags
        let background = forcedBackground || ((flags.contains(.command) || navigationAction.buttonNumber == 2) && !flags.contains(.shift))
        return session.openTab(in: self, url: nil, configuration: configuration, background: background).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        cancelPageRetry()
        // For automation, windowClose denotes target loss, not a resumable UI block.
        if controllerPolicy == .automationBackground { onAutomationNavigation?(.closed) }
        guard allowUI(.windowClose) else { return }
        window.close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard routeUI(.alert, perform: { true }, deny: { completionHandler(); return false }) else { return }
        let alert = pageAlert(frame, message)
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard routeUI(.confirm, perform: { true }, deny: { completionHandler(false); return false }) else { return }
        let alert = pageAlert(frame, message)
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard routeUI(.prompt, perform: { true }, deny: { completionHandler(nil); return false }) else { return }
        let alert = pageAlert(frame, prompt)
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    private func pageAlert(_ frame: WKFrameInfo, _ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "\(frame.securityOrigin.host.isEmpty ? "此网页" : frame.securityOrigin.host) 显示："
        alert.informativeText = message
        return alert
    }

    /// <input type=file>
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard routeUI(parameters.allowsDirectories ? .directorySelection : .fileSelection, perform: { true }, deny: { completionHandler(nil); return false }) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// 摄像头 / 麦克风：和 Safari 一样每次询问。
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let request: BackgroundUIRequest
        switch type {
        case .camera, .cameraAndMicrophone: request = .camera
        case .microphone: request = .microphone
        @unknown default: request = .unknown
        }
        guard routeUI(request, perform: { true }, deny: { decisionHandler(.deny); return false }) else { return }
        let what: String
        switch type {
        case .camera: what = "摄像头"
        case .microphone: what = "麦克风"
        case .cameraAndMicrophone: what = "摄像头和麦克风"
        @unknown default: what = "媒体设备"
        }
        let alert = NSAlert()
        alert.messageText = "允许「\(origin.host)」使用你的\(what)吗？"
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "不允许")
        alert.beginSheetModal(for: window) { decisionHandler($0 == .alertFirstButtonReturn ? .grant : .deny) }
    }

    /// WKWebView 默认不告诉网页窗口有多大，网页读到 outerWidth = outerHeight = 0（真 Safari 不会这样，
    /// 指纹脚本常拿它识别嵌入式 WebView）。实现这个委托回调，WebKit 才把真实窗口尺寸交给网页。
    /// 开了高级隐私保护时 WebKit 会让 outer 等于视口，和真 Safari 无痕窗口实测一致。
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewGetWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(window.frame)
    }

    // No verified public beforeunload-specific hook is installed here; G2 remains unverified.

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        if navigationAction.targetFrame?.isMainFrame == true || navigationAction.targetFrame == nil { traceRegisteredPolicy("policy.entry", action: navigationAction) }
        #endif
        if controllerPolicy == .interactive {
            let request = navigationAction.request
            pageRetry.observeAction(url: request.url, mainFrame: navigationAction.targetFrame?.isMainFrame == true,
                get: request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil,
                explicit: navigationAction.navigationType == .other && !navigationAction.shouldPerformDownload)
            if !pageRetry.isActive { cancelPageRetry() }
        }
        if let request = BackgroundPagePolicy.navigationRequest(for: navigationAction.request.url),
           !routeUI(request, perform: { true }, deny: { decisionHandler(.cancel); return false }) { return }
        if navigationAction.shouldPerformDownload {
            guard routeUI(.download, perform: { true }, deny: { decisionHandler(.cancel); return false }) else { return }
            decisionHandler(.download)
            return
        }
        // ⌘点按 / 中键点按链接：后台新标签（加 ⇧ 切过去）；⌥点按：下载。和 Safari 一样。
        // 只管在本页里点的链接：新窗口 / 新标签的第一次载入也带着打开它的那次点击（右键菜单、⌘点按）的信息，不能再分流一次。
        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated, navigationAction.sourceFrame.webView === webView {
            switch Self.linkClickDecision(targetIsMainFrame: navigationAction.targetFrame.map(\.isMainFrame), flags: flags, buttonNumber: navigationAction.buttonNumber) {
            case .openTab(let background):
                if let url = navigationAction.request.url {
                    guard routeUI(.openTab, perform: { true }, deny: { decisionHandler(.cancel); return false }) else { return }
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
                    traceRegisteredPolicy("policy.cancel.openTab", action: navigationAction)
                    #endif
                    decisionHandler(.cancel)
                    session.openTab(in: self, url: url, background: background)
                    return
                }
            case .download:
                guard routeUI(.download, perform: { true }, deny: { decisionHandler(.cancel); return false }) else { return }
                decisionHandler(.download)
                return
            case .allow:
                break
            }
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        if navigationAction.targetFrame?.isMainFrame == true || navigationAction.targetFrame == nil { traceRegisteredPolicy("policy.allow", action: navigationAction) }
        #endif
        decisionHandler(.allow)
    }

    enum LinkClickDecision: Equatable {
        case allow
        case openTab(background: Bool)
        case download
    }

    /// 本页里点链接的分流。`targetIsMainFrame` 为 nil 表示 target=_blank / 新窗口：不在这里截，
    /// 交给 createWebViewWith 用 WebKit 给的 configuration 开新标签，window.opener 和 Referer 才保留（那里同样按 ⌘ / 中键开后台标签）。
    /// 主框架里 ⌘点按 / 中键点按开新标签（不加 ⇧ 在后台）；主框架或新窗口的 ⌥点按下载；子框架里的链接照常。
    static func linkClickDecision(targetIsMainFrame: Bool?, flags: NSEvent.ModifierFlags, buttonNumber: Int) -> LinkClickDecision {
        if targetIsMainFrame == true, flags.contains(.command) || buttonNumber == 2 {
            return .openTab(background: !flags.contains(.shift))
        }
        if targetIsMainFrame != false, flags.contains(.option) { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || (navigationResponse.isForMainFrame && disposition.hasPrefix("attachment")) {
            guard routeUI(.download, perform: { true }, deny: { decisionHandler(.cancel); return false }) else { return }
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        routeUI(.download, perform: { session.downloads.track(download) }, deny: { download.cancel { _ in } })
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        routeUI(.download, perform: { session.downloads.track(download) }, deny: { download.cancel { _ in } })
    }

    /// HTTP 基本 / 摘要认证：弹出用户名密码，只在本次会话里记住。
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust { pageRetry.disallowCurrentRetry() }
        // Proxy flags and proposed credentials are not proof of a bound automatic proxy path.
        let request: BackgroundUIRequest = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate ? .clientCertificate : .httpAuthentication
        guard routeUI(request, perform: { true }, deny: { completionHandler(.cancelAuthenticationChallenge, nil); return false }) else { return }
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 3 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "登录「\(challenge.protectionSpace.host)」"
        alert.informativeText = challenge.protectionSpace.realm.map { "网站要求输入用户名和密码（\($0)）。" } ?? "网站要求输入用户名和密码。"
        let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
        user.placeholderString = "用户名"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "密码"
        let stack = NSStackView(views: [user, password])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        alert.accessoryView = stack
        alert.addButton(withTitle: "登录")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = user
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        traceRegisteredLoad("didStart", navigation: navigation)
        #endif
        if let navigation, pageRetry.isRetired(navigation) { return }
        if let navigation, !pageRetry.matches(navigation) { cancelPageRetry() }
        hasAutofilledCurrentPage = false
        if controllerPolicy == .automationBackground { onAutomationNavigation?(.started(navigation)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        traceRegisteredLoad("didFinish", navigation: navigation)
        #endif
        if let navigation, pageRetry.isRetired(navigation) { return }
        if let navigation, let ticket = pageRetry.expiryTicket,
           pageRetry.matchesActive(ticket, navigation: navigation), pageRetry.isExpired(ticket, now: retryNow) {
            expirePageRetry(ticket); return
        }
        if let navigation, pageRetry.matches(navigation) { cancelPageRetry() }
        if controllerPolicy == .automationBackground { onAutomationNavigation?(.finished(navigation)) }
        updateFavicon()
    }

    /// 真正打开了别的网页（点链接、手势后退等）：出错页记下的网址作废，⌘R 重新载入的是当前页。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        traceRegisteredLoad("didCommit", navigation: navigation)
        #endif
        if let navigation, pageRetry.isRetired(navigation) { return }
        if let navigation { pageRetry.disallowRetry(navigation) }
        targetURL = nil
        hasAutofilledCurrentPage = false
        if let failedURL, webView.url != failedURL { self.failedURL = nil }
        if controllerPolicy == .automationBackground { onAutomationNavigation?(.committed(navigation)) }
        dismissPasswordSaveBanner()
        updateFavicon()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        traceRegisteredLoad("didFailProvisional", navigation: navigation, error: error)
        #endif
        if let navigation, pageRetry.isRetired(navigation) { return }
        if controllerPolicy == .automationBackground { onAutomationNavigation?(.failed(navigation, error, provisional: true)); return }
        if retryProvisional(navigation, error: error) { return }
        cancelPageRetry(); targetURL = nil
        showErrorPage(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
        traceRegisteredLoad("didFail", navigation: navigation, error: error)
        #endif
        if let navigation, pageRetry.isRetired(navigation) { return }
        if controllerPolicy == .automationBackground { onAutomationNavigation?(.failed(navigation, error, provisional: false)); return }
        cancelPageRetry(); targetURL = nil
        showErrorPage(error)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let navigation, pageRetry.isRetired(navigation) { return }
        if let navigation { pageRetry.disallowRetry(navigation) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelPageRetry()
        // Automation treats process termination as target loss, never as a reload.
        if controllerPolicy == .automationBackground { onAutomationNavigation?(.processTerminated) }
        guard allowUI(.windowClose) else { return }
        FileHandle.standardError.write(Data("[webcontent] 网页进程退出，重新载入\n".utf8))
        webView.reload()
    }

    /// 和 Safari 一样在页面里显示出错原因（不弹窗）。代理连不上时也走这里，不会改走直连。
    private func showErrorPage(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // 102 = 下载等策略变化打断了这次载入。
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        FileHandle.standardError.write(Data("[load-error] \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)\n".utf8))
        guard let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url else { return }
        failedURL = url
        let host = Self.escape(url.host ?? url.absoluteString)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>无法打开页面</title><style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system; margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center; background: Canvas; }
        main { max-width: 520px; text-align: center; color: GrayText; padding: 24px; }
        h1 { font-size: 22px; font-weight: 600; color: CanvasText; margin: 0 0 12px; }
        p { font-size: 14px; line-height: 1.5; margin: 0; }
        </style></head><body><main><h1>无法打开该页面</h1>
        <p>无法打开“\(host)”，因为：\(Self.escape(nsError.localizedDescription))</p></main></body></html>
        """
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 工具栏左侧的环境标识：彩色首字母 + 环境名；无痕环境像 Safari 一样标「私密浏览」。
@MainActor
final class ProfileBadge: NSView {
    init(profile: Profile, accent: NSColor, isPrivate: Bool) {
        super.init(frame: .zero)
        let letter = NSTextField(labelWithString: profile.name.first.map { String($0).uppercased() } ?? "?")
        letter.font = .systemFont(ofSize: 11, weight: .bold)
        letter.textColor = .white
        letter.alignment = .center
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accent.cgColor
        dot.layer?.cornerRadius = 5
        letter.translatesAutoresizingMaskIntoConstraints = false
        dot.addSubview(letter)
        let name = NSTextField(labelWithString: isPrivate ? "\(profile.name) · 私密浏览" : profile.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [dot, name])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 20),
            dot.heightAnchor.constraint(equalToConstant: 20),
            letter.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 浏览器顶部统一工具栏微半透明磨砂玻璃材质背景，与管理窗口顶部控制栏视觉质感完全对齐
@MainActor
final class ToolbarTranslucentBackgroundView: NSVisualEffectView {
    static let viewTag = 0x5442 // "TB"

    init() {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .active
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var tag: Int { Self.viewTag }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tint = isDark
            ? NSColor(red: 0x0C / 255.0, green: 0x10 / 255.0, blue: 0x18 / 255.0, alpha: 0.28)
            : NSColor(red: 0xE8 / 255.0, green: 0xEE / 255.0, blue: 0xF6 / 255.0, alpha: 0.25)
        tint.setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}
