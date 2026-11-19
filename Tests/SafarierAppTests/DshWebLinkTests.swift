import AppKit
import WebKit
import XCTest
@testable import Safarier

@MainActor
final class DshWebLinkTests: XCTestCase {
    func testDshWebViewInstallsNewWindowAndNavigationHandlers() {
        let service = DshService.shared
        defer { service.stop() }
        let view = service.getOrCreateWebView(for: URL(string: "http://127.0.0.1:9/")!)
        XCTAssertNotNil(view.uiDelegate, "DSH external links ask WebKit to open a new window")
        XCTAssertNotNil(view.navigationDelegate, "External main-frame links should leave the workbench intact")
        XCTAssertFalse(view.configuration.preferences.javaScriptCanOpenWindowsAutomatically,
                       "A page must not launch an external browser from an unsolicited popup")
    }

    func testWebKitOpensExternalLinksOnceAndKeepsTheWorkbench() async throws {
        let allowed = URL(string: "https://dsh.example.invalid/workbench")!
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 260), configuration: config)
        var opened: [URL] = []
        let navigator = DshWebNavigation(serviceURL: allowed) { opened.append($0) }
        view.uiDelegate = navigator
        view.navigationDelegate = navigator
        defer { withExtendedLifetime(navigator) {} }
        view.loadHTMLString("""
            <!doctype html><h1 id="workbench">Workbench</h1>
            <script>
              window.open('https://example.invalid/unsolicited', '_blank');
            </script>
            <a id="inside" href="#workbench">Jump</a>
            <a id="popup" href="https://example.invalid/new" target="_blank" rel="noopener noreferrer">Popup</a>
            <a id="main" href="https://example.invalid/main">External</a>
            <button id="chat" onclick="window.open('https://example.invalid/chat','_blank','noopener,noreferrer')">Chat link</button>
            """, baseURL: allowed)
        let ready = try await until {
            guard !view.isLoading else { return false }
            return (try? await view.evaluateJavaScript("!!document.getElementById('chat')")) as? Bool == true
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(view.url, allowed)
        XCTAssertTrue(opened.isEmpty, "A popup created by the document on load must not open the system browser")

        _ = try await view.evaluateJavaScript("document.getElementById('inside').click()")
        let internalLinkApplied = try await until { view.url?.fragment == "workbench" }
        XCTAssertTrue(internalLinkApplied)
        XCTAssertTrue(opened.isEmpty)

        for (index, link) in ["popup", "main", "chat"].enumerated() {
            _ = try await view.evaluateJavaScript("document.getElementById('\(link)').click()")
            let didOpen = try await until { opened.count == index + 1 }
            XCTAssertTrue(didOpen, "Expected an external handoff for \(link)")
        }
        XCTAssertEqual(opened.map(\.path), ["/new", "/main", "/chat"])
        XCTAssertEqual(view.url?.fragment, "workbench")
    }

    private func until(_ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return false
    }
}
