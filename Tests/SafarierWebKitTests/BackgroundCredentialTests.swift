import XCTest
@testable import SafarierWebKit

final class BackgroundCredentialTests: XCTestCase {
    @MainActor func testCredentialDispatch() throws {
        XCTAssertGreaterThan(try BackgroundCredentialCases.run(), 0)
    }
}
