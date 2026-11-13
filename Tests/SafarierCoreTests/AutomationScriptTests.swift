import XCTest
@testable import SafarierCore
final class AutomationScriptTests: XCTestCase {
    func testScriptCases() async throws {
        let count = try await AutomationScriptCases.run()
        XCTAssertGreaterThan(count, 0)
    }
}
