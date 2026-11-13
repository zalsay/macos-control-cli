import XCTest
@testable import SafarierCore
final class AutomationWireTests: XCTestCase {
    func testWireCases() async throws {
        let count = try await AutomationWireCases.run()
        XCTAssertGreaterThan(count, 0)
    }
}
