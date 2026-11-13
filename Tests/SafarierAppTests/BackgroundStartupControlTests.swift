import XCTest
@testable import Safarier

final class BackgroundStartupControlTests: XCTestCase {
    func testPrivateSocketWatch() async throws {
        let count = try await BackgroundStartupControlCases.run()
        XCTAssertGreaterThan(count, 0)
    }
}
