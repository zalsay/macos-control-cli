import XCTest
import WebKit
import SafarierCore
@testable import SafarierWebKit

final class BackgroundConfigurationGateTests: XCTestCase {
    private final class CredentialSpy: CredentialStore, @unchecked Sendable {
        var reads = 0
        func password(forKey key: String) throws -> String? { reads += 1; return nil }
        func setPassword(_ password: String, forKey key: String) throws {}
        func removePassword(forKey key: String) throws {}
    }

    @MainActor private final class PrivacySpy: PrivacyProtectionAdapter {
        let identifier = "spy"
        var calls = 0
        func apply(to configuration: WKWebViewConfiguration, for profile: Profile, report: inout PrivacyCapabilityReport) { calls += 1 }
    }

    @MainActor func testBackgroundDeniedBeforeProxyCredentialsAndPrivacy() {
        let credentials = CredentialSpy()
        let privacy = PrivacySpy()
        let factory = WebViewConfigurationFactory(credentials: credentials, privacy: privacy, safariApplicationName: nil)
        let proxy = ProxySettings(name: "test", kind: .socks5, host: "127.0.0.1", port: 20001, username: "user")
        let profile = Profile(name: "test", mode: .ephemeral, proxyID: proxy.id)
        XCTAssertThrowsError(try factory.make(profile: profile, proxy: proxy, processLanguages: [], executionPolicy: .automationBackground)) {
            XCTAssertEqual($0 as? AutomationError, AutomationError(code: .uiPolicyUnavailable))
        }
        XCTAssertEqual(credentials.reads, 0)
        XCTAssertEqual(privacy.calls, 0)
        // This error also takes precedence over missing proxy validation.
        XCTAssertThrowsError(try factory.make(profile: profile, proxy: nil, processLanguages: [], executionPolicy: .automationBackground)) {
            XCTAssertEqual($0 as? AutomationError, AutomationError(code: .uiPolicyUnavailable))
        }
    }
}
