import Foundation

// Synthetic manager: no process, socket, profile, or network side effects.
final class SingboxProcessManager: @unchecked Sendable {
    struct OwnedIdentity: Sendable {}
    enum Failure: Error { case rejected }
    let delay: UInt64
    let exit: Int?
    let reject: Bool
    private let lock = NSLock()
    private var requests = 0
    private var observations = 0
    private var timeout: Double?
    init(delay: UInt64 = 0, exit: Int? = 0, reject: Bool = false) {
        self.delay = delay; self.exit = exit; self.reject = reject
    }
    func requestStopOwned(_ identity: OwnedIdentity) throws {
        lock.lock(); requests += 1; lock.unlock()
        if reject { throw Failure.rejected }
    }
    func stopOwned(_ identity: OwnedIdentity, timeoutSeconds: Double) async throws -> Int? {
        record(timeoutSeconds)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return exit
    }
    private func record(_ seconds: Double) {
        lock.lock(); observations += 1; timeout = seconds; lock.unlock()
    }
    func snapshot() -> (Int, Int, Double?) {
        lock.lock(); defer { lock.unlock() }
        return (requests, observations, timeout)
    }
}

@main struct OwnedResourcesDeadlineMain {
    @MainActor static func main() async {
        do { print("PASS: \(try await run()) owned resource deadline checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    struct Failure: Error { let message: String }
    @MainActor static func run() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            count += 1; if !value { throw Failure(message: message) }
        }
        let identity = SingboxProcessManager.OwnedIdentity()
        let empty = RunnerPreparation.OwnedResources()
        try check(await empty.close(), "empty succeeds")
        let mismatched = RunnerPreparation.OwnedResources(identity: identity)
        try check(!(await mismatched.close()), "mismatch fails")
        let healthy = SingboxProcessManager()
        let resources = RunnerPreparation.OwnedResources(manager: healthy, identity: identity)
        async let a = resources.close()
        async let b = resources.close()
        let (x, y) = await (a, b)
        try check(x && y, "healthy closes")
        let snapshot = healthy.snapshot()
        try check(snapshot.0 == 1 && snapshot.1 == 1, "single flight")
        try check(snapshot.2 != nil && snapshot.2! > 0 && snapshot.2! <= 2, "remaining budget")
        let unknown = SingboxProcessManager(exit: nil)
        let unknownResources = RunnerPreparation.OwnedResources(manager: unknown, identity: identity)
        let unknownFirst = await unknownResources.close(), unknownSecond = await unknownResources.close()
        try check(!unknownFirst && !unknownSecond, "nil cached false")
        try check(unknown.snapshot().0 == 1 && unknown.snapshot().1 == 1, "nil not retried")
        let rejected = SingboxProcessManager(reject: true)
        let rejectedResources = RunnerPreparation.OwnedResources(manager: rejected, identity: identity)
        let rejectedFirst = await rejectedResources.close(), rejectedSecond = await rejectedResources.close()
        try check(!rejectedFirst && !rejectedSecond, "request error cached false")
        try check(rejected.snapshot().0 == 1 && rejected.snapshot().1 == 0, "request error no observation")
        let late = SingboxProcessManager(delay: 2_100_000_000)
        let lateResources = RunnerPreparation.OwnedResources(manager: late, identity: identity)
        let lateFirst = await lateResources.close(), lateSecond = await lateResources.close()
        try check(!lateFirst && !lateSecond, "late exit cached false")
        try check(late.snapshot().0 == 1 && late.snapshot().1 == 1, "late exit not retried")
        return count
    }
}
