import Foundation
import XCTest
@testable import Safarier
final class RunnerAutomationServiceTests: XCTestCase {
    @MainActor func testCases() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_SERVICE_FIXTURE"] ?? "")
        guard !base.path.isEmpty else { throw XCTSkip("private fixture not configured") }
        let count = try await RunnerAutomationServiceCases.run(base: base)
        XCTAssertGreaterThan(count, 0)
    }
}
