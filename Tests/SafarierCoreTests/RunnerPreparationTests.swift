import XCTest
@testable import SafarierCore

final class RunnerPreparationTests: XCTestCase {
    func testPreparationCases() throws {
        XCTAssertGreaterThan(try RunnerPreparationCases.run(), 0)
    }
}
