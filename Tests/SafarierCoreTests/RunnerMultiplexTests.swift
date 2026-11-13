import XCTest
@testable import SafarierCore
final class RunnerMultiplexTests: XCTestCase {
    func testMultiplex() async throws {
        let count = try await RunnerMultiplexCases.run()
        XCTAssertGreaterThan(count, 0)
    }
}
