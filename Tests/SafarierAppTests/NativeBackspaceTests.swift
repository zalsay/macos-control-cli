#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_NATIVE_INPUT_POLICY_TESTS
import AppKit
import WebKit
import XCTest
import SafarierCore
@testable import Safarier

@MainActor
final class NativeBackspaceTests: XCTestCase {
    func testBackspaceNavigatesHistoryWithoutReplacingNativeEditing() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.html"), second = directory.appendingPathComponent("second.html")
        try "<title>first</title><body>First page</body>".write(to: first, atomically: true, encoding: .utf8)
        try "<title>second</title><input id='field' value='abc'><p id='body' tabindex='0'>Second page</p>".write(to: second, atomically: true, encoding: .utf8)
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); webView.stopLoading(); try? FileManager.default.removeItem(at: directory) }
        func waitFor(_ condition: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Expected native Backspace effect was not observed")
        }
        webView.loadFileURL(first, allowingReadAccessTo: directory)
        try await waitFor { webView.url == first && !webView.isLoading }
        webView.loadFileURL(second, allowingReadAccessTo: directory)
        try await waitFor { webView.url == second && !webView.isLoading }
        XCTAssertTrue(webView.canGoBack)
        XCTAssertTrue(window.makeFirstResponder(webView))
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: webView, window: window)
        _ = try await webView.evaluateJavaScript("field.focus(); field.setSelectionRange(3,3)")
        input.key(.backspace)
        XCTAssertNil(input.policyTestFailure)
        try await waitFor { try await webView.evaluateJavaScript("field.value") as? String == "ab" }
        XCTAssertEqual(webView.url, second, "Editing must not navigate away")
        _ = try await webView.evaluateJavaScript("document.getElementById('body').focus()")
        input.key(.backspace)
        XCTAssertNil(input.policyTestFailure)
        try await waitFor { webView.url == first && !webView.isLoading }
    }
}
#endif
