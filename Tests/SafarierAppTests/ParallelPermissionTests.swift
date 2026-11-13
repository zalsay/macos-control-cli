#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_PARALLEL_PERMISSION_CANDIDATE
import XCTest
import SafarierCore
@testable import Safarier

final class ParallelPermissionTests: XCTestCase {
    private actor Fixture {
        var validations = 0, reads = 0, readFinished = false
        var allowed = true, failFirst = false, failSecond = false, failRead = false
        var delay: UInt64 = 0
        func validate() async throws {
            validations += 1
            let n = validations
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if (n == 1 && failFirst) || (n == 2 && failSecond) { throw Failure.identity }
        }
        func read() async throws -> Bool {
            reads += 1
            defer { readFinished = true }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if failRead { throw Failure.read }
            return allowed
        }
        func configure(delay: UInt64 = 0, allowed: Bool = true, first: Bool = false, second: Bool = false, readError: Bool = false) {
            self.delay = delay; self.allowed = allowed; failFirst = first; failSecond = second; failRead = readError
        }
        func counts() -> (Int, Int, Bool) { (validations, reads, readFinished) }
    }
    private enum Failure: Error { case identity, read }
    private actor ReadGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var started = false
        func wait() async -> Bool {
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func isStarted() -> Bool { started }
        func release() { continuation?.resume(returning: true); continuation = nil }
    }
    private actor CompletionFlag {
        private var completed = false
        func mark() { completed = true }
        func value() -> Bool { completed }
    }

    func testAllowsOnlyBothIdentityChecksAndFreshPermission() async {
        for mode in 0..<5 {
            let f = Fixture()
            await f.configure(allowed: mode != 1, first: mode == 2, second: mode == 3, readError: mode == 4)
            let result = await RunnerAutomationService.parallelPermission(validate: { try await f.validate() }, read: { try await f.read() })
            XCTAssertEqual(result, mode == 0)
            let counts = await f.counts()
            XCTAssertEqual(counts.1, 1)
            XCTAssertTrue(counts.2, "child read must finish before return")
            if mode == 0 || mode == 1 || mode == 3 { XCTAssertEqual(counts.0, 2) }
        }
    }

    func testCancellationNeverAllowsAndWaitsForRead() async {
        let f = Fixture(); await f.configure(delay: 300_000_000)
        let task = Task { await RunnerAutomationService.parallelPermission(validate: { try await f.validate() }, read: { try await f.read() }) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        let counts = await f.counts()
        XCTAssertTrue(counts.2)
    }

    func testIdentityFailureWaitsForNoncooperativeReadAndNeverAllows() async {
        let gate = ReadGate(), finished = CompletionFlag()
        let task = Task {
            let result = await RunnerAutomationService.parallelPermission(validate: { throw Failure.identity }, read: { await gate.wait() })
            await finished.mark()
            return result
        }
        while !(await gate.isStarted()) { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        let completedBeforeDrain = await finished.value()
        XCTAssertFalse(completedBeforeDrain)
        await gate.release()
        let result = await task.value
        XCTAssertFalse(result)
    }

    func testCancellationStillRejectsWhenChildrenIgnoreCancellation() async {
        let gate = ReadGate()
        let task = Task { await RunnerAutomationService.parallelPermission(validate: { try? await Task.sleep(nanoseconds: 50_000_000) }, read: { await gate.wait() }) }
        while !(await gate.isStarted()) { await Task.yield() }
        task.cancel()
        await gate.release()
        let allowed = await task.value
        XCTAssertFalse(allowed)
    }

    func testIsolatedRepositoryPermissionReadTiming() async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("safarier-permission-read-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = Profile(name: "isolated", mode: .persistent)
        try SafarierWorkspace(root: root).profiles.insert(profile)
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now().uptimeNanoseconds
            let allowed = await RunnerAutomationService.repositoryPermission(profileID: profile.id, root: root)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertTrue(allowed)
        }
        samples.sort()
        print("ISOLATED_REPOSITORY_READ milliseconds median=\(samples[samples.count / 2]) max=\(samples.last!) samples=\(samples.count)")
    }

    func testIdentityChangeWhileReadIsInFlightIsRejectedByFinalValidation() async {
        let f = Fixture(), gate = ReadGate()
        let task = Task { await RunnerAutomationService.parallelPermission(validate: { try await f.validate() }, read: { await gate.wait() }) }
        while true {
            let started = await gate.isStarted(), validations = await f.counts().0
            if started && validations > 0 { break }
            await Task.yield()
        }
        await f.configure(second: true)
        await gate.release()
        let result = await task.value
        XCTAssertFalse(result)
        let counts = await f.counts()
        XCTAssertEqual(counts.0, 2)
    }

    func testParallelOverlapReducesSyntheticLatencyWithSameChecks() async throws {
        let serial = Fixture(), parallel = Fixture()
        await serial.configure(delay: 150_000_000); await parallel.configure(delay: 150_000_000)
        let start = ContinuousClock.now
        try await serial.validate(); let allowed = try await serial.read(); try await serial.validate()
        let sequentialDuration = start.duration(to: .now)
        let parallelStart = ContinuousClock.now
        let actual = await RunnerAutomationService.parallelPermission(validate: { try await parallel.validate() }, read: { try await parallel.read() })
        let parallelDuration = parallelStart.duration(to: .now)
        print("SYNTHETIC_PERMISSION_TIMING sequential=\(sequentialDuration) parallel=\(parallelDuration)")
        XCTAssertEqual(actual, allowed)
        let counts = await parallel.counts()
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 1)
        XCTAssertLessThan(parallelDuration, sequentialDuration - .milliseconds(60))
    }
}
#endif
