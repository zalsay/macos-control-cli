import XCTest
import SafarierCore
@testable import Safarier
#if SAFARIER_BOUND_LOCAL_CANDIDATE
@MainActor final class RegisteredInitialLoadTests: XCTestCase {
    func testWaitsReadOnlyUntilReadyAndValidatesEveryPoll() async throws {
        var checks = 0
        try await BrowserSession.waitForRegisteredInitialLoad(deadline: .now + .seconds(1), validate: { checks += 1 }, ready: { checks >= 3 })
        XCTAssertEqual(checks, 3)
    }
    func testConflictAbortsBeforeReadiness() async {
        var reads = 0
        do {
            try await BrowserSession.waitForRegisteredInitialLoad(deadline: .now + .seconds(1), validate: { throw AutomationError(code: .targetChanged) }, ready: { reads += 1; return true })
            XCTFail("conflict accepted")
        } catch { XCTAssertEqual((error as? AutomationError)?.code, .targetChanged) }
        XCTAssertEqual(reads, 0)
    }
    func testLoadingDeadlineDenies() async {
        do {
            try await BrowserSession.waitForRegisteredInitialLoad(deadline: .now + .milliseconds(20), validate: {}, ready: { false })
            XCTFail("loading accepted")
        } catch { XCTAssertEqual((error as? AutomationError)?.code, .interactionRequired) }
    }
}
#endif
