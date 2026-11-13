import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

@MainActor
final class LegacySystemDragBoundaryTests: XCTestCase {
    private func makeView() -> BrowserWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return BrowserWebView(frame: .zero, configuration: configuration)
    }

    func testOriginalCustomDragFixtureDisablesWebKitTextSelection() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("scripts/background-input-probe/fixture.html")
        let html = try String(contentsOf: fixture, encoding: .utf8)
        let view = makeView()
        view.loadHTMLString(html, baseURL: nil)

        var ready = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("window.__probeReady === true") as? Bool) == true {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard ready else {
            XCTFail("Original fixture did not set __probeReady within 5 seconds")
            return
        }
        let value = try await view.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#customdrag')).getPropertyValue('-webkit-user-select')"
        ) as? String
        XCTAssertEqual(value, "none", "Original custom drag control must not select text in WebKit")
        let selectedLength = try await view.evaluateJavaScript("window.probeSnapshot().customDragSelectedLength") as? Int
        XCTAssertEqual(selectedLength, 0, "Custom drag snapshot must initially report no selected text")
    }

    func testPermissionDefaultsToManualAndEvaluatesOncePerAttempt() {
        let view = makeView()
        XCTAssertTrue(view.canBeginLegacySystemDrag())
        var calls = 0
        view.legacySystemDragPermission = { calls += 1; return true }
        XCTAssertTrue(view.canBeginLegacySystemDrag())
        XCTAssertEqual(calls, 1)
        view.legacySystemDragPermission = { calls += 1; return false }
        XCTAssertFalse(view.canBeginLegacySystemDrag())
        XCTAssertEqual(calls, 2)
    }

    func testExistingBackgroundPolicyBlocksSystemDragOnce() {
        var blocked: [BackgroundUIRequest] = []
        let allowed = BackgroundPagePolicy(mode: .automationBackground).route(.systemDrag, onBlocked: { blocked.append($0) }, perform: { true }, deny: { false })
        XCTAssertFalse(allowed)
        XCTAssertEqual(blocked, [.systemDrag])
    }

    func testControllerBindsInteractiveSessionAndFailsClosedAfterOwnerLoss() throws {
        _ = NSApplication.shared
        let view = makeView()
        weak var weakSession: BrowserSession?
        autoreleasepool {
            let profile = Profile(name: "legacy-drag-boundary", mode: .ephemeral)
            let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: nil)
            let output = try! factory.make(profile: profile, proxy: nil, processLanguages: [])
            let session = BrowserSession(profile: profile, output: output, outboundDescription: "test", diagnostics: SPIDiagnostics())
            weakSession = session
            let controller = BrowserWindowController(session: session, webView: view, contentSize: NSSize(width: 800, height: 600))
            XCTAssertFalse(controller.window.isVisible)
            XCTAssertTrue(view.legacySystemDragBoundaryInstalled)
            XCTAssertNotNil(view.legacySystemDragPermission)
            XCTAssertTrue(view.canBeginLegacySystemDrag())
        }
        XCTAssertNil(weakSession)
        XCTAssertFalse(view.canBeginLegacySystemDrag())
    }

    func testProductionAdmissionsRemainClosed() {
        XCTAssertFalse(NativePageInput.shippingAdmissionAvailable)
        XCTAssertFalse(NativeInputPreflight.shippingAdmissionAvailable)
        XCTAssertFalse(BackgroundSafetyCapabilities.unverified.isComplete)
        XCTAssertThrowsError(try WebViewConfigurationFactory.requireExecutionPolicy(.automationBackground))
    }
}
