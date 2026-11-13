import Foundation
import Darwin
import SafarierCore

public enum ControlledRunnerCases {
    struct Failure: Error { let description: String }
    final class OldSpawner: ProcessSpawning, @unchecked Sendable {
        var calls = 0
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 { calls += 1; return 123 }
    }
    actor StartGate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func ready() -> Bool { continuation != nil }
        func release() { continuation?.resume(); continuation = nil }
    }
    final class CountedSpawner: ProcessSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
            lock.withLock { count += 1 }; return getpid()
        }
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> Int32 {
            lock.withLock { count += 1 }; return getpid()
        }
    }
    final class ConfiguredSpawner: ProcessSpawning, @unchecked Sendable {
        let additions: [String: String]
        private let lock = NSLock()
        private var exitValue: ProcessExit?
        private var launchArguments: [String] = []
        private var launchEnvironment: [String: String] = [:]
        init(_ additions: [String: String] = [:]) { self.additions = additions }
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
            try spawn(executableURL: executableURL, arguments: arguments, environment: environment, logURL: logURL, standardInput: .nullDevice)
        }
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> Int32 {
            var env = environment; for (k,v) in additions { env[k] = v }
            lock.withLock { launchArguments = arguments; launchEnvironment = env }
            return try FoundationProcessSpawner(onExit: { [weak self] result in self?.lock.withLock { self?.exitValue = result } }).spawn(executableURL: executableURL, arguments: arguments, environment: env, logURL: logURL, standardInput: standardInput)
        }
        func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> OwnedRunnerProcess {
            var env = environment; for (k, v) in additions { env[k] = v }
            lock.withLock { launchArguments = arguments; launchEnvironment = env }
            return try FoundationProcessSpawner(onExit: { [weak self] result in self?.lock.withLock { self?.exitValue = result } }).spawnOwned(executableURL: executableURL, arguments: arguments, environment: env, logURL: logURL, standardInput: standardInput)
        }
        func exitStatus() -> ProcessExit? { lock.withLock { exitValue } }
        func args() -> [String] { lock.withLock { launchArguments } }
        func env() -> [String: String] { lock.withLock { launchEnvironment } }
        func waitForExit() async throws -> ProcessExit {
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let status = exitStatus() { return status }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw Failure(description: "helper did not exit after channel close")
        }
    }
    static func check(_ value: Bool, _ label: String) throws { if !value { throw Failure(description: label) } }
    static func rejects(_ block: () throws -> Void, _ label: String) throws {
        do { try block() } catch { return }; throw Failure(description: label)
    }
    public static func run() async throws -> Int {
        var count = 0
        let id = UUID()
        let spec = RunnerLaunchSpec(profileID: id, startURL: URL(string: "about:blank"), backgroundAutomation: true)
        try check(try RunnerLaunchSpec.parse(spec.arguments()) == spec, "background spec roundtrip"); count += 1
        try rejects({ _ = try RunnerLaunchSpec.parse(spec.arguments() + ["--probe"]) }, "probe conflict"); count += 1
        let spawner = OldSpawner(); let launcher = RunnerLauncher(executableURL: URL(fileURLWithPath: "/test"), spawner: spawner)
        try rejects({ _ = try launcher.launch(spec) }, "missing input"); count += 1
        let normalSpec = RunnerLaunchSpec(profileID: id, languages: ["en-US"], timeZoneIdentifier: "Asia/Tokyo")
        try check(try launcher.launch(normalSpec, baseEnvironment: ["HOME":"/fixture"]) == 123, "normal launch"); count += 1
        try check(spawner.calls == 1, "normal spawner called"); spawner.calls = 0
        let null = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { try? null.close() }
        try rejects({ _ = try launcher.launch(spec, controlInput: null) }, "invalid input"); count += 1
        let pair = try AutomationChannel.makePair(); defer { pair.parent.close(); try? pair.child.close() }
        try rejects({ _ = try launcher.launch(RunnerLaunchSpec(profileID: id), controlInput: pair.child) }, "normal input"); count += 1
        try rejects({ _ = try launcher.launch(spec, controlInput: pair.child) }, "old spawner unsupported"); try check(spawner.calls == 0, "no fallback"); count += 1
        let workspace = SafarierWorkspace(root: FileManager.default.temporaryDirectory.appendingPathComponent("controlled-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        var profile = Profile(id: id, name: "fixture", mode: .persistent, startURL: URL(string: "https://example.com"))
        try rejects({ _ = try workspace.launch(profile, launcher: launcher, backgroundAutomation: true, controlInput: pair.child) }, "not authorized"); count += 1
        profile.allowsBackgroundAutomation = true
        let counted = CountedSpawner()
        let countedLauncher = RunnerLauncher(executableURL: URL(fileURLWithPath: "/unused-fixture"), spawner: counted)
        let overflowBoundary = Double(UInt64.max) / 1_000_000_000
        for timeout in [Double.nan, .infinity, -.infinity, 0, -0.0, -1, overflowBoundary, overflowBoundary * 2] {
            do {
                _ = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: countedLauncher, timeoutSeconds: timeout)
                throw Failure(description: "invalid startup timeout accepted")
            } catch let e as AutomationError {
                try check(e.code == .invalidRequest, "invalid timeout error")
            }
        }
        try check(counted.calls == 0, "invalid startup timeout invoked spawner \(counted.calls) times"); count += 8
        let gate = StartGate()
        let cancelledBeforeStart = Task {
            await gate.wait()
            return try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: countedLauncher, timeoutSeconds: 1)
        }
        let gateDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !(await gate.ready()) && DispatchTime.now().uptimeNanoseconds < gateDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
        if !(await gate.ready()) { cancelledBeforeStart.cancel(); await gate.release(); throw Failure(description: "cancellation gate timeout") }
        cancelledBeforeStart.cancel(); await gate.release()
        do { _ = try await cancelledBeforeStart.value; throw Failure(description: "pre-cancelled startup succeeded") }
        catch is CancellationError {}
        try check(counted.calls == 0, "pre-cancelled startup invoked spawner"); count += 1
        let bg = workspace.runnerSpec(for: profile, backgroundAutomation: true)
        try check(bg.startURL == URL(string: "about:blank") && bg.backgroundAutomation, "blank start"); count += 1
        let lock = try ProfileLock.acquire(profileID: id, in: workspace.locksDirectory); defer { lock.release() }
        try rejects({ _ = try workspace.launch(profile, launcher: launcher, backgroundAutomation: true, controlInput: pair.child) }, "profile lock"); count += 1
        lock.release()
        if let path = ProcessInfo.processInfo.environment["CONTROLLED_HELPER_PATH"] {
            try workspace.profiles.insert(profile)
            let executable = URL(fileURLWithPath: path)
            var pipeFD: [Int32] = [-1, -1]; try check(pipe(&pipeFD) == 0, "fixture pipe")
            defer { Darwin.close(pipeFD[0]); Darwin.close(pipeFD[1]) }
            try check(fcntl(pipeFD[0], F_SETFD, 0) == 0, "fixture clears cloexec")
            var info = stat(); try check(fstat(pipeFD[0], &info) == 0, "fixture stat")
            let spawn = ConfiguredSpawner(["CONTROLLED_EXEC":"1", "CONTROLLED_CHECK_FD":String(pipeFD[0]), "CONTROLLED_CHECK_INO":String(info.st_ino), "CONTROLLED_CHECK_DEV":String(info.st_dev), "CONTROLLED_EXPECT_HOME":workspace.root.path])
            let launcher = RunnerLauncher(executableURL: executable, spawner: spawn)
            let client = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: launcher, timeoutSeconds: 3)
            let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
            let reply = try await client.request(request, timeoutSeconds: 3)
            try check(reply.requestID == request.requestID, "reply id"); count += 1
            try check(spawn.env()["SAFARIER_HOME"] == workspace.root.path, "controlled workspace root"); count += 1
            try check(workspace.isRunning(profile.id), "helper holds workspace lock"); count += 1
            if case .success(.capabilities(let caps)) = reply.outcome {
                try check(caps.backend == .unavailable && caps.role == "runner", "capabilities unavailable")
            } else { throw Failure(description: "capabilities outcome") }
            count += 1
            let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
            let result = try await client.request(open, timeoutSeconds: 3)
            if case .failure = result.outcome {} else { throw Failure(description: "open should fail") }
            count += 1
            let foreign = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: UUID()))
            do { _ = try await client.request(foreign); throw Failure(description: "foreign profile accepted") }
            catch is Failure { throw Failure(description: "foreign profile accepted") } catch {}
            let token = try AutomationSessionToken.generate()
            let pageActions: [AutomationAction] = [.getState, .navigate(url: URL(string: "https://example.com")!), .screenshot, .move(point: ViewportPoint(x: 1, y: 1), viewVersion: 1), .mouseDown(point: ViewportPoint(x: 1, y: 1), viewVersion: 1), .mouseUp(point: ViewportPoint(x: 1, y: 1), viewVersion: 1), .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1), .scroll(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, deltaX: 1, deltaY: 1), .insertText("fixture"), .key(name: .enter, shift: false), .cancel, .closeSession]
            for action in pageActions {
                let pageRequest = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: action)
                let pageReply = try await client.request(pageRequest, timeoutSeconds: 3)
                if case .failure(let error) = pageReply.outcome { try check(error.code == .backendUnavailable && error.sideEffects == .none, "backend failure remains unchanged") }
                else { throw Failure(description: "page action succeeded") }
                count += 1
            }
            try check(!spawn.args().joined(separator: " ").contains("nonce") && spawn.env()["SAFARIER_AUTOMATION_NONCE"] == nil && spawn.env()["SAFARIER_AUTOMATION_TOKEN"] == nil, "sensitive launch parameters"); count += 1
            await client.close()
            let exited = try await spawn.waitForExit()
            try check(exited.status == 0 && !exited.uncaughtSignal, "exec/unspecified fd/EOF helper exit"); count += 1
            try check(!workspace.isRunning(profile.id), "helper releases workspace lock"); count += 1
            for mode in ["bad-role", "bad-effect", "bad-id", "bad-target", "bad-instance", "bad-state"] {
                let child = ConfiguredSpawner(["CONTROLLED_BAD":mode])
                let badLauncher = RunnerLauncher(executableURL: executable, spawner: child)
                let badClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: badLauncher, timeoutSeconds: 3)
                let badRequest = (mode == "bad-target" || mode == "bad-instance") ? open : (mode == "bad-state" ? AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState) : request)
                do { _ = try await badClient.request(badRequest, timeoutSeconds: 3); throw Failure(description: "accepted \(mode)") }
                catch is Failure { throw Failure(description: "accepted \(mode)") } catch {}
                do { _ = try await badClient.request(request); throw Failure(description: "channel not closed \(mode)") }
                catch is Failure { throw Failure(description: "channel not closed \(mode)") } catch {}
                let status = try await child.waitForExit(); try check(status.status == 0, "negative helper EOF"); count += 1
            }
            let slow = ConfiguredSpawner(["CONTROLLED_BAD":"stall"])
            let slowLauncher = RunnerLauncher(executableURL: executable, spawner: slow)
            do { _ = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: slowLauncher, timeoutSeconds: 0.1); throw Failure(description: "startup timeout accepted") }
            catch is Failure { throw Failure(description: "startup timeout accepted") } catch {}
            _ = try await slow.waitForExit(); count += 1
            let cancelled = ConfiguredSpawner(["CONTROLLED_BAD":"stall"])
            let cancelLauncher = RunnerLauncher(executableURL: executable, spawner: cancelled)
            let startup = Task { try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: cancelLauncher, timeoutSeconds: 3) }
            let startDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while cancelled.args().isEmpty && DispatchTime.now().uptimeNanoseconds < startDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
            try check(!cancelled.args().isEmpty, "cancel fixture spawned")
            startup.cancel()
            do { _ = try await startup.value; throw Failure(description: "cancelled startup succeeded") }
            catch is Failure { throw Failure(description: "cancelled startup succeeded") } catch {}
            _ = try await cancelled.waitForExit(); count += 1
            let rpcReady = workspace.root.appendingPathComponent("busy-\(UUID().uuidString).ready")
            defer { try? FileManager.default.removeItem(at: rpcReady) }
            let stalledRPC = ConfiguredSpawner(["CONTROLLED_BAD":"stall-rpc", "CONTROLLED_READY_FILE":rpcReady.path])
            let rpcLauncher = RunnerLauncher(executableURL: executable, spawner: stalledRPC)
            let rpcClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: rpcLauncher, timeoutSeconds: 3)
            let pending = Task { try await rpcClient.request(request, timeoutSeconds: 5) }
            do {
                let readyDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                while !FileManager.default.fileExists(atPath: rpcReady.path) && DispatchTime.now().uptimeNanoseconds < readyDeadline {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                try check(FileManager.default.fileExists(atPath: rpcReady.path), "busy fixture did not receive first request")
                do { _ = try await rpcClient.request(request); throw Failure(description: "overlapping duplicate RPC accepted") }
                catch let error as AutomationError { try check(error.code == .requestIDReused, "duplicate ID error") }
                pending.cancel()
                do { _ = try await pending.value; throw Failure(description: "cancelled RPC succeeded") }
                catch is Failure { throw Failure(description: "cancelled RPC succeeded") } catch {}
                do { _ = try await rpcClient.request(request); throw Failure(description: "cancelled channel reused") }
                catch is Failure { throw Failure(description: "cancelled channel reused") } catch {}
                _ = try await stalledRPC.waitForExit(); count += 1
            } catch {
                await rpcClient.close(); pending.cancel(); _ = try? await pending.value
                _ = try? await stalledRPC.waitForExit()
                throw error
            }
            let timeoutReady = workspace.root.appendingPathComponent("timeout-\(UUID().uuidString).ready")
            defer { try? FileManager.default.removeItem(at: timeoutReady) }
            let timeoutRPC = ConfiguredSpawner(["CONTROLLED_BAD":"stall-rpc", "CONTROLLED_READY_FILE":timeoutReady.path])
            let timeoutClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: executable, spawner: timeoutRPC), timeoutSeconds: 3)
            do { _ = try await timeoutClient.request(request, timeoutSeconds: 0.2); throw Failure(description: "RPC timeout accepted") }
            catch let error as AutomationError { try check(error.code == .timeout && error.sideEffects == .none, "read-only timeout semantics") }
            catch { await timeoutClient.close(); throw error }
            do { _ = try await timeoutClient.request(request); throw Failure(description: "timed out channel reused") }
            catch is Failure { await timeoutClient.close(); throw Failure(description: "timed out channel reused") } catch {}
            _ = try await timeoutRPC.waitForExit(); count += 1
            let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
            for mode in ["stall-rpc", "drop-rpc", "bad-effect"] {
                let actionReady = workspace.root.appendingPathComponent("action-\(UUID().uuidString).ready")
                defer { try? FileManager.default.removeItem(at: actionReady) }
                let actionSpawner = ConfiguredSpawner(["CONTROLLED_BAD":mode, "CONTROLLED_READY_FILE":actionReady.path])
                let actionClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: executable, spawner: actionSpawner), timeoutSeconds: 3)
                do {
                    _ = try await actionClient.request(click, timeoutSeconds: mode == "stall-rpc" ? 0.2 : 3)
                    await actionClient.close(); throw Failure(description: "unknown action result accepted: \(mode)")
                } catch let error as AutomationError {
                    try check(error.code == .indeterminateResult && !error.retryable && error.sideEffects == .possible, "unknown action result \(mode)")
                } catch { await actionClient.close(); throw error }
                if mode == "stall-rpc" { try check(FileManager.default.fileExists(atPath: actionReady.path), "timeout helper received click") }
                await actionClient.close()
                let actionExit = try await actionSpawner.waitForExit()
                try check(actionExit.status == 0 && !actionExit.uncaughtSignal, "action helper exit")
                count += 1
            }
            let failureSpawner = ConfiguredSpawner(["CONTROLLED_BAD":"backend-failure"])
            let failureClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: executable, spawner: failureSpawner), timeoutSeconds: 3)
            let failureReply = try await failureClient.request(click, timeoutSeconds: 3)
            if case .failure(let error) = failureReply.outcome {
                try check(error.code == .backendUnavailable && error.retryable && error.sideEffects == .possible, "backend failure preserves fields")
            } else { throw Failure(description: "backend failure not returned") }
            await failureClient.close(); _ = try await failureSpawner.waitForExit(); count += 1
            let cancelReady = workspace.root.appendingPathComponent("action-cancel-\(UUID().uuidString).ready")
            defer { try? FileManager.default.removeItem(at: cancelReady) }
            let cancelActionSpawner = ConfiguredSpawner(["CONTROLLED_BAD":"stall-rpc", "CONTROLLED_READY_FILE":cancelReady.path])
            let cancelActionClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: executable, spawner: cancelActionSpawner), timeoutSeconds: 3)
            let cancelling = Task { try await cancelActionClient.request(click, timeoutSeconds: 5) }
            do {
                let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                while !FileManager.default.fileExists(atPath: cancelReady.path) && DispatchTime.now().uptimeNanoseconds < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
                try check(FileManager.default.fileExists(atPath: cancelReady.path), "cancel action in flight")
                cancelling.cancel()
                do { _ = try await cancelling.value; throw Failure(description: "cancelled action succeeded") }
                catch let error as AutomationError { try check(error.code == .indeterminateResult && error.sideEffects == .possible && !error.retryable, "cancelled action possible") }
                catch { throw error }
                await cancelActionClient.close(); _ = try await cancelActionSpawner.waitForExit(); count += 1
            } catch {
                await cancelActionClient.close(); cancelling.cancel(); _ = try? await cancelling.value
                _ = try? await cancelActionSpawner.waitForExit(); throw error
            }
            let invalidSpawner = ConfiguredSpawner()
            let invalidClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: executable, spawner: invalidSpawner), timeoutSeconds: 3)
            do { _ = try await invalidClient.request(click, timeoutSeconds: .infinity); throw Failure(description: "invalid RPC timeout accepted") }
            catch let error as AutomationError { try check(error.code == .invalidRequest && error.sideEffects == .none, "pre-send validation") }
            catch { await invalidClient.close(); throw error }
            await invalidClient.close(); _ = try await invalidSpawner.waitForExit(); count += 1
            let ready = workspace.root.appendingPathComponent("late-\(UUID().uuidString).ready")
            defer { try? FileManager.default.removeItem(at: ready) }
            let lateSpawner = ConfiguredSpawner(["CONTROLLED_BAD":"late", "CONTROLLED_READY_FILE":ready.path])
            let lateClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: executable, spawner: lateSpawner), timeoutSeconds: 3)
            let lateRequest = Task { try await lateClient.request(request, timeoutSeconds: 3) }
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !FileManager.default.fileExists(atPath: ready.path) && DispatchTime.now().uptimeNanoseconds < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            if !FileManager.default.fileExists(atPath: ready.path) { await lateClient.close(); _ = try? await lateRequest.value; throw Failure(description: "late fixture not ready") }
            await lateClient.close()
            do { _ = try await lateRequest.value; throw Failure(description: "late reply succeeded after close") }
            catch is Failure { throw Failure(description: "late reply succeeded after close") } catch {}
            _ = try await lateSpawner.waitForExit(); count += 1
        }
        return count
    }
}
