import XCTest
@testable import SafarierCore

final class OwnedChildLifecycleTests: XCTestCase {
    func testLifecycle() async throws {
        guard let path = ProcessInfo.processInfo.environment["OWNED_CHILD_HELPER"] else { throw XCTSkip("standalone helper not configured") }
        let count = try await OwnedChildLifecycleCases.run(helper: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(count, 0)
    }
}
