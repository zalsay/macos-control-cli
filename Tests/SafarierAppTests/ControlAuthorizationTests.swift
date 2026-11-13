import Foundation
import XCTest
import SafarierControlSupport
import SafarierCore
@testable import Safarier

@MainActor final class ControlAuthorizationTests: XCTestCase {
    func testAppleEventTimeoutBoundAcceptsNavigationBudget() {
        var manager = CSControlManager()
        var request: UInt8 = 1, reply: UInt8 = 0
        var replyLength: UInt = 0, sent: Int32 = -1, audit: Int32 = -1
        var phase: UInt32 = 0
        let traceID = [UInt8](repeating: 0, count: 16)
        let timeout = UInt32(AutomationLimits.navigationSeconds + AutomationLimits.actionSeconds)
        let status = cs_control_send_apple_event("invalid.test", &request, 1, timeout, &manager, "/invalid", &reply, 1, &replyLength, &sent, &audit, &phase, traceID)
        XCTAssertNotEqual(status, -50)
        XCTAssertEqual(phase, 1)
        XCTAssertEqual(sent, 0)
        let rejected = cs_control_send_apple_event("invalid.test", &request, 1, timeout + 1, &manager, "/invalid", &reply, 1, &replyLength, &sent, &audit, &phase, traceID)
        XCTAssertEqual(rejected, -50)
    }
    func testStrictArgumentsAndDefaultQuery() throws {
        XCTAssertFalse(try ControlAuthorization.parse([]))
        XCTAssertTrue(try ControlAuthorization.parse(["--request"]))
        for args in [["--request", "--request"], ["--request=true"], ["--app", "/tmp/x"], ["foo"], ["--request", "foo"]] {
            XCTAssertThrowsError(try ControlAuthorization.parse(args))
        }
        XCTAssertEqual(ManagerCLI.run(["authorize", "--invalid"]), 64)
    }
    func testDefaultQueryNeverRequestsConsentAndOnlyCallsOnce() async {
        var calls: [Bool] = []
        let reply = await ControlAuthorization.perform(request: false, targetCurrent: { true }) { ask in
            calls.append(ask); return (-1744, false)
        }
        XCTAssertEqual(calls, [false])
        XCTAssertEqual(reply.status, "consent_required")
        XCTAssertEqual(reply.osStatus, -1744)
    }
    func testExplicitRequestCallsOnceAndReturnsAllowedWithoutBusinessEvent() async throws {
        var calls: [Bool] = []
        let reply = await ControlAuthorization.perform(request: true, targetCurrent: { true }) { ask in
            calls.append(ask); return (0, false)
        }
        XCTAssertEqual(calls, [true])
        XCTAssertEqual(reply.status, "allowed")
        let json = try JSONSerialization.jsonObject(with: reply.jsonData()) as! [String: Any]
        XCTAssertEqual(json["businessEventSent"] as? Bool, false)
        XCTAssertFalse((json["statusDescription"] as! String).isEmpty)
    }
    func testStatusMappingDoesNotRetryDeniedOrUnknown() async {
        for (code, status): (Int32, String) in [(-1743, "not_permitted"), (-1744, "consent_required"), (-600, "unavailable")] {
            var calls = 0
            let reply = await ControlAuthorization.perform(request: true, targetCurrent: { true }) { _ in
                calls += 1; return (code, false)
            }
            XCTAssertEqual(reply.status, status); XCTAssertEqual(reply.osStatus, code); XCTAssertEqual(calls, 1)
        }
    }
    func testChangedTargetBeforeCallPreventsPermissionRequest() async throws {
        var called = false
        let reply = await ControlAuthorization.perform(request: true, targetCurrent: { false }) { _ in
            called = true; return (0, false)
        }
        XCTAssertFalse(called); XCTAssertEqual(reply.status, "target_changed"); XCTAssertNil(reply.osStatus)
        let json = try JSONSerialization.jsonObject(with: reply.jsonData()) as! [String: Any]
        XCTAssertTrue(json["osStatus"] is NSNull)
    }
    func testChangedTargetAfterPromptOrInsideCOverridesAllowed() async {
        var checks = 0
        let reply = await ControlAuthorization.perform(request: true, targetCurrent: { checks += 1; return checks == 1 }) { _ in (0, false) }
        XCTAssertEqual(checks, 2); XCTAssertEqual(reply.status, "target_changed")
        let inner = await ControlAuthorization.perform(request: true, targetCurrent: { true }) { _ in (0, true) }
        XCTAssertEqual(inner.status, "target_changed")
    }
}
