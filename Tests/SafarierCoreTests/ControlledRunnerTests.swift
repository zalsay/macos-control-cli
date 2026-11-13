import XCTest
@testable import SafarierCore
final class ControlledRunnerTests: XCTestCase {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Int, Error>?
        func set(_ value: Result<Int, Error>) { lock.withLock { result = value } }
        func get() -> Result<Int, Error>? { lock.withLock { result } }
    }
    func testControlledRunnerCases() async throws {
        guard let path = ProcessInfo.processInfo.environment["CONTROLLED_HELPER_PATH"], FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set CONTROLLED_HELPER_PATH to the separately compiled Foundation fixture")
        }
        let done = expectation(description: "controlled runner checks finish")
        let box = ResultBox()
        let task = Task {
            do { box.set(.success(try await ControlledRunnerCases.run())) }
            catch { box.set(.failure(error)) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        task.cancel()
        guard let result = box.get() else { XCTFail("controlled runner checks timed out"); return }
        XCTAssertGreaterThan(try result.get(), 0)
    }
}
