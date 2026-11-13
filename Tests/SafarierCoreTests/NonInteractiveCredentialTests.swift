import XCTest
@testable import SafarierCore

final class NonInteractiveCredentialTests: XCTestCase {
    func testCases() throws {
        XCTAssertGreaterThan(try NonInteractiveCredentialCases.run(), 0)
    }
}
