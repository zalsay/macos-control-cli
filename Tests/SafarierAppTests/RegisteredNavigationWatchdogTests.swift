import XCTest
import WebKit
@testable import Safarier

#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
@MainActor final class RegisteredNavigationWatchdogTests: XCTestCase {
    func testReleasedNativeInputDoesNotExpireDuringLongerNavigation() async throws {
        let permit = OwnedBrowserAutomationPage.RegisteredNativePermit(source: URL(string: "http://localhost/")!, epoch: 1)
        var expired = false, allowed = false
        permit.decision = { allowed = $0 == .allow }
        permit.watchInput(until: .now + .milliseconds(20)) { expired = true }
        permit.releaseForNavigation()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(allowed)
        XCTAssertTrue(permit.released)
        XCTAssertFalse(expired)
    }
    func testUnreleasedNativeInputStillExpires() async throws {
        let permit = OwnedBrowserAutomationPage.RegisteredNativePermit(source: URL(string: "http://localhost/")!, epoch: 1)
        var expired = false
        permit.watchInput(until: .now + .milliseconds(20)) { expired = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(expired)
        XCTAssertFalse(permit.released)
    }
    func testCancelledDecisionIsDeliveredOnlyOnce() {
        let permit = OwnedBrowserAutomationPage.RegisteredNativePermit(source: URL(string: "http://localhost/")!, epoch: 1)
        var decisions: [WKNavigationActionPolicy] = []
        permit.decision = { decisions.append($0) }
        permit.decide(.cancel)
        permit.decide(.cancel)
        XCTAssertEqual(decisions, [.cancel])
        XCTAssertNil(permit.decision)
        XCTAssertFalse(permit.released)
    }
}
#endif
