import XCTest
@testable import SafarierCore

final class AutomationChannelTests: XCTestCase {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Int, Error>?
        func set(_ result: Result<Int, Error>) { lock.withLock { value = result } }
        func get() -> Result<Int, Error>? { lock.withLock { value } }
    }
    func testFrameDeadlineAllowsGenerationPastPreviousLimit() throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = try FrameDeadline(lifetimeStart: now - 50_000_000_000)
        XCTAssertGreaterThan(try deadline.remaining(), 5)
        XCTAssertThrowsError(try FrameDeadline(lifetimeStart: now - 91_000_000_000))
    }
    func testChannelCases() async throws {
        let done = expectation(description: "channel cases finish within deadline")
        let result = ResultBox()
        let task = Task {
            do { result.set(.success(try await AutomationChannelCases.run())) }
            catch { result.set(.failure(error)) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 20)
        task.cancel()
        guard let outcome = result.get() else { XCTFail("channel cases timed out"); return }
        XCTAssertGreaterThan(try outcome.get(), 0)
    }
}
