#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_NATIVE_INPUT_POLICY_TESTS
import AppKit
import WebKit
import XCTest
import SafarierCore
@testable import Safarier

@MainActor
final class NativePageKeyTests: XCTestCase {
    func testPageDownAndPageUpScrollUsingNativeKeyEvents() async throws {
        let down = try XCTUnwrap(AutomationKey(rawValue: "PageDown"))
        let up = try XCTUnwrap(AutomationKey(rawValue: "PageUp"))
        _ = NSApplication.shared
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); webView.stopLoading() }
        func waitFor(_ condition: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("native page key effect was not observed")
        }
        webView.loadHTMLString("""
        <title>Page key test</title><body tabindex='0' style='height:6000px'>
        <h1>Long course content</h1><script>
        window.keys=[]; document.addEventListener('keydown', e => keys.push(e.key));
        </script></body>
        """, baseURL: nil)
        try await waitFor { !webView.isLoading && webView.title == "Page key test" }
        XCTAssertTrue(window.makeFirstResponder(webView))
        _ = try await webView.evaluateJavaScript("document.body.focus()")
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: webView, window: window)
        input.key(down)
        XCTAssertNil(input.policyTestFailure)
        try await waitFor { (try await webView.evaluateJavaScript("window.scrollY") as? Double ?? 0) > 250 }
        // Wait for the native page-down animation to settle before testing the reverse key.
        var previous = -1.0, stable = 0
        try await waitFor {
            let current = try await webView.evaluateJavaScript("window.scrollY") as? Double ?? 0
            stable = current == previous ? stable + 1 : 0; previous = current
            return stable >= 5
        }
        input.key(up)
        XCTAssertNil(input.policyTestFailure)
        try await waitFor { (try await webView.evaluateJavaScript("window.scrollY") as? Double ?? 999) < 50 }
        let keys = try await webView.evaluateJavaScript("window.keys") as? [String]
        XCTAssertEqual(keys, ["PageDown", "PageUp"])
    }
}
#endif
