import XCTest
@testable import SafarierCore
final class ManagerLaunchTests: XCTestCase {
    func testPolicyAndMenu() throws { XCTAssertGreaterThan(try ManagerLaunchCases.run(), 0) }
}
