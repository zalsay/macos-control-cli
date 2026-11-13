import XCTest
@testable import SafarierCore
final class AutomationSessionTests: XCTestCase {
    func testSessionCases() throws { XCTAssertGreaterThan(try AutomationSessionCases.run(), 0) }
}
