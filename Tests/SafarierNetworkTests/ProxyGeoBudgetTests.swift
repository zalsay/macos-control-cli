import XCTest
@testable import SafarierNetwork

final class ProxyGeoBudgetTests: XCTestCase {
    func testBudgetCases() async throws {
        let count = try await ProxyGeoBudgetCases.run()
        XCTAssertGreaterThan(count, 0)
    }
}
