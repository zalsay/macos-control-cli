import XCTest
@testable import SafarierCore

final class BackgroundPagePolicyTests: XCTestCase {
    func testPolicyAndCapabilities() throws {
        XCTAssertGreaterThan(try BackgroundPagePolicyCases.run(), 0)
    }
}
