import Foundation
import Darwin
#if SAFARIER_BOUND_LOCAL_CANDIDATE
import OSLog
#endif


enum ControllerRequestMintUnavailable: Error { case noLongerLive }

/// Local startup failure, distinct from protocol replies from the Runner.
public enum AutomationRunnerClientStartError: Error {
    case launcherIdentityMismatch
    case cleanupUnconfirmed(underlying: Error)
}

/// A private channel to one exact owned Runner. It never replays requests.
public actor AutomationRunnerClient {
    public nonisolated let pid: Int32
    public nonisolated let runnerInstanceID: UUID
    public nonisolated let ownershipID: UUID
    public nonisolated let absoluteLifetimeDeadline: Double?
    private let profileID: UUID
    private let channel: AutomationChannel
    private let owner: OwnedRunnerProcess
    nonisolated let fixtureContext: ControllerGenerationContext
    private var closed = false
    private var boundTarget: AutomationTargetIdentity?
    private var releasePreparation: ControlReleasePreparation?
    private var validatedRelease: ControlReleaseReceipt?
    private var releasedOwnerTaken = false
    private var pending: [UUID: Pending] = [:]
    // Correlation-only tombstones; no cached result, retry, or replay scheduler.
    private var sentIDs: Set<UUID> = []
    private let maxSentIDs = 4096
    private var ordinaryCount = 0
    private var reservedCount = 0
    private struct Outbound {
        let id: UUID
        let generation: UUID
        let bytes: Data
        let reserved: Bool
    }
    private var outbound: [Outbound] = []
    private var ordinarySends = 0
    private var reservedSends = 0
    private let maxOrdinary = 8
    private let maxReserved = 2

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private struct Pending {
        let action: AutomationAction
        let generation: UUID
        let cancellation: CancellationFlag
        let deadline: UInt64
        let bytes: Data
        var minting: Bool
        var admission: SealedWriteAdmission?
        let continuation: CheckedContinuation<AutomationReply, Error>
        let reserved: Bool
        var attempted: Bool
        var timer: Task<Void, Never>?
    }
    private init(owner: OwnedRunnerProcess, profileID: UUID, runnerInstanceID: UUID, channel: AutomationChannel, context: ControllerGenerationContext) {
        self.owner = owner; self.pid = owner.pid; self.ownershipID = owner.ownershipID
        let (end, overflow) = context.lifetimeStart.addingReportingOverflow(UInt64(AutomationLimits.generationSeconds * 1_000_000_000))
        self.absoluteLifetimeDeadline = overflow ? nil : Double(end) / 1_000_000_000
        self.profileID = profileID; self.runnerInstanceID = runnerInstanceID; self.channel = channel; self.fixtureContext = context
    }
    deinit {
        let context = fixtureContext
        context.revokeFromClientDeinit()
        channel.close()
        for item in pending.values { item.timer?.cancel() }
        Task { await context.safeClose() }
    }
    private static func validTimeout(_ seconds: Double) -> Bool {
        guard seconds.isFinite, seconds > 0, seconds < Double(UInt64.max / 1_000_000_000) - 1 else { return false }
        let nanos = UInt64(seconds * 1_000_000_000)
        return !DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(nanos).overflow
    }
    static func prepareLocksDirectory(workspace: SafarierWorkspace) throws {
        let root = workspace.root.standardizedFileURL
        let rootPin = try PrivateDirectoryPin(path: root)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RepositoryBindingProvider.Failure.directoryChanged }
        defer { Darwin.close(fd) }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, lstat(root.path, &named) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino, rootPin.matches() else {
            throw RepositoryBindingProvider.Failure.directoryChanged
        }
        if mkdirat(fd, "locks", 0o700) != 0 && errno != EEXIST {
            throw RepositoryBindingProvider.Failure.directoryChanged
        }
        let locksPin = try PrivateDirectoryPin(path: workspace.locksDirectory.standardizedFileURL)
        guard rootPin.matches(), locksPin.matches() else { throw RepositoryBindingProvider.Failure.directoryChanged }
    }
    public static func start(profile: Profile, workspace: SafarierWorkspace, launcher: RunnerLauncher, timeoutSeconds: Double = AutomationLimits.startupSeconds) async throws -> AutomationRunnerClient {
        guard validTimeout(timeoutSeconds) else { throw AutomationError(code: .invalidRequest) }
        let start = DispatchTime.now().uptimeNanoseconds
        let (cutoff, overflow) = start.addingReportingOverflow(UInt64(timeoutSeconds * 1_000_000_000))
        guard !overflow else { throw AutomationError(code: .invalidRequest) }
        let spec = workspace.runnerSpec(for: profile, backgroundAutomation: true)
        var base = ProcessInfo.processInfo.environment; base["SAFARIER_HOME"] = workspace.root.path
        let environment = spec.environment(inheriting: base)
        let pair = try AutomationChannel.makePair()
        return try await withTaskCancellationHandler(operation: {
            var context: ControllerGenerationContext?
            var retainedOwner: OwnedRunnerProcess?
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            var diagnosticPhase = "client.prepare_context"
            #endif
            do {
                try Task.checkCancellation()
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticPhase = "client.prepare_locks_directory"
                #endif
                try prepareLocksDirectory(workspace: workspace)
                try Task.checkCancellation()
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticPhase = "client.prepare_context"
                #endif
                let c = try await ControllerGenerationContext.prepare(channel: pair.parent, workspace: workspace, expectedSpec: spec, actualArgs: spec.arguments(), environment: environment, lifetimeStart: start, startupCutoff: cutoff)
                context = c
                try Task.checkCancellation()
                // The path is an additional restriction, not identity authority: c's
                // path comes from the C-verified role pair and signed outer bundle.
                // Reject lexical aliases as well as symlink resolution differences so
                // Process cannot interpret a different path than the one compared.
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticPhase = "client.launcher_identity"
                #endif
                let expected = c.runnerExecutablePath
                let executable = launcher.executableURL
                guard executable.isFileURL, executable.path == expected,
                      executable.standardizedFileURL.path == expected,
                      executable.resolvingSymlinksInPath().path == expected else {
                    throw AutomationRunnerClientStartError.launcherIdentityMismatch
                }
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticPhase = "client.launch_owned"
                #endif
                let owner = try workspace.launchOwnedBackground(profile, launcher: launcher, controlInput: pair.child)
                retainedOwner = owner
                try pair.child.close()
                try Task.checkCancellation()
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticPhase = "client.capture_birth"
                #endif
                let birth = try await c.captureOwnedBirth(owner)
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticPhase = "client.attach_owned"
                #endif
                try await c.attachOwnedChildOnce(owner, birth: birth)
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                diagnosticPhase = "client.start_fixture"
                #endif
                return try await startFixture(context: c, startupCutoff: cutoff)
            } catch {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                let diagnosticNow = DispatchTime.now().uptimeNanoseconds
                let diagnosticElapsed = diagnosticNow >= start ? (diagnosticNow - start) / 1_000_000 : 0
                let diagnosticCode: String
                if let error = error as? AutomationError { diagnosticCode = error.code.rawValue }
                else if error is CancellationError { diagnosticCode = "cancelled" }
                else if let error = error as? HarnessError {
                    switch error {
                    case .identityNotReady: diagnosticCode = "identityNotReady"
                    case .invalidClock: diagnosticCode = "invalidClock"
                    case .deadline: diagnosticCode = "deadline"
                    case .eof: diagnosticCode = "eof"
                    case .invalidMode: diagnosticCode = "invalidMode"
                    case .environment: diagnosticCode = "environment"
                    }
                } else if let error = error as? AutomationRunnerClientStartError {
                    switch error {
                    case .launcherIdentityMismatch: diagnosticCode = "launcherIdentityMismatch"
                    case .cleanupUnconfirmed: diagnosticCode = "cleanupUnconfirmed"
                    }
                } else if let error = error as? IdentityBridgeError {
                    switch error {
                    case .rejected: diagnosticCode = "identityRejected"
                    case .unsupportedParentAuthority: diagnosticCode = "unsupportedParentAuthority"
                    case .collector(let phase, let result):
                        let safePhase: String
                        switch phase {
                        case "metadata", "static", "self", "resource", "peer": safePhase = phase
                        default: safePhase = "other"
                        }
                        let safeResult: String
                        switch result {
                        case 1: safeResult = "invalid"
                        case 2: safeResult = "expired"
                        case 3: safeResult = "io"
                        case 4: safeResult = "changed"
                        default: safeResult = "other"
                        }
                        diagnosticCode = "collector_\(safePhase)_\(safeResult)"
                    }
                } else if let error = error as? RepositoryBindingProvider.Failure {
                    switch error {
                    case .invalidExecutablePath: diagnosticCode = "repository_invalidExecutablePath"
                    case .invalidArguments: diagnosticCode = "repository_invalidArguments"
                    case .directoryChanged: diagnosticCode = "repository_directoryChanged"
                    case .unsafeLock: diagnosticCode = "repository_unsafeLock"
                    case .lockUnavailable: diagnosticCode = "repository_lockUnavailable"
                    case .lockLost: diagnosticCode = "repository_lockLost"
                    case .unsafeRepository: diagnosticCode = "repository_unsafeRepository"
                    case .repositoryTooLarge: diagnosticCode = "repository_repositoryTooLarge"
                    case .snapshotFailed: diagnosticCode = "repository_snapshotFailed"
                    case .repositoryChanged: diagnosticCode = "repository_repositoryChanged"
                    case .decodingFailed: diagnosticCode = "repository_decodingFailed"
                    case .duplicateID: diagnosticCode = "repository_duplicateID"
                    case .missingProfile: diagnosticCode = "repository_missingProfile"
                    case .profileDenied: diagnosticCode = "repository_profileDenied"
                    case .deadline: diagnosticCode = "repository_deadline"
                    case .closed: diagnosticCode = "repository_closed"
                    }
                } else if error is PrivateDirectoryPin.Failure {
                    diagnosticCode = "privateDirectoryInvalid"
                } else { diagnosticCode = "unknown" }
                fputs("BOUND_DIAG phase=\(diagnosticPhase) elapsed_ms=\(diagnosticElapsed) result=\(diagnosticCode)\n", stderr)
                Logger(subsystem: "sh.safarier.testing", category: "bound-start").notice("phase=\(diagnosticPhase, privacy: .public) elapsed_ms=\(diagnosticElapsed, privacy: .public) result=\(diagnosticCode, privacy: .public)")
                #endif
                pair.parent.close(); try? pair.child.close()
                if let context { await context.safeClose() }
                if let retainedOwner {
                    // Detached observation survives cancellation of this start task.
                    // It observes only the originally retained Process, never a PID lookup.
                    let observed = await Task.detached {
                        try? await retainedOwner.waitForExit(timeoutSeconds: AutomationLimits.cleanupSeconds)
                    }.value
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    let now = DispatchTime.now().uptimeNanoseconds
                    let elapsed = now >= start ? (now - start) / 1_000_000 : 0
                    if let observed {
                        fputs("BOUND_DIAG phase=client.owned_exit elapsed_ms=\(elapsed) owned_runner_exit_observed=true status=\(observed.status)\n", stderr)
                    } else {
                        fputs("BOUND_DIAG phase=client.owned_exit elapsed_ms=\(elapsed) owned_runner_exit_observed=false\n", stderr)
                    }
                    #endif
                    guard observed != nil else {
                        throw AutomationRunnerClientStartError.cleanupUnconfirmed(underlying: error)
                    }
                }
                throw error
            }
        }, onCancel: { pair.parent.close() })
    }
    static func startFixture(context: ControllerGenerationContext, startupCutoff: UInt64) async throws -> AutomationRunnerClient {
        do {
            let response = try await AutomationHandshakeCodec.negotiateBound(context: context, startupCutoff: startupCutoff)
            let (owner, profileID, channel) = try await context.clientParameters(for: response)
            let client = AutomationRunnerClient(owner: owner, profileID: profileID, runnerInstanceID: response.runnerInstanceID, channel: channel, context: context)
            let reader = try await context.attachClientOnce(client, response: response)
            await client.startReader(reader)
            try Task.checkCancellation()
            try await context.validateAttachedClient(client, response: response)
            try Task.checkCancellation()
            return client
        } catch { await context.safeClose(); throw error }
    }
    private func startReader(_ reader: AutomationChannel.ReaderLease) {
        let channel = self.channel
        Task.detached { [weak self] in
            do {
                while let data = try await reader.receive() {
                    guard let self else { channel.close(); return }
                    if !(await self.receiveFrame(data)) { return }
                }
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                hoverCoreTrace("client.reader_eof", "eof")
                #endif
                await self?.failConnection(.runnerExited, source: "client.reader_eof")
            } catch {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                hoverCoreTrace("client.reader_catch", "read_error")
                #endif
                await self?.failConnection(.runnerExited, source: "client.reader_catch")
            }
        }
    }
    private func isReserved(_ action: AutomationAction) -> Bool {
        switch action { case .cancel, .closeSession, .releaseControl, .commitControlRelease: return true; default: return false }
    }
    public func request(_ request: AutomationRequest, timeoutSeconds: Double = AutomationLimits.actionSeconds) async throws -> AutomationReply {
        guard Self.validTimeout(timeoutSeconds) else { throw AutomationError(code: .invalidRequest) }
        guard !closed else { throw AutomationError(code: .runnerExited) }
        let reserved = isReserved(request.action)
        // Keep two correlation tombstones for cleanup. At the hard limit the
        // channel is closed: no cleanup or other request can be safely correlated.
        if sentIDs.count >= maxSentIDs { failConnection(.replayWindowFull); throw AutomationError(code: .replayWindowFull) }
        guard pending[request.requestID] == nil, !sentIDs.contains(request.requestID) else { throw AutomationError(code: .requestIDReused) }
        if !reserved && sentIDs.count >= maxSentIDs - 2 { throw AutomationError(code: .replayWindowFull) }
        if case .openSession(let id) = request.action, id != profileID { throw AutomationError(code: .invalidRequest) }
        guard reserved ? reservedCount < maxReserved : ordinaryCount < maxOrdinary else { throw AutomationError(code: .sessionBusy) }
        let start = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = start.addingReportingOverflow(UInt64(timeoutSeconds * 1_000_000_000))
        guard !overflow else { throw AutomationError(code: .invalidRequest) }
        let bytes = try AutomationCodec.encodeRequest(request)
        let flag = CancellationFlag()
        let generation = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AutomationReply, Error>) in
                guard !flag.isCancelled else { continuation.resume(throwing: AutomationError(code: .cancelled)); return }
                let id = request.requestID
                pending[id] = Pending(action: request.action, generation: generation, cancellation: flag, deadline: deadline, bytes: bytes, minting: false, admission: nil, continuation: continuation, reserved: reserved, attempted: false, timer: nil)
                if reserved { reservedCount += 1 } else { ordinaryCount += 1 }
                let timer = Task.detached { [weak self] in
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < deadline {
                        do { try await Task.sleep(nanoseconds: deadline - now) } catch { return }
                    }
                    await self?.failTimedRequest(id, generation: generation, code: .timeout)
                }
                pending[id]?.timer = timer
                outbound.append(Outbound(id: id, generation: generation, bytes: bytes, reserved: reserved))
                pumpWrites()
            }
        }, onCancel: {
            flag.cancel()
            Task { await self.failTimedRequest(request.requestID, generation: generation, code: .cancelled) }
        })
    }
    private func pumpWrites() {
        guard !closed else { return }
        while let index = outbound.firstIndex(where: { $0.reserved && reservedSends < 2 }) ?? outbound.firstIndex(where: { !$0.reserved && ordinarySends < 2 }) {
            let write = outbound.remove(at: index)
            guard pending[write.id]?.generation == write.generation else { continue }
            if write.reserved { reservedSends += 1 } else { ordinarySends += 1 }
            Task.detached { [weak self] in await self?.sendRequest(write) }
        }
    }
    // Concrete context may read the Pending only once and can never supply bytes to it.
    func beginOwnedRequestMint(context: ControllerGenerationContext, id: UUID, generation: UUID) -> (Data, UInt64)? {
        guard context === fixtureContext, !closed, let item = pending[id], item.generation == generation,
              item.attempted, !item.minting, item.admission == nil, !item.cancellation.isCancelled,
              DispatchTime.now().uptimeNanoseconds < item.deadline else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let observed = pending[id]
            let now = DispatchTime.now().uptimeNanoseconds
            hoverCoreTrace("close.client.begin_guard_failure", "contextMatch=\(context === fixtureContext),closed=\(closed),pendingPresent=\(observed != nil),generationMatch=\(observed.map { String($0.generation == generation) } ?? "na"),attempted=\(observed.map { String($0.attempted) } ?? "na"),minting=\(observed.map { String($0.minting) } ?? "na"),admissionNil=\(observed.map { String($0.admission == nil) } ?? "na"),cancelled=\(observed.map { String($0.cancellation.isCancelled) } ?? "na"),deadlineExpired=\(observed.map { String(now >= $0.deadline) } ?? "na")")
            #endif
            return nil
        }
        pending[id]?.minting = true
        return (item.bytes, item.deadline)
    }
    func installOwnedRequestAdmission(context: ControllerGenerationContext, id: UUID, generation: UUID,
                                      admission: SealedWriteAdmission) throws {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        var observedOwnedAdmission: Bool?
        // Called exactly at the original guard location, at most once.
        func originalOwnedCheck() -> Bool {
            let value = admission.isOwnedRequest(context: context, id: id, generation: generation)
            observedOwnedAdmission = value
            return value
        }
        guard context === fixtureContext, !closed, let item = pending[id], item.generation == generation,
              item.minting, item.attempted, item.admission == nil, !item.cancellation.isCancelled,
              DispatchTime.now().uptimeNanoseconds < item.deadline, admission.cutoff <= item.deadline,
              admission.frame == item.bytes, originalOwnedCheck()
        else {
            let observed = pending[id]
            let now = DispatchTime.now().uptimeNanoseconds
            hoverCoreTrace("close.client.install_guard_failure", "contextMatch=\(context === fixtureContext),closed=\(closed),pendingPresent=\(observed != nil),generationMatch=\(observed.map { String($0.generation == generation) } ?? "na"),attempted=\(observed.map { String($0.attempted) } ?? "na"),minting=\(observed.map { String($0.minting) } ?? "na"),admissionNil=\(observed.map { String($0.admission == nil) } ?? "na"),cancelled=\(observed.map { String($0.cancellation.isCancelled) } ?? "na"),deadlineExpired=\(observed.map { String(now >= $0.deadline) } ?? "na"),cutoffWithinPending=\(observed.map { String(admission.cutoff <= $0.deadline) } ?? "na"),frameEqual=\(observed.map { String(admission.frame == $0.bytes) } ?? "na"),ownedAdmission=\(observedOwnedAdmission.map { String($0) } ?? "na")")
            throw ControllerRequestMintUnavailable.noLongerLive
        }
        #else
        guard context === fixtureContext, !closed, let item = pending[id], item.generation == generation,
              item.minting, item.attempted, item.admission == nil, !item.cancellation.isCancelled,
              DispatchTime.now().uptimeNanoseconds < item.deadline, admission.cutoff <= item.deadline,
              admission.frame == item.bytes, admission.isOwnedRequest(context: context, id: id, generation: generation)
        else { throw ControllerRequestMintUnavailable.noLongerLive }
        #endif
        pending[id]?.admission = admission
    }
    func checkQueuedPending(context: ControllerGenerationContext, id: UUID, generation: UUID,
                            admission: SealedWriteAdmission) throws {
        guard context === fixtureContext, !closed, let item = pending[id], item.generation == generation,
              item.attempted, item.admission === admission, !item.cancellation.isCancelled,
              DispatchTime.now().uptimeNanoseconds < item.deadline, admission.cutoff <= item.deadline,
              admission.frame == item.bytes, admission.isOwnedRequest(context: context, id: id, generation: generation) else { throw AutomationError(code: .runnerExited) }
    }
    func inboundPendingDeadline(context: ControllerGenerationContext, id: UUID, generation: UUID,
                                reply: AutomationReply) throws -> UInt64 {
        guard context === fixtureContext, !closed else { throw AutomationError(code: .runnerExited) }
        guard let item = pending[id], item.generation == generation, item.attempted,
              reply.requestID == id, valid(reply, for: item.action),
              let admission = item.admission, admission.isOwnedRequest(context: context, id: id, generation: generation),
              admission.binding.channel === channel, admission.frame == item.bytes,
              admission.cutoff <= item.deadline else { throw AutomationError(code: .invalidRequest) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticNow = DispatchTime.now().uptimeNanoseconds
        let outboundCutoffExpired = diagnosticNow >= admission.cutoff
        let pendingDeadlineExpired = diagnosticNow >= item.deadline
        let pendingRemainingMs = diagnosticNow < item.deadline ? (item.deadline - diagnosticNow) / 1_000_000 : 0
        fputs("INBOUND_DIAG phase=pending_deadline outboundCutoffExpired=\(outboundCutoffExpired) pendingDeadlineExpired=\(pendingDeadlineExpired) pendingRemainingMs=\(pendingRemainingMs)\n", stderr)
        #endif
        if item.cancellation.isCancelled { throw AutomationError(code: .cancelled) }
        if DispatchTime.now().uptimeNanoseconds >= item.deadline { throw AutomationError(code: .timeout) }
        try admission.binding.checkCommit()
        try channel.requireOpen(before: admission.cutoff)
        try admission.binding.checkCommit()
        return item.deadline
    }
    private func sendRequest(_ write: Outbound) async {
        defer {
            if write.reserved { reservedSends -= 1 } else { ordinarySends -= 1 }
            pumpWrites()
        }
        let id = write.id, generation = write.generation
        guard !closed, let item = pending[id], item.generation == generation else { return }
        if item.cancellation.isCancelled { finishFailure(id, code: .cancelled, definitelyUnsent: true); return }
        if DispatchTime.now().uptimeNanoseconds >= item.deadline { finishFailure(id, code: .timeout, definitelyUnsent: true); return }
        // Preserve the actual client's original attempt boundary: all new async
        // mint/validation work is part of the send attempt, not pre-attempt wait.
        if sentIDs.count >= maxSentIDs { failConnection(.replayWindowFull); return }
        if !write.reserved && sentIDs.count >= maxSentIDs - 2 { finishFailure(id, code: .replayWindowFull, definitelyUnsent: true); return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let hoverIsMove: Bool
        if case .move = item.action { hoverIsMove = true; hoverCoreTrace("client.move_attempt_before") }
        else { hoverIsMove = false }
        let closeIsReducing: Bool
        switch item.action { case .closeSession, .cancel, .releaseControl, .commitControlRelease: closeIsReducing = true; default: closeIsReducing = false }
        #endif
        sentIDs.insert(id)
        pending[id]?.attempted = true
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if hoverIsMove { hoverCoreTrace("client.move_attempt_after") }
        #endif
        let admission: SealedWriteAdmission
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if closeIsReducing { hoverCoreTrace("close.client.mint_before") }
        #endif
        do {
            guard let minted = try await fixtureContext.mintOwnedRequest(client: self, id: id, generation: generation) else {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                if closeIsReducing { hoverCoreTrace("close.client.mint_nil", "no_longer_live") }
                #endif
                guard let live = pending[id], live.generation == generation, live.attempted else { return }
                if live.cancellation.isCancelled { failConnection(.cancelled) }
                else if DispatchTime.now().uptimeNanoseconds >= live.deadline { failConnection(.timeout) }
                else { failConnection(.runnerExited) }
                return
            }
            admission = minted
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if closeIsReducing { hoverCoreTrace("close.client.mint_after") }
            #endif
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if closeIsReducing { hoverCoreTrace("close.client.mint_catch", (error as? AutomationError)?.code.rawValue ?? (error is CancellationError ? "cancelled" : "unknown")) }
            if hoverIsMove { hoverCoreTrace("client.move_mint_failure", "mint_error") }
            #endif
            guard let live = pending[id], live.generation == generation, live.attempted else { return }
            if live.cancellation.isCancelled { failConnection(.cancelled) }
            else if DispatchTime.now().uptimeNanoseconds >= live.deadline { failConnection(.timeout) }
            else { failConnection(.runnerExited) }
            return
        }
        guard !closed, let live = pending[id], live.generation == generation, live.attempted, live.admission === admission else { return }
        if live.cancellation.isCancelled { failConnection(.cancelled); return }
        if DispatchTime.now().uptimeNanoseconds >= live.deadline { failConnection(.timeout); return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if closeIsReducing { hoverCoreTrace("close.client.arm_before") }
        #endif
        do {
            try await fixtureContext.armOwnedRequest(client: self, id: id, generation: generation, admission: admission)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if closeIsReducing { hoverCoreTrace("close.client.arm_after") }
            #endif
        }
        catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if closeIsReducing { hoverCoreTrace("close.client.arm_catch", (error as? AutomationError)?.code.rawValue ?? (error is CancellationError ? "cancelled" : "unknown")) }
            if hoverIsMove { hoverCoreTrace("client.move_arm_failure", "arm_error") }
            #endif
            failPendingAfterAwait(id, generation: generation, fallback: .runnerExited); return
        }
        guard !closed, let attempted = pending[id], attempted.generation == generation,
              attempted.attempted, attempted.admission === admission else { return }
        if attempted.cancellation.isCancelled { failConnection(.cancelled); return }
        if DispatchTime.now().uptimeNanoseconds >= attempted.deadline { failConnection(.timeout); return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if hoverIsMove { hoverCoreTrace("client.move_send_before") }
        if closeIsReducing { hoverCoreTrace("close.client.send_before") }
        #endif
        do {
            try await channel.sendBound(admission)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if hoverIsMove { hoverCoreTrace("client.move_send_after") }
            if closeIsReducing { hoverCoreTrace("close.client.send_after") }
            #endif
        }
        catch AutomationChannel.ChannelError.sendBackpressure {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if hoverIsMove { hoverCoreTrace("client.move_send_failure", "backpressure") }
            if closeIsReducing { hoverCoreTrace("close.client.send_catch", "backpressure") }
            #endif
            if let live = pending[id], live.generation == generation {
                if live.cancellation.isCancelled || DispatchTime.now().uptimeNanoseconds >= live.deadline {
                    failPendingAfterAwait(id, generation: generation, fallback: .runnerExited); return
                }
                do {
                    guard !closed, live.attempted, live.admission === admission else { throw AutomationChannel.ChannelError.closed }
                    try fixtureContext.checkBackpressureHealth(admission, id: id, generation: generation)
                    if live.cancellation.isCancelled || DispatchTime.now().uptimeNanoseconds >= live.deadline {
                        failPendingAfterAwait(id, generation: generation, fallback: .runnerExited); return
                    }
                    sentIDs.remove(id)
                    finishFailure(id, code: .sessionBusy, definitelyUnsent: true)
                } catch { failPendingAfterAwait(id, generation: generation, fallback: .runnerExited) }
            }
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if hoverIsMove { hoverCoreTrace("client.move_send_failure", "send_error") }
            if closeIsReducing { hoverCoreTrace("close.client.send_catch", "send_error") }
            #endif
            failPendingAfterAwait(id, generation: generation, fallback: .runnerExited)
        }
    }
    private func receiveFrame(_ data: Data) async -> Bool {
        guard !closed else { return false }
        let reply: AutomationReply
        do { reply = try AutomationCodec.decodeReply(data) }
        catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let code: String
            if let error = error as? AutomationError { code = error.code.rawValue }
            else if let error = error as? AutomationChannel.ChannelError, case .closed = error { code = "channel_closed" }
            else { code = "unknown" }
            fputs("INBOUND_DIAG phase=receive.decode code=\(code)\n", stderr)
            #endif
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            hoverCoreTrace("client.reply_decode_failure", "invalid_request")
            #endif
            failConnection(.invalidRequest, source: "client.reply_decode_failure"); return false
        }
        var correlated: (UUID, UUID)?
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        var diagnosticPhase = "receive.correlate"
        #endif
        do {
            guard let id = reply.requestID, let generation = pending[id]?.generation else { throw AutomationError(code: .invalidRequest) }
            correlated = (id, generation)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if let item = pending[id], case .move = item.action { hoverCoreTrace("client.move_reply_received") }
            diagnosticPhase = "receive.pending_before"
            #endif
            _ = try inboundPendingDeadline(context: fixtureContext, id: id, generation: generation, reply: reply)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "receive.validate"
            #endif
            try await fixtureContext.validateInbound(client: self, id: id, generation: generation, reply: reply)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "receive.pending_after"
            #endif
            _ = try inboundPendingDeadline(context: fixtureContext, id: id, generation: generation, reply: reply)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "receive.remove_pending"
            #endif
            guard let item = pending[id], item.generation == generation else { throw AutomationError(code: .invalidRequest) }
            if case .success(let result) = reply.outcome {
                switch (item.action, result) {
                case (.openSession, .sessionOpened(_, let target, _)): boundTarget = target
                case (.releaseControl, .controlReleasePrepared(let value)):
                    guard value.target == boundTarget, value.inputReleased, value.artifactsCleaned, value.browserRetained else { throw AutomationError(code: .invalidRequest) }
                    releasePreparation = value
                case (.commitControlRelease(let transferID), .controlReleased(let value)):
                    guard let prepared = releasePreparation, prepared.target == boundTarget,
                          prepared.transferID == transferID, value.target == prepared.target,
                          value.transferID == transferID, value.inputReleased, value.artifactsCleaned,
                          value.browserRetained, value.manualInteractionEnabled else { throw AutomationError(code: .invalidRequest) }
                    validatedRelease = value
                default: break
                }
            }
            guard removePending(id) != nil else { throw AutomationError(code: .invalidRequest) }
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if case .move = item.action {
                if case .failure(let error) = reply.outcome { hoverCoreTrace("client.move_reply_delivered", error.code.rawValue) }
                else { hoverCoreTrace("client.move_reply_delivered") }
            }
            #endif
            item.continuation.resume(returning: reply)
            return true
        } catch let error as AutomationError {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            fputs("INBOUND_DIAG phase=\(diagnosticPhase) code=\(error.code.rawValue)\n", stderr)
            hoverCoreTrace("client.reply_failure", error.code.rawValue)
            #endif
            if let (id, generation) = correlated { failCorrelatedReceiveAfterAwait(id, generation: generation, fallback: error.code) }
            else { failConnection(error.code) }
            return false
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let code: String
            if let error = error as? AutomationChannel.ChannelError, case .closed = error { code = "channel_closed" }
            else { code = "unknown" }
            fputs("INBOUND_DIAG phase=\(diagnosticPhase) code=\(code)\n", stderr)
            hoverCoreTrace("client.reply_failure", code)
            #endif
            if let (id, generation) = correlated { failCorrelatedReceiveAfterAwait(id, generation: generation, fallback: .runnerExited) }
            else { failConnection(.runnerExited) }
            return false
        }
    }
    private func failCorrelatedReceiveAfterAwait(_ id: UUID, generation: UUID, fallback: AutomationErrorCode) {
        guard !closed else { return }
        guard let item = pending[id], item.generation == generation else {
            // A live connection with an unknown/stale reply cannot keep running
            // after its one reader loop exits, nor revive another generation.
            failConnection(.invalidRequest); return
        }
        failPendingAfterAwait(id, generation: generation, fallback: fallback)
    }
    // Reuses the original Pending flags/deadline and failure machinery; it is
    // not an independent error record or authorization source.
    private func failPendingAfterAwait(_ id: UUID, generation: UUID, fallback: AutomationErrorCode) {
        guard let item = pending[id], item.generation == generation else { return }
        if fallback == .invalidRequest { failConnection(.invalidRequest); return }
        if item.cancellation.isCancelled { failTimedRequest(id, generation: generation, code: .cancelled) }
        else if DispatchTime.now().uptimeNanoseconds >= item.deadline { failTimedRequest(id, generation: generation, code: .timeout) }
        else { failConnection(fallback) }
    }
    private func removePending(_ id: UUID) -> Pending? {
        guard let item = pending.removeValue(forKey: id) else { return nil }
        item.timer?.cancel()
        // Also settle this request's exact bound writer timer. The send task's
        // own deferred settlement remains idempotent if it resumes later.
        item.admission?.finishDeadline()
        outbound.removeAll { $0.id == id && $0.generation == item.generation }
        if item.reserved { reservedCount -= 1 } else { ordinaryCount -= 1 }
        return item
    }
    private func failure(for item: Pending, code: AutomationErrorCode, definitelyUnsent: Bool = false) -> AutomationError {
        if item.attempted && !definitelyUnsent {
            switch item.action {
            case .capabilities, .getState: break
            default: return AutomationError(code: .indeterminateResult, sideEffects: .possible)
            }
        }
        return AutomationError(code: code)
    }
    private func finishFailure(_ id: UUID, code: AutomationErrorCode, definitelyUnsent: Bool = false) {
        guard let item = removePending(id) else { return }
        item.continuation.resume(throwing: failure(for: item, code: code, definitelyUnsent: definitelyUnsent))
    }
    private func failTimedRequest(_ id: UUID, generation: UUID, code: AutomationErrorCode) {
        guard let item = pending[id], item.generation == generation else { return }
        if item.attempted { failConnection(code, source: "client.timer_or_cancel") } else { finishFailure(id, code: code) }
    }
    private func failConnection(_ code: AutomationErrorCode, source: String = #function) {
        guard !closed else { return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        fputs("INBOUND_DIAG phase=fail_connection code=\(code.rawValue)\n", stderr)
        hoverCoreTrace("client.fail_connection." + source, code.rawValue)
        #endif
        closed = true
        let context = fixtureContext
        context.stopFromClient(code)
        channel.close()
        Task { await context.safeClose() }
        outbound.removeAll()
        for id in Array(pending.keys) {
            guard let item = pending[id] else { continue }
            // A synchronous channel close may wake the reader before an already
            // expired/cancelled request's original timer/cancellation actor job.
            // Preserve that very Pending's original result; never relabel a
            // schema/codec invalidRequest or invent a separate error record.
            let effective: AutomationErrorCode
            if code == .runnerExited && item.cancellation.isCancelled { effective = .cancelled }
            else if code == .runnerExited && DispatchTime.now().uptimeNanoseconds >= item.deadline { effective = .timeout }
            else { effective = code }
            finishFailure(id, code: effective)
        }
    }
    private func valid(_ reply: AutomationReply, for action: AutomationAction) -> Bool {
        guard case .success(let result) = reply.outcome else { return true }
        func matches(_ target: AutomationTargetIdentity) -> Bool {
            target.profileID == profileID && target.runnerInstanceID == runnerInstanceID
        }
        switch (action, result) {
        case (.capabilities, .capabilities(let c)): return c.role == "runner"
        case (.openSession, .sessionOpened(_, let target, _)): return matches(target)
        case (.getState, .stateRead(let state)): return matches(state.target)
        case (.navigate, .navigationFinished), (.navigateByInput, .navigationFinished), (.screenshot, .snapshotWritten): return true
        case (.move, .nativeDelivered), (.mouseDown, .nativeDelivered), (.mouseUp, .nativeDelivered), (.click, .nativeDelivered), (.scroll, .nativeDelivered), (.insertText, .nativeDelivered), (.key, .nativeDelivered): return true
        case (.cancel, .sessionClosed), (.closeSession, .sessionClosed): return true
        case (.releaseControl, .controlReleasePrepared(let value)): return matches(value.target)
        case (.commitControlRelease(let id), .controlReleased(let value)): return matches(value.target) && value.transferID == id
        default: return false
        }
    }
    public func close() { failConnection(.runnerExited) }
    /// Transfers only the exact child held by this client after its authenticated commit reply.
    // Keep distinct from the App async protocol default: same-name overloads recurse into that default.
    public func takeValidatedReleasedOwner(matching receipt: ControlReleaseReceipt) throws -> OwnedRunnerProcess {
        guard !closed, !releasedOwnerTaken, pending.isEmpty, validatedRelease == receipt,
              receipt.target == boundTarget, owner.isRunning else { throw AutomationError(code: .indeterminateResult, sideEffects: .possible) }
        releasedOwnerTaken = true; validatedRelease = nil; closed = true
        channel.close()
        let context = fixtureContext
        context.stopFromClient(.cancelled)
        Task { await context.safeClose() }
        return owner
    }
    public func closeAndWait(timeoutSeconds: Double = AutomationLimits.cleanupSeconds) async throws -> ProcessExit? {
        guard Self.validTimeout(timeoutSeconds) else { throw AutomationError(code: .invalidRequest) }
        close()
        return try await owner.waitForExit(timeoutSeconds: timeoutSeconds)
    }
}
