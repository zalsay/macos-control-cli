import XCTest
import WebKit
import SafarierCore
@testable import SafarierWebKit
@testable import Safarier

/// Offline data-query regression: no WebView, window, navigation or native input.
@MainActor final class RegisteredShareQueryTests: XCTestCase {
    private func session(_ policy: BrowserExecutionPolicy) -> BrowserSession {
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(),
            report: PrivacyCapabilityReport(), executionPolicy: policy)
        return BrowserSession(profile: Profile(name: "share-query", mode: .ephemeral), output: output,
            outboundDescription: "offline", diagnostics: SPIDiagnostics())
    }

    func testBackgroundQueryReturnsNoContentWithoutBlockingButRealRequestStillBlocks() {
        let session = session(.automationBackground)
        var blocked: [BackgroundUIRequest] = []
        session.onAutomationUIBlocked = { blocked.append($0) }
        let url = URL(string: "https://example.invalid/public-fixture")!
        XCTAssertTrue(BrowserWindowController.sharingItems(session: session, displayURL: url).isEmpty)
        XCTAssertTrue(BrowserWindowController.sharingItems(session: session, displayURL: nil).isEmpty)
        XCTAssertTrue(blocked.isEmpty, "a toolbar content query is not a user share action")
        XCTAssertFalse(session.allowUI(.share))
        XCTAssertEqual(blocked, [.share], "real UI requests must retain their blocking behavior")
    }

    func testInteractiveQueryKeepsURLWithoutBlocking() {
        let session = session(.interactive)
        var blocked = 0
        session.onAutomationUIBlocked = { _ in blocked += 1 }
        let url = URL(string: "https://example.invalid/public-fixture")!
        XCTAssertEqual(BrowserWindowController.sharingItems(session: session, displayURL: url) as? [URL], [url])
        XCTAssertTrue(BrowserWindowController.sharingItems(session: session, displayURL: nil).isEmpty)
        XCTAssertEqual(blocked, 0)
    }
}
