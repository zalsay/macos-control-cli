import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

/// 浏览窗口的结构性检查：多标签 / 多窗口的创建与释放、窗口尺寸回调、地址栏焦点。
@MainActor
final class BrowserWindowTests: XCTestCase {
    private var session: BrowserSession!

    override func setUp() async throws {
        _ = NSApplication.shared
        let profile = Profile(name: "test", mode: .ephemeral)
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15")
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        session = BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics())
    }

    override func tearDown() async throws {
        for controller in session.openControllers { controller.window.close() }
        session = nil
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 快速连开连关标签：关掉的标签（控制器、窗口、WebView）都要被释放，不留在会话里。
    func testRapidNewAndCloseTabsReleasesEverything() {
        let first = session.openWindow(url: nil)
        weak var weakTab: BrowserWindowController?
        weak var weakWebView: WKWebView?
        autoreleasepool {
            var tabs: [BrowserWindowController] = []
            for _ in 0..<15 { tabs.append(session.openTab(in: first, url: nil)) }
            XCTAssertEqual(first.window.tabbedWindows?.count, 16)
            weakTab = tabs.last
            weakWebView = tabs.last?.webView
            for tab in tabs { tab.window.close() }
            tabs.removeAll()
        }
        spin()
        XCTAssertEqual(session.openControllers.count, 1)
        XCTAssertNil(weakTab, "关掉的标签控制器没有被释放（循环引用）")
        XCTAssertNil(weakWebView, "关掉的标签 WebView 没有被释放")
        XCTAssertTrue(first.window.tabbedWindows == nil || first.window.tabbedWindows?.count == 1)
    }

    func testClosingLastTabClosesWindowAndEmptiesSession() {
        let window = session.openWindow(url: nil)
        let tab = session.openTab(in: window, url: nil)
        tab.window.close()
        window.window.close()
        spin()
        XCTAssertTrue(session.openControllers.isEmpty)
    }

    /// 每个窗口和标签都要把真实窗口尺寸交给 WebKit，否则网页读到 outerWidth = outerHeight = 0。
    func testEveryTabReportsLiveWindowFrame() {
        let window = session.openWindow(url: nil, contentSize: NSSize(width: 900, height: 600))
        let tab = session.openTab(in: window, url: nil)
        for controller in [window, tab] {
            var reported: CGRect?
            controller.webViewGetWindowFrame(controller.webView) { reported = $0 }
            XCTAssertEqual(reported, controller.window.frame)
            XCTAssertGreaterThan(reported?.width ?? 0, 0)
        }
        // 改窗口大小后回调给的是新尺寸（不是创建时记下的值）。
        window.window.setContentSize(NSSize(width: 1000, height: 700))
        var resized: CGRect?
        window.webViewGetWindowFrame(window.webView) { resized = $0 }
        XCTAssertEqual(resized, window.window.frame)
        XCTAssertEqual(window.webView.uiDelegate as? BrowserWindowController, window)
        XCTAssertEqual(tab.webView.uiDelegate as? BrowserWindowController, tab)
    }

    /// 端到端：网页里读到的 outerWidth / outerHeight 就是窗口尺寸，outer − inner 是工具栏高度。
    func testPageSeesRealOuterSize() throws {
        let controller = session.openWindow(url: nil, contentSize: NSSize(width: 800, height: 500))
        let loaded = expectation(description: "loaded")
        controller.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://example.invalid/"))
        var result: [Double] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            controller.webView.evaluateJavaScript("[outerWidth, outerHeight, innerWidth, innerHeight]") { value, _ in
                result = (value as? [NSNumber])?.map(\.doubleValue) ?? []
                loaded.fulfill()
            }
        }
        wait(for: [loaded], timeout: 15)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.first, Double(controller.window.frame.width))
        XCTAssertEqual(result[1], Double(controller.window.frame.height))
        XCTAssertGreaterThan(result[1], result[3], "outerHeight 应当比 innerHeight 多出工具栏")
    }

    /// 地址栏获得焦点时显示完整网址并全选。
    func testAddressBarFocusSelectsWholeURL() {
        let bar = AddressBar(isPrivate: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        window.makeKeyAndOrderFront(nil)
        let url = URL(string: "https://www.example.com/path?q=1")!
        bar.update(url: url, isLoading: false, progress: 0, secure: true)
        bar.focus()
        spin()
        guard let editor = window.firstResponder as? NSTextView else { return XCTFail("焦点没有进地址栏：\(String(describing: window.firstResponder))") }
        XCTAssertEqual(editor.string, url.absoluteString)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (url.absoluteString as NSString).length))
        window.close()
    }

    func testToolbarIncludesBookmarksAndBookmarksList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "tb-test", mode: .persistent)
        try workspace.profiles.insert(profile)

        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15")
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        let sess = BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics(), workspace: workspace)
        defer {
            for c in sess.openControllers { c.window.close() }
        }

        let controller = sess.openWindow(url: nil)
        guard let tb = controller.window.toolbar else { return XCTFail("toolbar is nil") }
        let defaultIDs = controller.toolbarDefaultItemIdentifiers(tb)
        XCTAssertTrue(defaultIDs.contains(NSToolbarItem.Identifier("bookmarks")))
        XCTAssertTrue(defaultIDs.contains(NSToolbarItem.Identifier("bookmarksList")))
        let bookmarkItem = controller.toolbar(tb, itemForItemIdentifier: NSToolbarItem.Identifier("bookmarksList"), willBeInsertedIntoToolbar: false)
        XCTAssertNotNil(bookmarkItem)
        XCTAssertEqual(bookmarkItem?.label, "收藏夹")
    }

    func testBrowserMenuIncludesBookmarksSubmenu() {
        let menu = BrowserMenu.make()
        let bookmarksItem = menu.items.first(where: { $0.title == "书签" || $0.submenu?.title == "书签" })
        XCTAssertNotNil(bookmarksItem, "BrowserMenu 应当包含「书签」菜单")
        let sub = bookmarksItem?.submenu
        XCTAssertNotNil(sub)
        let titles = sub?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("显示收藏夹列表"))
        XCTAssertTrue(titles.contains("添加书签…"))
    }

    func testBrowserMenuIncludesNavigationShortcuts() {
        let menu = BrowserMenu.make()
        let historyItem = menu.items.first(where: { $0.title == "历史记录" || $0.submenu?.title == "历史记录" })
        XCTAssertNotNil(historyItem)
        let sub = historyItem?.submenu
        XCTAssertNotNil(sub)
        let backItems = sub?.items.filter { $0.action == #selector(BrowserActions.goBack(_:)) } ?? []
        let forwardItems = sub?.items.filter { $0.action == #selector(BrowserActions.goForward(_:)) } ?? []
        XCTAssertGreaterThanOrEqual(backItems.count, 3, "后退应包含 ⌘[、⌘←、⌥←")
        XCTAssertGreaterThanOrEqual(forwardItems.count, 3, "前进应包含 ⌘]、⌘→、⌥→")

        let backKeys = backItems.map { ($0.keyEquivalent, $0.keyEquivalentModifierMask) }
        XCTAssertTrue(backKeys.contains(where: { $0.0 == "[" && $0.1 == .command }))
        XCTAssertTrue(backKeys.contains(where: { $0.0 == BrowserMenu.leftArrow && $0.1 == .command }))
        XCTAssertTrue(backKeys.contains(where: { $0.0 == BrowserMenu.leftArrow && $0.1 == .option }))

        let forwardKeys = forwardItems.map { ($0.keyEquivalent, $0.keyEquivalentModifierMask) }
        XCTAssertTrue(forwardKeys.contains(where: { $0.0 == "]" && $0.1 == .command }))
        XCTAssertTrue(forwardKeys.contains(where: { $0.0 == BrowserMenu.rightArrow && $0.1 == .command }))
        XCTAssertTrue(forwardKeys.contains(where: { $0.0 == BrowserMenu.rightArrow && $0.1 == .option }))
    }

    func testWindowAndWebViewMouseSideButtonsNavigation() {
        let controller = session.openWindow(url: nil)
        let window = controller.window

        // 测试按下侧键3（后退）和侧键4（前进）被安全处理
        let cgDown3 = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center)!
        cgDown3.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let eventDown3 = NSEvent(cgEvent: cgDown3)!
        window.sendEvent(eventDown3)

        let cgUp3 = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center)!
        cgUp3.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let eventUp3 = NSEvent(cgEvent: cgUp3)!
        window.sendEvent(eventUp3)

        let cgDown4 = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center)!
        cgDown4.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        let eventDown4 = NSEvent(cgEvent: cgDown4)!
        window.sendEvent(eventDown4)

        let cgUp4 = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center)!
        cgUp4.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        let eventUp4 = NSEvent(cgEvent: cgUp4)!
        window.sendEvent(eventUp4)

        // webView 上的鼠标侧键事件同样被安全处理
        controller.webView.otherMouseDown(with: eventDown3)
        controller.webView.otherMouseUp(with: eventUp3)
        controller.webView.otherMouseDown(with: eventDown4)
        controller.webView.otherMouseUp(with: eventUp4)
    }

    func testWindowKeyboardNavigationEquivalents() {
        let controller = session.openWindow(url: nil)
        let window = controller.window

        // ⌘[ (后退) 和 ⌘] (前进)
        let cmdBracketLeft = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33)!
        _ = window.performKeyEquivalent(with: cmdBracketLeft)

        let cmdBracketRight = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "]", charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30)!
        _ = window.performKeyEquivalent(with: cmdBracketRight)

        // ⌘← 和 ⌘→
        let cmdLeft = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: BrowserMenu.leftArrow, charactersIgnoringModifiers: BrowserMenu.leftArrow, isARepeat: false, keyCode: 123)!
        _ = window.performKeyEquivalent(with: cmdLeft)

        let cmdRight = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: BrowserMenu.rightArrow, charactersIgnoringModifiers: BrowserMenu.rightArrow, isARepeat: false, keyCode: 124)!
        _ = window.performKeyEquivalent(with: cmdRight)

        // ⌥← 和 ⌥→
        let optLeft = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: BrowserMenu.leftArrow, charactersIgnoringModifiers: BrowserMenu.leftArrow, isARepeat: false, keyCode: 123)!
        _ = window.performKeyEquivalent(with: optLeft)

        let optRight = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: BrowserMenu.rightArrow, charactersIgnoringModifiers: BrowserMenu.rightArrow, isARepeat: false, keyCode: 124)!
        _ = window.performKeyEquivalent(with: optRight)
    }

    func testArrowKeyWhileEditingAllowsTextEditing() {
        let controller = session.openWindow(url: nil)
        let backItem = NSMenuItem(title: "后退", action: #selector(BrowserActions.goBack(_:)), keyEquivalent: BrowserMenu.leftArrow)
        backItem.keyEquivalentModifierMask = .command

        // 当没有编辑文本且不可后退时，validateMenuItem 返回 false
        XCTAssertFalse(controller.validateMenuItem(backItem))

        // 当在 NSTextView 中编辑文本时，即使 webView.canGoBack，validateMenuItem 也应返回 false（不拦截文本移动光标）
        let textView = NSTextView()
        controller.window.contentView?.addSubview(textView)
        controller.window.makeFirstResponder(textView)
        XCTAssertFalse(controller.validateMenuItem(backItem))
    }

    func testAutofillToolbarItemAndMenuItems() throws {
        let controller = session.openWindow(url: nil)
        let toolbar = try XCTUnwrap(controller.window.toolbar)

        // 工具栏包含自动填充项
        let identifiers = controller.toolbarDefaultItemIdentifiers(toolbar)
        let autofillID = NSToolbarItem.Identifier("autofill")
        XCTAssertTrue(identifiers.contains(autofillID))

        let item = controller.toolbar(toolbar, itemForItemIdentifier: autofillID, willBeInsertedIntoToolbar: true)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.label, "自动填充")
        XCTAssertEqual(item?.toolTip, "自动填充与密码 (⌥⌘F)")

        // 菜单项校验
        let autofillMenuItem = NSMenuItem(title: "自动填写表单", action: #selector(BrowserActions.autofillCurrentPage(_:)), keyEquivalent: "f")
        // 起始页没有 URL 时不可填写
        XCTAssertFalse(controller.validateMenuItem(autofillMenuItem))

        let passwordsMenuItem = NSMenuItem(title: "已保存密码…", action: #selector(BrowserActions.showSavedPasswords(_:)), keyEquivalent: "p")
        // 管理密码菜单项始终可用
        XCTAssertTrue(controller.validateMenuItem(passwordsMenuItem))
    }

    func testAutofillBridgeScriptRegisteredInSessionConfiguration() {
        let scripts = session.configuration.userContentController.userScripts
        let hasAutofillScript = scripts.contains { $0.source.contains("__safarierAutofillInstalled") }
        XCTAssertTrue(hasAutofillScript, "BrowserSession should register FormAutofillBridge.userScript in userContentController")

        let hasDropdownScript = scripts.contains { $0.source.contains("__safarierShowAutofillOptions") }
        XCTAssertTrue(hasDropdownScript, "userScript should contain __safarierShowAutofillOptions function for input dropdown")
    }

    func testShowAutofillOptionsDispatchesToWebView() throws {
        let controller = session.openWindow(url: nil)
        let cred = try WebCredential(domain: "example.com", username: "user1", password: "pwd")
        FormAutofillBridge.showAutofillOptions(in: controller.webView, credentials: [cred])
        // 确保不会抛出崩溃或异常
        spin(0.2)
    }

    func testPasswordSaveBannerPresentationAndDismissal() throws {
        let controller = session.openWindow(url: nil)
        let contentView = try XCTUnwrap(controller.window.contentView)

        // 弹出密码保存横幅
        controller.showPasswordSaveBanner(domain: "example.com", username: "tester", password: "pwd")
        let hasBanner = contentView.subviews.contains { subview in
            String(describing: type(of: subview)).contains("NSHostingView")
        }
        XCTAssertTrue(hasBanner, "PasswordSaveBanner should be added to window contentView")

        // 移除密码保存横幅
        controller.dismissPasswordSaveBanner()
        spin(0.3)
    }
}
