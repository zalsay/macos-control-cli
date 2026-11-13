import Foundation
import XCTest
@testable import SafarierCore
final class OwnedRunnerTests: XCTestCase {
    func testOwnedRunnerCases() async throws {
        guard let helper = ProcessInfo.processInfo.environment["OWNED_RUNNER_HELPER"], let root = ProcessInfo.processInfo.environment["OWNED_RUNNER_FIXTURE"] else { throw XCTSkip("fixture paths not configured") }
        let count = try await OwnedRunnerCases.run(helper: URL(fileURLWithPath: helper), root: URL(fileURLWithPath: root))
        XCTAssertGreaterThan(count, 0)
    }
}
