import XCTest
@testable import SafarierCore
final class NativeInputTests: XCTestCase {
    func testPreflight() throws { XCTAssertGreaterThan(try NativeInputCases.run(), 0) }
}
