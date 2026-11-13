import XCTest
@testable import Safarier
final class RunnerAutomationControllerTests: XCTestCase {
    @MainActor func testCases() async throws { let count = try await RunnerAutomationControllerCases.run(); XCTAssertGreaterThan(count, 0) }
}
