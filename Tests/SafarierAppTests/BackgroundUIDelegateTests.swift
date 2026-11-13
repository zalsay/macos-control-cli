import XCTest
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

// Definitions only: background factory denial makes a background BrowserSession unreachable.
@MainActor
final class BackgroundUIDelegateTests: XCTestCase {
    func testFactoryStillRefusesBackgroundBeforeSessionCreation() {
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: nil)
        let profile = Profile(name: "boundary", mode: .ephemeral)
        XCTAssertThrowsError(try factory.make(profile: profile, proxy: nil, processLanguages: [], executionPolicy: .automationBackground)) {
            XCTAssertEqual($0 as? AutomationError, AutomationError(code: .uiPolicyUnavailable))
        }
    }

    func testInteractiveSessionUsesOutputPolicy() throws {
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: nil)
        let profile = Profile(name: "boundary", mode: .ephemeral)
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        let session = BrowserSession(profile: profile, output: output, outboundDescription: "test", diagnostics: SPIDiagnostics())
        var blocked = 0, performed = 0
        session.onAutomationUIBlocked = { _ in blocked += 1 }
        session.routeUI(.alert, perform: { performed += 1 }, deny: { XCTFail("interactive denied") })
        XCTAssertEqual(performed, 1)
        XCTAssertEqual(blocked, 0)
    }
}
