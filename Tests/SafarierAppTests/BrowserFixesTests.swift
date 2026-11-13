import XCTest
import AppKit
import WebKit
import Darwin
import SafarierCore
import SafarierWebKit
@testable import Safarier

/// 本测试独占的回环监听器：每个连接由网络层真实重置，不访问 DNS 或远端。
private final class ResettingLoopbackFixture {
    private final class State {
        var accepted = 0
        var errors: [String] = []
        var closeResult: Int32 = -1
    }

    let url: URL
    private let queue = DispatchQueue(label: "BrowserFixesTests.resetting-loopback")
    private let source: DispatchSourceRead
    private let closed = DispatchSemaphore(value: 0)
    private let state = State()

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var sourceOwnsFD = false
        defer { if !sourceOwnsFD { close(fd) } }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, listen(fd, SOMAXCONN) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/x") else {
            throw URLError(.badURL)
        }
        self.url = url
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let state = self.state
        let closed = self.closed
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    if errno != EAGAIN && errno != EWOULDBLOCK { state.errors.append("accept: \(errno)") }
                    break
                }
                state.accepted += 1
                var reset = linger(l_onoff: 1, l_linger: 0)
                if setsockopt(client, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)) != 0 {
                    state.errors.append("setsockopt: \(errno)")
                }
                if close(client) != 0 { state.errors.append("close client: \(errno)") }
            }
        }
        source.setCancelHandler {
            state.closeResult = close(fd)
            closed.signal()
        }
        sourceOwnsFD = true
        source.resume()
    }

    var descriptorFlags: Int32 { queue.sync { fcntl(Int32(source.handle), F_GETFD) } }
    var acceptedCount: Int { queue.sync { state.accepted } }
    var errors: [String] { queue.sync { state.errors } }

    /// 关闭仅由 cancel handler 执行，并等待其完成后再断言。
    func stop() -> Bool {
        source.cancel()
        guard closed.wait(timeout: .now() + 5) == .success else { return false }
        return queue.sync { state.closeResult == 0 }
    }
}

/// Round 3 浏览窗口修复：网页打开的视图不抢地址栏、target=_blank 走 createWebViewWith、源代码窗口、标签选中、
/// 出错页网址残留、⇧⌘H 历史、右键打开方式的定时器、菜单置灰、地址栏 Esc。
@MainActor
final class BrowserFixesTests: XCTestCase {
    private var session: BrowserSession!

    override func setUp() async throws {
        _ = NSApplication.shared
        session = try Self.makeSession(Profile(name: "fix", mode: .ephemeral))
    }

    override func tearDown() async throws {
        for controller in session.openControllers { controller.window.close() }
        session = nil
    }

