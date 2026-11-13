import XCTest
@testable import SafarierCore
final class BackgroundUIBoundaryTests: XCTestCase {
    func testBoundary() throws { XCTAssertGreaterThan(try BackgroundUIBoundaryCases.run(), 0) }
}
