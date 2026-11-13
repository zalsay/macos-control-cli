import Foundation
import Darwin
@testable import SafarierCore

public enum OwnedRunnerCases {
    struct Failure: Error { let label: String }
    final class OldSpawner: ProcessSpawning, @unchecked Sendable {
        var calls = 0
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 { calls += 1; return 42 }
    }
    final class Observer: @unchecked Sendable {
        private let lock = NSLock(); private var list: [ProcessExit] = []
        func add(_ e: ProcessExit) { lock.lock(); list.append(e); lock.unlock() }
        var values: [ProcessExit] { lock.lock(); defer { lock.unlock() }; return list }
    }
    final class ExitBarrier: @unchecked Sendable {
        private let condition = NSCondition()
        private var didEnter = false, released = false, didFinish = false
        func onExit(_ value: ProcessExit) {
            condition.lock(); didEnter = true; condition.broadcast()
            while !released { condition.wait() }
            didFinish = true; condition.broadcast(); condition.unlock()
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var entered: Bool { condition.lock(); defer { condition.unlock() }; return didEnter }
        var finished: Bool { condition.lock(); defer { condition.unlock() }; return didFinish }
    }
    final class RecordingOwnedSpawner: ProcessSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(arguments: [String], environment: [String: String], log: URL?)] = []
        private var ordinary = 0
        private let expectedHome: String
        init(expectedHome: String) { self.expectedHome = expectedHome }
        var snapshot: [(arguments: [String], environment: [String: String], log: URL?)] { lock.lock(); defer { lock.unlock() }; return entries }
        var ordinaryCount: Int { lock.lock(); defer { lock.unlock() }; return ordinary }
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
            lock.lock(); ordinary += 1; lock.unlock(); return 123
        }
        func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> OwnedRunnerProcess {
            lock.lock(); entries.append((arguments, environment, logURL)); lock.unlock()
            var fixtureEnvironment = environment
            fixtureEnvironment["OWNED_EXPECT_HOME"] = expectedHome
            fixtureEnvironment["OWNED_EXPECT_BACKGROUND"] = "1"
            return try FoundationProcessSpawner().spawnOwned(executableURL: executableURL, arguments: arguments, environment: fixtureEnvironment, logURL: logURL, standardInput: standardInput)
        }
    }
    public static func run(helper: URL, root: URL) async throws -> Int {
        var checks = 0
        func check(_ ok: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !ok() { throw Failure(label: label) } }
        let observer = Observer(), spawner = FoundationProcessSpawner(onExit: { observer.add($0) })
        let old = OldSpawner(), id = UUID()
        let spec = RunnerLaunchSpec(profileID: id, startURL: URL(string: "about:blank"), backgroundAutomation: true)
        let pair = try AutomationChannel.makePair()
        do { _ = try RunnerLauncher(executableURL: helper, spawner: old).launchOwned(spec, controlInput: pair.child); throw Failure(label: "legacy accepted") }
        catch let error as ControlledLaunchError { try check(error == .unsupportedOwnedProcess && old.calls == 0, "legacy no fallback") }
        pair.parent.close(); try pair.child.close()
        let ordinaryLegacy = try RunnerLauncher(executableURL: helper, spawner: old).launch(RunnerLaunchSpec(profileID: id))
        try check(ordinaryLegacy == 42 && old.calls == 1, "legacy ordinary path preserved")
        var ownedPIDs: [Int32] = []
        for _ in 0..<3 {
            let fastPair = try AutomationChannel.makePair()
            defer { fastPair.parent.close(); try? fastPair.child.close() }
            let owned = try spawner.spawnOwned(executableURL: helper, arguments: [], environment: ["OWNED_FIXTURE_MODE":"exit7"], logURL: nil, standardInput: fastPair.child)
            try fastPair.child.close(); fastPair.parent.close()
            let exitDeadline = DispatchTime.now() + .seconds(3)
            while !observer.values.contains(where: { $0.pid == owned.pid }) && DispatchTime.now() < exitDeadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard observer.values.contains(where: { $0.pid == owned.pid }) else {
                throw Failure(label: "exit callback timed out, cached status: \(String(describing: owned.observedExit?.status))")
            }
            try check(owned.observedExit?.status == 7, "exit observed before first waiter")
            ownedPIDs.append(owned.pid)
            let result = try await owned.waitForExit(timeoutSeconds: 3)
            try check(result?.status == 7 && result?.pid == owned.pid && !result!.uncaughtSignal, "natural exit")
            try check(owned.observedExit == result, "exit retained")
            for timeout in [0.0, -1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
                do { _ = try await owned.waitForExit(timeoutSeconds: timeout); throw Failure(label: "invalid timeout accepted") }
                catch let error as OwnedRunnerProcessError { try check(error == .invalidTimeout, "invalid timeout rejected") }
            }
            let late = try await owned.waitForExit(timeoutSeconds: 1)
            try check(late == result, "late wait")
            let waitPair = try AutomationChannel.makePair()
            defer { waitPair.parent.close(); try? waitPair.child.close() }
            let waiting = try spawner.spawnOwned(executableURL: helper, arguments: [], environment: ["OWNED_FIXTURE_MODE":"wait"], logURL: nil, standardInput: waitPair.child)
            try waitPair.child.close()
            ownedPIDs.append(waiting.pid)
            let timeoutStarted = DispatchTime.now().uptimeNanoseconds
            let timed = try await waiting.waitForExit(timeoutSeconds: 0.03)
            let timeoutElapsed = Double(DispatchTime.now().uptimeNanoseconds - timeoutStarted) / 1_000_000_000
            try check(timed == nil && waiting.observedExit == nil && timeoutElapsed >= 0.02 && timeoutElapsed < 2, "timeout bounded and unverified")
            let stillWaiting = try await waiting.waitForExit(timeoutSeconds: 0.03)
            try check(stillWaiting == nil && waiting.observedExit == nil, "timeout does not terminate child")
            let cancelled = Task { try await waiting.waitForExit(timeoutSeconds: 3) }; cancelled.cancel()
            var cancellationThrown = false; do { _ = try await cancelled.value } catch is CancellationError { cancellationThrown = true }
            try check(cancellationThrown, "cancel throws")
            let pendingCancellation = Task { try await waiting.waitForExit(timeoutSeconds: 3) }
            try await Task.sleep(nanoseconds: 10_000_000); pendingCancellation.cancel()
            var pendingCancelled = false
            do { _ = try await pendingCancellation.value } catch is CancellationError { pendingCancelled = true }
            try check(pendingCancelled && waiting.observedExit == nil, "cancel running waiter leaves child alive")
            async let a = waiting.waitForExit(timeoutSeconds: 3)
            async let b = waiting.waitForExit(timeoutSeconds: 3)
            var watchers: [Task<ProcessExit?, Error>] = []
            for _ in 0..<12 { watchers.append(Task { try await waiting.waitForExit(timeoutSeconds: 3) }) }
            for index in stride(from: 0, to: watchers.count, by: 2) { watchers[index].cancel() }
            waitPair.parent.close()
            let both = try await (a,b)
            try check(both.0 == both.1 && both.0?.status == 0, "multiple waiters")
            for (index, watcher) in watchers.enumerated() {
                do {
                    let observed = try await watcher.value
                    try check(index % 2 == 1 && observed == both.0, "live waiter completes")
                } catch is CancellationError { try check(index % 2 == 0, "cancelled waiter finishes") }
            }
            try check(waiting.ownershipID != owned.ownershipID, "unique ownership")
        }
        for _ in 0..<500 { if observer.values.count == ownedPIDs.count { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let observed = observer.values
        try check(observed.count == ownedPIDs.count && ownedPIDs.allSatisfy { pid in observed.filter { $0.pid == pid }.count == 1 }, "onExit once per owned child")
        let callbackBefore = observed.count
        let failedPair = try AutomationChannel.makePair()
        do { _ = try spawner.spawnOwned(executableURL: root.appendingPathComponent("nonexistent-executable"), arguments: [], environment: [:], logURL: nil, standardInput: failedPair.child); throw Failure(label: "missing executable accepted") } catch is Failure { throw Failure(label: "missing executable accepted") } catch { }
        failedPair.parent.close(); try failedPair.child.close()
        try await Task.sleep(nanoseconds: 10_000_000)
        try check(observer.values.count == callbackBefore, "failed spawn no exit callback")
        let exitBarrier = ExitBarrier(), barrierPair = try AutomationChannel.makePair()
        defer { exitBarrier.release(); barrierPair.parent.close(); try? barrierPair.child.close() }
        let barrierOwned = try FoundationProcessSpawner(onExit: { exitBarrier.onExit($0) }).spawnOwned(executableURL: helper, arguments: [], environment: ["OWNED_FIXTURE_MODE":"exit7"], logURL: nil, standardInput: barrierPair.child)
        try barrierPair.child.close(); barrierPair.parent.close()
        let barrierExit = try await barrierOwned.waitForExit(timeoutSeconds: 3)
        for _ in 0..<500 { if exitBarrier.entered { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try check(barrierExit?.status == 7 && exitBarrier.entered && !exitBarrier.finished, "exit visible before blocked callback completes")
        exitBarrier.release()
        for _ in 0..<500 { if exitBarrier.finished { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try check(exitBarrier.finished, "onExit released")
        let lifetimeObserver = Observer(), lifetimePair = try AutomationChannel.makePair()
        defer { lifetimePair.parent.close(); try? lifetimePair.child.close() }
        var lifetime: OwnedRunnerProcess? = try FoundationProcessSpawner(onExit: { lifetimeObserver.add($0) }).spawnOwned(executableURL: helper, arguments: [], environment: ["OWNED_FIXTURE_MODE":"exit7"], logURL: nil, standardInput: lifetimePair.child)
        weak let weakLifetime = lifetime
        try lifetimePair.child.close(); lifetimePair.parent.close()
        _ = try await lifetime!.waitForExit(timeoutSeconds: 3)
        for _ in 0..<500 { if !lifetimeObserver.values.isEmpty { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        lifetime = nil
        for _ in 0..<50 { if weakLifetime == nil { break }; await Task.yield() }
        try check(weakLifetime == nil && lifetimeObserver.values.count == 1, "finished owner has no retain cycle")
        let recorder = RecordingOwnedSpawner(expectedHome: root.path), launcher = RunnerLauncher(executableURL: helper, spawner: recorder, logDirectory: root)
        let modes = [RunnerLaunchSpec(profileID: id), RunnerLaunchSpec(profileID: id, startURL: URL(string: "about:blank"), probe: true, backgroundAutomation: true), RunnerLaunchSpec(profileID: id, startURL: URL(string: "https://example.invalid"), backgroundAutomation: true), RunnerLaunchSpec(profileID: id, startURL: URL(string: "about:blank"), spiOverride: [], backgroundAutomation: true)]
        do { _ = try launcher.launchOwned(spec); throw Failure(label: "missing input accepted") }
        catch let error as ControlledLaunchError { try check(error == .missingControlledInput, "missing owned input rejected") }
        let invalidPair = try AutomationChannel.makePair()
        for mode in modes {
            do { _ = try launcher.launchOwned(mode, controlInput: invalidPair.child); throw Failure(label: "incompatible mode accepted") }
            catch let error as ControlledLaunchError { try check(error == .incompatibleMode, "incompatible mode") }
        }
        do { _ = try launcher.launchOwned(spec, controlInput: .nullDevice); throw Failure(label: "invalid fd accepted") } catch is Failure { throw Failure(label: "invalid fd accepted") } catch { }
        try check(recorder.snapshot.isEmpty, "invalid mode/fd no spawn")
        invalidPair.parent.close(); try invalidPair.child.close()
        let workspace = SafarierWorkspace(root: root)
        var profile = Profile(id: UUID(), name: "fixture", mode: .ephemeral, languages: ["en-US"], timeZoneIdentifier: "UTC", startURL: URL(string: "https://example.invalid"))
        let workspacePair = try AutomationChannel.makePair()
        defer { workspacePair.parent.close(); try? workspacePair.child.close() }
        do { _ = try workspace.launchOwnedBackground(profile, launcher: launcher, controlInput: workspacePair.child); throw Failure(label: "unauthorized profile accepted") }
        catch let error as ControlledLaunchError { try check(error == .backgroundNotAllowed, "profile permission") }
        try check(recorder.snapshot.isEmpty, "unauthorized profile no spawn")
        profile.allowsBackgroundAutomation = true
        do { _ = try workspace.launchOwnedBackground(profile, launcher: launcher); throw Failure(label: "workspace missing input accepted") }
        catch let error as ControlledLaunchError { try check(error == .missingControlledInput, "workspace missing input rejected") }
        try check(recorder.snapshot.isEmpty, "missing input no spawn")
        let lock = try ProfileLock.acquire(profileID: profile.id, in: workspace.locksDirectory)
        do { _ = try workspace.launchOwnedBackground(profile, launcher: launcher, controlInput: workspacePair.child); throw Failure(label: "locked profile accepted") }
        catch let error as WorkspaceError { try check(error == .alreadyRunning(profile.id), "existing lock") }
        try check(recorder.snapshot.isEmpty, "locked profile no spawn")
        lock.release()
        let child = try workspace.launchOwnedBackground(profile, launcher: launcher, controlInput: workspacePair.child)
        try workspacePair.child.close(); workspacePair.parent.close()
        let childExit = try await child.waitForExit(timeoutSeconds: 3)
        let recorded = recorder.snapshot
        try check(childExit?.status == 0 && recorded.count == 1, "workspace actual owned process")
        guard let call = recorded.first else { throw Failure(label: "missing launch facts") }
        let parsed = try RunnerLaunchSpec.parse(call.arguments, environment: call.environment)
        try check(parsed == workspace.runnerSpec(for: profile, backgroundAutomation: true), "workspace reuses exact spec")
        try check(call.environment["SAFARIER_HOME"] == root.path && call.environment["TZ"] == "UTC" && !call.environment.keys.contains(where: { $0.hasPrefix("SAFARIER_GEO_") }) && call.log == root.appendingPathComponent("\(profile.id.uuidString).log"), "workspace isolated environment and log")
        let lockFile = workspace.locksDirectory.appendingPathComponent("\(profile.id.uuidString).lock")
        _ = unlink(lockFile.path); _ = rmdir(workspace.locksDirectory.path)
        _ = unlink(root.appendingPathComponent("\(profile.id.uuidString).log").path)
        let ordinary = try spawner.spawn(executableURL: helper, arguments: [], environment: ["OWNED_FIXTURE_MODE":"exit7"], logURL: nil)
        for _ in 0..<500 { if observer.values.contains(where: { $0.pid == ordinary }) { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try check(observer.values.filter { $0.pid == ordinary }.count == 1 && observer.values.first(where: { $0.pid == ordinary })?.status == 7, "ordinary onExit remains intact")
        return checks
    }
}
