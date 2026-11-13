import Foundation
import Darwin
import SafarierCore

public enum RunnerMultiplexCases {
    struct Failure: Error { let label: String }
    actor Marker {
        var calls = 0
        func mark() { calls += 1 }
    }
    final class ExitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ProcessExit?
        func record(_ exit: ProcessExit) { lock.lock(); value = exit; lock.unlock() }
        var observed: ProcessExit? { lock.lock(); defer { lock.unlock() }; return value }
    }
    struct FixtureSpawner: ProcessSpawning {
        let mode: String
        var markerPath: String? = nil
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
            throw AutomationError(code: .backendUnavailable)
        }
        func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> OwnedRunnerProcess {
            var environment = environment; environment["CONTROLLED_BAD"] = mode
            if let markerPath { environment["CONTROLLED_MUTATION_MARKER"] = markerPath }
            return try FoundationProcessSpawner().spawnOwned(executableURL: executableURL, arguments: arguments, environment: environment, logURL: logURL, standardInput: standardInput)
        }
    }
    public static func run() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws { checks += 1; if !value { throw Failure(label: label) } }
        let profileID = UUID(), instanceID = UUID()
        let pair = try AutomationChannel.makePair()
        let serverChannel = try AutomationChannel(adopting: pair.child)
        let shutdowns = Marker()
        let server = AutomationRunnerServer(profileID: profileID, runnerInstanceID: instanceID, channel: serverChannel, idleSeconds: 5, maxOrdinaryRequests: 1, handler: { request in
            switch request.action {
            case .capabilities:
                try? await Task.sleep(nanoseconds: 500_000_000)
                return .success(.capabilities(AutomationCapabilities(backend: .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: "1", role: "runner", managerPID: Int(getppid()))))
            case .cancel:
                return .success(.sessionClosed(CleanupReceipt(cleaned: true, terminatedOwnedRunner: false)))
            default: return .failure(AutomationError(code: .backendUnavailable))
            }
        }, shutdown: { Task { await shutdowns.mark() } })
        let running = Task { await server.serve() }
        let nonce = try AutomationSessionToken.generate()
        try await pair.parent.send(AutomationHandshakeCodec.makeChallenge(profileID: profileID, nonce: nonce))
        guard let hello = try await pair.parent.receive() else { throw Failure(label: "no hello") }
        let response = try AutomationHandshakeCodec.readResponse(hello, expectedProfileID: profileID, expectedNonce: nonce, expectedPID: getpid())
        try check(response.runnerInstanceID == instanceID, "instance binding")
        let slow = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
        let cancel = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .cancel)
        try await pair.parent.send(AutomationCodec.encodeRequest(slow))
        try await pair.parent.send(AutomationCodec.encodeRequest(cancel))
        guard let first = try await pair.parent.receive(), let second = try await pair.parent.receive() else { throw Failure(label: "missing replies") }
        try check(try AutomationCodec.decodeReply(first).requestID == cancel.requestID, "reserved cancellation overtakes stalled ordinary")
        try check(try AutomationCodec.decodeReply(second).requestID == slow.requestID, "out of order association")
        pair.parent.close()
        try check(await running.value == 0, "EOF shutdown")
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(await shutdowns.calls == 1, "one shutdown")
        let malformedPair = try AutomationChannel.makePair()
        let malformedChannel = try AutomationChannel(adopting: malformedPair.child)
        let malformedHandlers = Marker(), malformedShutdowns = Marker()
        let malformedServer = AutomationRunnerServer(profileID: profileID, channel: malformedChannel, idleSeconds: 2, handler: { _ in
            await malformedHandlers.mark()
            return .failure(AutomationError(code: .backendUnavailable))
        }, shutdown: { Task { await malformedShutdowns.mark() } })
        let malformedRunning = Task { await malformedServer.serve() }
        let malformedNonce = try AutomationSessionToken.generate()
        try await malformedPair.parent.send(AutomationHandshakeCodec.makeChallenge(profileID: profileID, nonce: malformedNonce))
        guard try await malformedPair.parent.receive() != nil else { throw Failure(label: "malformed handshake") }
        try await malformedPair.parent.send(Data("{\"bad\":true}".utf8))
        guard let malformedFrame = try await malformedPair.parent.receive() else { throw Failure(label: "malformed diagnostic missing") }
        let malformedReply = try AutomationCodec.decodeReply(malformedFrame)
        try check(malformedReply.requestID == nil && malformedReply.outcome == .failure(AutomationError(code: .invalidRequest)), "fixed malformed diagnostic")
        try check(try await malformedPair.parent.receive() == nil, "malformed closes after diagnostic")
        try check(await malformedRunning.value == 1, "malformed failure exit")
        try await Task.sleep(nanoseconds: 50_000_000)
        let malformedHandlerCount = await malformedHandlers.calls
        let malformedShutdownCount = await malformedShutdowns.calls
        try check(malformedHandlerCount == 0 && malformedShutdownCount == 1, "malformed bypasses handler and shuts once")
        malformedPair.parent.close()
        let saturatedPair = try AutomationChannel.makePair()
        var smallBuffer: Int32 = 1024
        guard setsockopt(saturatedPair.child.fileDescriptor, SOL_SOCKET, SO_SNDBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure(label: "socket buffer setup") }
        let saturatedChannel = try AutomationChannel(adopting: saturatedPair.child)
        let saturatedHandlers = Marker(), saturatedShutdowns = Marker()
        let saturatedServer = AutomationRunnerServer(profileID: profileID, channel: saturatedChannel, idleSeconds: 5, handler: { _ in
            await saturatedHandlers.mark()
            return .success(.capabilities(AutomationCapabilities(backend: .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: String(repeating: "a", count: 60000), role: "runner", managerPID: Int(getppid()))))
        }, shutdown: { Task { await saturatedShutdowns.mark() } })
        let saturatedRunning = Task { await saturatedServer.serve() }
        let saturatedNonce = try AutomationSessionToken.generate()
        try await saturatedPair.parent.send(AutomationHandshakeCodec.makeChallenge(profileID: profileID, nonce: saturatedNonce))
        guard try await saturatedPair.parent.receive() != nil else { throw Failure(label: "saturated handshake") }
        for _ in 0..<2 {
            let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
            try await saturatedPair.parent.send(AutomationCodec.encodeRequest(request))
        }
        for _ in 0..<2 {
            let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .cancel)
            try await saturatedPair.parent.send(AutomationCodec.encodeRequest(request))
        }
        let saturatedDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while await saturatedHandlers.calls < 4 && DispatchTime.now().uptimeNanoseconds < saturatedDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(await saturatedHandlers.calls == 4, "saturation handlers entered")
        try await Task.sleep(nanoseconds: 100_000_000)
        let saturatedStart = DispatchTime.now().uptimeNanoseconds
        try await saturatedPair.parent.send(Data("{\"bad\":true}".utf8))
        try check(await saturatedRunning.value == 1, "saturated malformed shuts down")
        try check(DispatchTime.now().uptimeNanoseconds - saturatedStart < 1_000_000_000, "saturated malformed does not enqueue or wait")
        try await Task.sleep(nanoseconds: 50_000_000)
        let saturatedHandlerCount = await saturatedHandlers.calls
        let saturatedShutdownCount = await saturatedShutdowns.calls
        try check(saturatedHandlerCount == 4 && saturatedShutdownCount == 1, "saturated malformed has no handler and one shutdown")
        saturatedPair.parent.close()
        let pair2 = try AutomationChannel.makePair()
        let server2Channel = try AutomationChannel(adopting: pair2.child)
        let shutdown2 = Marker()
        let server2 = AutomationRunnerServer(profileID: profileID, channel: server2Channel, idleSeconds: 5, handler: { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
            }
            return .failure(AutomationError(code: .backendUnavailable))
        }, shutdown: { Task { await shutdown2.mark() } })
        let running2 = Task { await server2.serve() }
        let nonce2 = try AutomationSessionToken.generate()
        try await pair2.parent.send(AutomationHandshakeCodec.makeChallenge(profileID: profileID, nonce: nonce2))
        guard try await pair2.parent.receive() != nil else { throw Failure(label: "second handshake") }
        try await pair2.parent.send(AutomationCodec.encodeRequest(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)))
        try await Task.sleep(nanoseconds: 50_000_000)
        let closing = DispatchTime.now().uptimeNanoseconds
        pair2.parent.close()
        try check(await running2.value == 0, "EOF with uncooperative handler")
        try check(DispatchTime.now().uptimeNanoseconds - closing < 500_000_000, "shutdown does not await uncooperative handler")
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(await shutdown2.calls == 1, "uncooperative shutdown once")
        let invalidPair = try AutomationChannel.makePair()
        let invalidChannel = try AutomationChannel(adopting: invalidPair.child)
        let invalidServer = AutomationRunnerServer(profileID: profileID, channel: invalidChannel, idleSeconds: 1, handler: { _ in .failure(AutomationError(code: .backendUnavailable)) }, shutdown: {})
        let invalidRunning = Task { await invalidServer.serve() }
        let invalidNonce = try AutomationSessionToken.generate()
        try await invalidPair.parent.send(AutomationHandshakeCodec.makeChallenge(profileID: UUID(), nonce: invalidNonce))
        try check(await invalidRunning.value == 1, "wrong-profile handshake refused")
        invalidPair.parent.close()
        if let helper = ProcessInfo.processInfo.environment["CONTROLLED_HELPER_PATH"] {
            let base = ProcessInfo.processInfo.environment["STAGE7_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
            let root = base.appendingPathComponent("mux-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = SafarierWorkspace(root: root)
            var profile = Profile(name: "owned-test", mode: .ephemeral)
            profile.allowsBackgroundAutomation = true
            try workspace.profiles.insert(profile)
            let launcher = RunnerLauncher(executableURL: URL(fileURLWithPath: helper), spawner: FoundationProcessSpawner())
            let client = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: launcher, timeoutSeconds: 3)
            let req1 = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
            let req2 = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
            async let a = client.request(req1, timeoutSeconds: 3)
            async let b = client.request(req2, timeoutSeconds: 3)
            let replies = try await [a, b]
            try check(Set(replies.compactMap(\.requestID)) == Set([req1.requestID, req2.requestID]), "concurrent owned client")
            do { _ = try await client.request(req1, timeoutSeconds: 3); throw Failure(label: "completed ID reused") }
            catch let error as AutomationError { try check(error.code == .requestIDReused && error.sideEffects == .none, "completed ID cannot rebind late reply") }
            let batch = (0..<8).map { _ in AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities) }
            let batchTasks = batch.map { request in Task { try await client.request(request, timeoutSeconds: 3) } }
            var batchIDs: Set<UUID> = []
            for task in batchTasks { if let id = try await task.value.requestID { batchIDs.insert(id) } }
            try check(batchIDs == Set(batch.map(\.requestID)), "bounded eight concurrent requests")
            let exit = try await client.closeAndWait(timeoutSeconds: 3)
            try check(exit?.pid == client.pid, "observe own helper exit")
            let recorder = ExitRecorder()
            let observedSpawner = FoundationProcessSpawner(onExit: { recorder.record($0) })
            var dropped: AutomationRunnerClient? = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: URL(fileURLWithPath: helper), spawner: observedSpawner), timeoutSeconds: 3)
            let droppedPID = dropped!.pid
            dropped = nil
            let dropDeadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
            while recorder.observed == nil && DispatchTime.now().uptimeNanoseconds < dropDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try check(recorder.observed?.pid == droppedPID, "dropping idle client closes owned channel")
            let mutationMarker = root.appendingPathComponent("unexpected-mutation")
            let slowLauncher = RunnerLauncher(executableURL: URL(fileURLWithPath: helper), spawner: FixtureSpawner(mode: "multiplex", markerPath: mutationMarker.path))
            let mux = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: slowLauncher, timeoutSeconds: 3)
            let cancelledRequest = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .mouseDown(point: ViewportPoint(x: 1, y: 1), viewVersion: 1))
            let alreadyCancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await mux.request(cancelledRequest, timeoutSeconds: 3)
            }
            do { _ = try await alreadyCancelled.value; throw Failure(label: "pre-cancel accepted") }
            catch let error as AutomationError { try check(error.code == .cancelled && error.sideEffects == .none, "pre-cancel is unsent") }
            let expired = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .mouseDown(point: ViewportPoint(x: 1, y: 1), viewVersion: 1))
            do { _ = try await mux.request(expired, timeoutSeconds: 0.000000001); throw Failure(label: "expired send accepted") }
            catch let error as AutomationError { try check(error.code == .timeout && error.sideEffects == .none, "expired before send is unsent") }
            try await Task.sleep(nanoseconds: 30_000_000)
            try check(!FileManager.default.fileExists(atPath: mutationMarker.path), "pre-cancelled and expired mutations never reached handler")
            let slowRequest = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
            let blocked = Task { try await mux.request(slowRequest, timeoutSeconds: 3) }
            try await Task.sleep(nanoseconds: 100_000_000)
            do { _ = try await mux.request(slowRequest, timeoutSeconds: 3); throw Failure(label: "duplicate accepted") }
            catch let error as AutomationError { try check(error.code == .requestIDReused && error.sideEffects == .none, "duplicate rejected locally") }
            let cancelRequest = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .cancel)
            let start = DispatchTime.now().uptimeNanoseconds
            let cancelReply = try await mux.request(cancelRequest, timeoutSeconds: 2)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            try check(cancelReply.requestID == cancelRequest.requestID && elapsed < 500_000_000, "cancel overtakes blocked request")
            try check(try await blocked.value.requestID == slowRequest.requestID, "slow reply matched")
            _ = try await mux.closeAndWait(timeoutSeconds: 3)
            let dropping = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(executableURL: URL(fileURLWithPath: helper), spawner: FixtureSpawner(mode: "drop-rpc")), timeoutSeconds: 3)
            let mutation = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .mouseDown(point: ViewportPoint(x: 1, y: 1), viewVersion: 1))
            do { _ = try await dropping.request(mutation, timeoutSeconds: 3); throw Failure(label: "drop accepted") }
            catch let error as AutomationError { try check(error.code == .indeterminateResult && error.sideEffects == .possible, "sent mutation ambiguous") }
            _ = try await dropping.closeAndWait(timeoutSeconds: 3)
            let budgetClient = try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: launcher, timeoutSeconds: 3)
            for _ in 0..<4094 {
                let item = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
                _ = try await budgetClient.request(item, timeoutSeconds: 3)
            }
            do {
                let extra = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
                _ = try await budgetClient.request(extra, timeoutSeconds: 3)
                throw Failure(label: "normal request consumed cleanup reserve")
            } catch let error as AutomationError {
                try check(error.code == .replayWindowFull && error.sideEffects == .none, "normal budget preserves cleanup slots")
            }
            for _ in 0..<2 {
                let cleanup = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .cancel)
                let reply = try await budgetClient.request(cleanup, timeoutSeconds: 3)
                try check(reply.requestID == cleanup.requestID, "reserved cleanup reaches handler")
            }
            do {
                let cleanup = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .closeSession)
                _ = try await budgetClient.request(cleanup, timeoutSeconds: 3)
                throw Failure(label: "hard budget accepted cleanup")
            } catch let error as AutomationError { try check(error.code == .replayWindowFull && error.sideEffects == .none, "hard budget rejects cleanup") }
            do {
                let after = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
                _ = try await budgetClient.request(after, timeoutSeconds: 3)
                throw Failure(label: "hard-budget channel remained open")
            } catch let error as AutomationError { try check(error.code == .runnerExited, "hard budget closes channel before wait") }
            let budgetExit = try await budgetClient.closeAndWait(timeoutSeconds: 3)
            try check(budgetExit?.pid == budgetClient.pid, "hard budget closes channel and own helper exits")
        }
        return checks
    }
}