    static func makeSession(_ profile: Profile) throws -> BrowserSession {
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15")
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        return BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics())
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 等到条件成立（最多 `timeout` 秒）。
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { spin(0.1) }
    }

    // MARK: - 网页打开的视图

    /// window.open / target=_blank / 右键新标签：不走起始页、不抢地址栏焦点，前台打开时焦点在网页上。
    func testPopupTabDoesNotShowStartPageOrGrabAddressBar() {
        let host = session.openWindow(url: nil)
        let popup = session.openTab(in: host, url: nil, configuration: session.configuration, background: false)
        spin()
        XCTAssertTrue(popup.isPopup)
        XCTAssertFalse(popup.isShowingStartPage, "空白弹窗不能被起始页盖住")
        XCTAssertFalse(popup.wantsAddressFocus)
        XCTAssertFalse(popup.window.firstResponder is NSTextView, "地址栏没有进入编辑状态")
        XCTAssertTrue(popup.window.firstResponder === popup.webView || (popup.window.firstResponder as? NSView)?.isDescendant(of: popup.webView) == true)

        let background = session.openTab(in: host, url: nil, configuration: session.configuration, background: true)
        XCTAssertFalse(background.wantsAddressFocus, "后台标签切过去时不能被地址栏抢焦点")
        background.window.makeKeyAndOrderFront(nil)
        spin()
        XCTAssertFalse(background.window.firstResponder is NSTextView)

        let window = session.openWindow(url: nil, configuration: session.configuration, contentSize: NSSize(width: 400, height: 300))
        XCTAssertTrue(window.isPopup)
        XCTAssertFalse(window.isShowingStartPage)

        // 普通的新标签（⌘T）照旧：显示起始页，要把焦点放进地址栏。
        let plain = session.openTab(in: host, url: nil)
        XCTAssertFalse(plain.isPopup)
        XCTAssertTrue(plain.isShowingStartPage)
    }

    /// window.open("") 的 about:blank 弹窗显示网页内容，不当成 ⇧⌘H 的起始页。
    func testBlankPopupShowsContent() {
        let host = session.openWindow(url: nil)
        let popup = session.openTab(in: host, url: nil, configuration: session.configuration)
        popup.webView.load(URLRequest(url: URL(string: "about:blank")!))
        spin(0.5)
        XCTAssertFalse(popup.isShowingStartPage)
        XCTAssertEqual(popup.displayURL?.absoluteString, "about:blank")
    }

    /// ⌘点按 / 中键点按：主框架链接在这里开新标签；target=_blank（targetFrame 为 nil）放行给 createWebViewWith，opener 才保留。
    func testLinkClickDecision() {
        typealias C = BrowserWindowController
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: .command, buttonNumber: 0), .openTab(background: true))
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: [.command, .shift], buttonNumber: 0), .openTab(background: false))
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: [], buttonNumber: 2), .openTab(background: true))
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: nil, flags: .command, buttonNumber: 0), .allow, "target=_blank 不截")
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: nil, flags: [], buttonNumber: 2), .allow)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: false, flags: .command, buttonNumber: 0), .allow, "子框架里的链接照常")
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: .option, buttonNumber: 0), .download)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: nil, flags: .option, buttonNumber: 0), .download)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: false, flags: .option, buttonNumber: 0), .allow)
        XCTAssertEqual(C.linkClickDecision(targetIsMainFrame: true, flags: [], buttonNumber: 0), .allow)
    }

    // MARK: - 标签

    func testOpenTabSelectsForegroundAndKeepsBackground() {
        let host = session.openWindow(url: nil)
        let background = session.openTab(in: host, url: URL(string: "https://example.invalid/bg"), background: true)
        XCTAssertTrue(host.window.tabGroup?.selectedWindow === host.window, "后台打开留在原标签")
        let foreground = session.openTab(in: host, url: URL(string: "https://example.invalid/fg"))
        XCTAssertTrue(host.window.tabGroup?.selectedWindow === foreground.window)
        XCTAssertNotNil(background.webView.url)
    }

    // MARK: - 源代码窗口

    func testPageSourceWindowFocusFindAndClose() throws {
        let host = session.openWindow(url: nil)
        session.showSource("<p>hello</p>", title: "t", url: URL(string: "https://example.invalid/"), relativeTo: host.window)
        spin()
        let groups = session.windowGroups()
        XCTAssertEqual(groups.count, 2, "源代码窗口也算本环境的窗口，⌘` 能切过去")
        let sourceWindow = try XCTUnwrap(groups.first { $0 !== host.window })
        let source = try XCTUnwrap(sourceWindow.delegate as? PageSourceWindowController)
        XCTAssertEqual(sourceWindow.tabbingMode, .disallowed, "不和浏览窗口合并成标签")
        XCTAssertTrue(sourceWindow.firstResponder === source.textView)

        source.showFind(nil)
        XCTAssertEqual(source.textView.enclosingScrollView?.isFindBarVisible, true, "⌘F 打开源代码窗口自己的查找栏")

        // 源代码窗口在前时，⌘T 交给最前面的浏览窗口，不新建窗口。
        sourceWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(session.frontmostController === host)
        session.newTab(nil)
        XCTAssertEqual(host.window.tabbedWindows?.count, 2)
        XCTAssertEqual(session.openControllers.count, 2)

        source.closeTab(nil)
        spin()
        XCTAssertFalse(sourceWindow.isVisible)
        XCTAssertEqual(session.windowGroups().count, 1, "关掉后不再算进窗口列表")
    }

    // MARK: - 出错页网址、⇧⌘H

    func testResettingLoopbackFixtureResetsRepeatedConnectionsAndCloses() throws {
        let fixture = try ResettingLoopbackFixture()
        defer {
            XCTAssertTrue(fixture.stop(), "监听器必须关闭")
            XCTAssertTrue(fixture.errors.isEmpty, "\(fixture.errors)")
        }
        let flags = fixture.descriptorFlags
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0, "监听器不能被 exec 后的子进程继承")
        let host = try XCTUnwrap(fixture.url.host)
        let port = try XCTUnwrap(fixture.url.port)
        for _ in 0..<3 {
            let client = socket(AF_INET, SOCK_STREAM, 0)
            guard client >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(client) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw URLError(.badURL) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            XCTAssertEqual(result, 0)
            var byte: UInt8 = 0
            let received = recv(client, &byte, 1, 0)
            let error = errno
            XCTAssertEqual(received, -1)
            XCTAssertEqual(error, ECONNRESET)
        }
        XCTAssertEqual(fixture.acceptedCount, 3)
    }

    func testFailedURLIsClearedByBackAndByOtherNavigation() throws {
        let fixture = try ResettingLoopbackFixture()
        defer {
            XCTAssertTrue(fixture.stop(), "监听器必须关闭")
            XCTAssertTrue(fixture.errors.isEmpty, "\(fixture.errors)")
        }
        let controller = session.openWindow(url: nil)
        let failing = fixture.url
        controller.webView.load(URLRequest(url: failing))
        spin(until: { controller.failedURL != nil })
        XCTAssertEqual(controller.failedURL, failing, "出错页记下原本要打开的网址")
        spin(1)
        XCTAssertEqual(controller.failedURL, failing, "出错页自己的载入不清掉它")

        controller.webView.loadHTMLString("<p>other</p>", baseURL: URL(string: "https://other.example.invalid/"))
        spin(until: { controller.failedURL == nil })
        XCTAssertNil(controller.failedURL, "打开了别的网页，⌘R 不再重试旧网址")

        let firstConnectionCount = fixture.acceptedCount
        controller.webView.load(URLRequest(url: failing))
        spin(until: { controller.failedURL != nil })
        XCTAssertEqual(controller.failedURL, failing, "第二次失败后记下网址")
        XCTAssertGreaterThan(fixture.acceptedCount, firstConnectionCount, "第二次导航必须到达回环监听器")
        controller.goBack(nil)
        XCTAssertNil(controller.failedURL, "后退时立即清掉")
    }

    /// ⇧⌘H 留下的 about:blank：后退回到它时也显示起始页。（loadHTMLString 不进后退列表，这里用 loadSimulatedRequest。）
    func testBackToHomeEntryShowsStartPage() {
        let controller = session.openWindow(url: nil)
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://a.example.invalid/")!), responseHTML: "<p>a</p>")
        spin(until: { controller.webView.url?.host == "a.example.invalid" && !controller.webView.isLoading })
        controller.goHome(nil)
        spin(until: { controller.webView.url?.absoluteString == "about:blank" && !controller.webView.isLoading })
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://b.example.invalid/")!), responseHTML: "<p>b</p>")
        spin(until: { controller.webView.url?.host == "b.example.invalid" && !controller.webView.isLoading })
        XCTAssertNotNil(controller.displayURL)
        controller.goBack(nil)
        spin(until: { controller.webView.url?.absoluteString == "about:blank" && !controller.webView.isLoading })
        XCTAssertNil(controller.displayURL)
        XCTAssertTrue(controller.isShowingStartPage)
        XCTAssertEqual(controller.window.title, "起始页面")
    }

    // MARK: - 右键打开方式的定时器

    /// 连续两次右键：第一次的两秒定时器不能清掉第二次的设置。
    func testOpenModeTimerOnlyResetsItsOwnGeneration() {
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
        let original = NSMenuItem(title: "o", action: #selector(ActionRecorder.fire(_:)), keyEquivalent: "")
        let recorder = ActionRecorder()
        original.target = recorder
        let forwarding = NSMenuItem(title: "f", action: nil, keyEquivalent: "")
        forwarding.representedObject = original

        webView.openInNewWindow(forwarding)
        XCTAssertTrue(webView.openNextAsWindow)
        spin(1.2)
        webView.openInBackgroundTab(forwarding)
        XCTAssertFalse(webView.openNextAsWindow, "新的一次先清掉上一次的方式")
        XCTAssertTrue(webView.openNextInBackgroundTab)
        spin(1.2)
        XCTAssertTrue(webView.openNextInBackgroundTab, "第一次的定时器到点了，但不能清掉第二次的设置")
        spin(1.2)
        XCTAssertFalse(webView.openNextInBackgroundTab, "第二次自己的定时器到点后复位")
    }

    // MARK: - 菜单置灰

    func testMenuItemsDisabledOnStartPage() throws {
        let controller = session.openWindow(url: nil)
        func enabled(_ action: Selector) -> Bool {
            controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        let pageOnly: [Selector] = [
            #selector(BrowserActions.zoomInPage(_:)), #selector(BrowserActions.zoomOutPage(_:)),
            #selector(BrowserActions.showFind(_:)), #selector(BrowserActions.findNextMatch(_:)), #selector(BrowserActions.findPreviousMatch(_:)),
            #selector(BrowserActions.duplicateTab(_:)), #selector(BrowserActions.goHome(_:)),
            #selector(BrowserActions.showWebInspector(_:)), #selector(BrowserActions.showJavaScriptConsole(_:)),
        ]
        for action in pageOnly { XCTAssertFalse(enabled(action), "起始页上 \(action) 应当置灰") }

        controller.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://page.example.invalid/"))
        spin(until: { controller.displayURL != nil })
        for action in pageOnly { XCTAssertTrue(enabled(action), "网页上 \(action) 应当可用") }

        controller.webView.pageZoom = 3
        XCTAssertFalse(enabled(#selector(BrowserActions.zoomInPage(_:))), "已经最大")
        controller.webView.pageZoom = 0.5
        XCTAssertFalse(enabled(#selector(BrowserActions.zoomOutPage(_:))), "已经最小")
    }

    func testGoHomeEnabledOnStartPageWhenProfileHasStartURL() throws {
        var profile = Profile(name: "home", mode: .ephemeral)
        profile.startURL = URL(string: "https://start.example.invalid/")
        let other = try Self.makeSession(profile)
        let controller = other.openWindow(url: nil)
        defer { controller.window.close() }
        XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserActions.goHome(_:)), keyEquivalent: "")))
    }

    // MARK: - 地址栏 Esc、起始页信息

    func testEscapeInAddressBarCallsOnCancel() {
        let bar = AddressBar(isPrivate: false)
        var cancelled = false
        bar.onCancel = { cancelled = true }
        XCTAssertTrue(bar.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(cancelled)
    }

    /// 跟随代理时起始页显示按出口 IP 解析出来的语言和时区（RunnerMain 传进来的是 effectiveProfile）。
    func testStartPageShowsResolvedRegion() throws {
        let profile = Profile(name: "geo", mode: .ephemeral, languages: ["th-TH", "th"], timeZoneIdentifier: "Asia/Bangkok",
                              followProxyLanguages: true, followProxyTimeZone: true)
        let geo = try Self.makeSession(profile)
        XCTAssertTrue(geo.startPageDetails.contains("语言：th-TH, th · 时区：Asia/Bangkok（跟随代理出口）"), "\(geo.startPageDetails)")
        XCTAssertFalse(session.startPageDetails.contains { $0.hasPrefix("语言：") || $0.hasPrefix("时区：") }, "跟随系统时不显示")
    }

    /// 台式机和笔记本预设下，窗口中央的鼠标点击命中测试都落到 WebView（不会被起始页覆盖层拦下）。
    func testDesktopAndLaptopPresetsNeverBlockWebViewMouseHitTest() throws {
        for id in ["mac-studio-m2-ultra", "imac-24-m4", "mac-mini-m2", "mac-pro-m2-ultra", "macbook-pro-16-m4-max"] {
            let profile = Profile(name: id, mode: .ephemeral, deviceModel: id)
            let devSession = try Self.makeSession(profile)
            let controller = devSession.openWindow(url: nil)
            defer { controller.window.close() }
            let center = NSPoint(x: controller.webView.frame.midX, y: controller.webView.frame.midY)
            let hit = controller.window.contentView?.hitTest(center)
            XCTAssertNotNil(hit, id)
            XCTAssertTrue(hit === controller.webView || hit?.isDescendant(of: controller.webView) == true, "\(id): hit=\(String(describing: hit))")
        }
    }
}
