import XCTest
final class OwnedSingboxTests: XCTestCase {
    func testOwnedSingbox() async throws {
        guard let helper = ProcessInfo.processInfo.environment["OWNED_SINGBOX_HELPER"], let root = ProcessInfo.processInfo.environment["OWNED_SINGBOX_FIXTURE"] else { throw XCTSkip("standalone fixture not configured") }
        _ = try await OwnedSingboxCases.run(helper: URL(fileURLWithPath: helper), root: URL(fileURLWithPath: root))
    }
}
