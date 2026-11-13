import Foundation
import SafarierCore
import Darwin
#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
#endif

/// Owns routing to private Runner channels. Shipping admission remains closed.
@MainActor final class AutomationManager {
    typealias ProfileReader = @Sendable (UUID) async throws -> Profile?
    typealias HumanRunning = @Sendable (UUID) async -> Bool
    typealias RunnerFactory = @Sendable (Profile) async throws -> any AutomationManagerEndpoint
    typealias Admission = @Sendable () -> Bool
    typealias Clock = @Sendable () -> Double
    typealias Sleeper = @Sendable (Double) async throws -> Void

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class Completion<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var continuation: CheckedContinuation<T, Error>?
        func install(_ c: CheckedContinuation<T, Error>) {
            lock.lock()
            if let result { lock.unlock(); c.resume(with: result) }
            else { continuation = c; lock.unlock() }
        }
        @discardableResult func claim(_ value: Result<T, Error>, onClaim: () -> Void = {}) -> Bool {
            lock.lock()
            guard result == nil else { lock.unlock(); return false }
            result = value; onClaim(); let c = continuation; continuation = nil
            lock.unlock(); c?.resume(with: value); return true
        }
    }
    private enum Phase { case opening, active, releasing, closing, closed, released }
    private final class Entry {
        let request: AutomationRequest
        let caller: AutomationScriptCallerProof
        let profileID: UUID
        var phase: Phase = .opening
        var endpoint: (any AutomationManagerEndpoint)?
        var token: String?
        var target: AutomationTargetIdentity?
        var replay: AutomationReplayCache
        var openReply: AutomationReply?
        var closeReceipt: CleanupReceipt?
        var closeTask: Task<CleanupReceipt, Never>?
        var releaseRequest: AutomationRequest?
        var releaseReply: AutomationReply?
        var releaseWorkerRunning = false
        var closeRequests: [UUID: AutomationRequest] = [:]
        // Correlation-only tombstones preserve cross-action conflicts when the
        // replay cache is full or expired; entries are never evicted to reexecute.
        var ordinaryIDs: Set<UUID> = []
        var identity: (pid: Int32, instance: UUID, ownership: UUID)?
        var registeredInteractive = false
        var leaseDeadline: Double = 0
        var leaseGeneration = UUID()
        var leaseTimer: Task<Void, Never>?
        var openWorkerRunning = false
        var closeWorkerRunning = false
        var cancellers: [UUID: (flag: CancellationFlag, cancel: () -> Void)] = [:]
        init(_ request: AutomationRequest, _ caller: AutomationScriptCallerProof, _ profileID: UUID, now: Double) {
            self.request = request; self.caller = caller; self.profileID = profileID
            self.replay = AutomationReplayCache(startedAt: now)
        }
    }
    private let profileReader: ProfileReader
    private let humanRunning: HumanRunning
    private let runnerFactory: RunnerFactory
    private let admission: Admission
    private let clock: Clock
    private var lastClock: Double?
    private var clockFault = false
    private let sleepUntil: Sleeper
    private var opens: [UUID: Entry] = [:]
    private var sessions: [String: Entry] = [:]
    private var retainedRunners: [UUID: OwnedRunnerProcess] = [:]
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var registeredRegistry: RegisteredRunnerRegistry?
    private var registeredConnector: (@MainActor (Profile) async throws -> any AutomationManagerEndpoint)?
    private var interactiveLaunches: [UUID: (request: AutomationRequest, caller: AutomationScriptCallerProof, reply: AutomationReply?)] = [:]
    #endif
    #if SAFARIER_MANAGER_ROUTING_TESTS
    // Explicit test-build seam for orchestration fakes, never compiled into apps.
    var injectedOwnedRegistrationProof: (() -> Bool)?
    #endif
    private var stopped = false
    private var outstandingWorkers = 0
    var onPendingWorkChanged: (() -> Void)?
    var pendingWorkCount: Int { opens.values.filter { $0.phase != .closed && $0.phase != .released }.count }

    init(profileReader: @escaping ProfileReader, humanRunning: @escaping HumanRunning,
         runnerFactory: @escaping RunnerFactory, admission: @escaping Admission,
         now: @escaping Clock, sleepUntil: @escaping Sleeper) {
        self.profileReader = profileReader; self.humanRunning = humanRunning
        self.runnerFactory = runnerFactory; self.admission = admission
        self.clock = now; self.sleepUntil = sleepUntil
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    // Do not accept an endpoint-provided proof. Only the two concrete owned
    // implementations can expose the original authenticated Core client.
    private static func concreteOwnedClient(_ endpoint: any AutomationManagerEndpoint) -> AutomationRunnerClient? {
        if let client = endpoint as? AutomationRunnerClient { return client }
        return (endpoint as? RegisteredManagerEndpoint)?.client
    }
    #endif

    private nonisolated static let coldLaunchVerified = false
    deinit {
        // Losing the owner must not leave an owned channel open. Never inspect or
        // signal a process; the retained endpoint is the only cleanup capability.
        for entry in opens.values where entry.closeTask == nil && entry.phase != .released {
            guard let endpoint = entry.endpoint, let identity = entry.identity,
                  endpoint.pid == identity.pid, endpoint.runnerInstanceID == identity.instance,
                  endpoint.ownershipID == identity.ownership else { continue }
            Task {
                guard endpoint.pid == identity.pid, endpoint.runnerInstanceID == identity.instance, endpoint.ownershipID == identity.ownership else { return }
                _ = try? await endpoint.closeAndWait(timeoutSeconds: AutomationLimits.cleanupSeconds)
            }
        }
    }
    private nonisolated static var candidateRouteAvailable: Bool {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        return true // Routing only; Core authenticates the actual peer and lease.
        #else
        return false
        #endif
    }
    static func shipping(workspace: SafarierWorkspace) -> AutomationManager {
        let manager = AutomationManager(profileReader: { try workspace.profiles.record(id: $0) },
            humanRunning: { workspace.isRunning($0) },
            runnerFactory: { profile in
                try await AutomationRunnerClient.start(profile: profile, workspace: workspace, launcher: RunnerLauncher(logDirectory: workspace.logsDirectory))
            }, admission: { candidateRouteAvailable || (NativeInputPreflight.shippingAdmissionAvailable && coldLaunchVerified) },
            now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            })
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let registry = RegisteredRunnerRegistry(workspace: workspace)
        manager.registeredRegistry = registry
        manager.registeredConnector = { profile in
            if !registry.contains(profile.id) {
                guard !workspace.isRunning(profile.id) else { throw AutomationError(code: .profileAlreadyRunning) }
                try registry.launch(profile, launcher: RunnerLauncher(logDirectory: workspace.logsDirectory), initialBlank: true)
            }
            return try await registry.open(profile)
        }
        #endif
        return manager
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func launchRegisteredInteractive(_ profile: Profile, spawner: FoundationProcessSpawner, workspace: SafarierWorkspace) throws {
        guard let registeredRegistry else { throw AutomationError(code: .backendUnavailable) }
        try registeredRegistry.launch(profile, launcher: RunnerLauncher(spawner: spawner, logDirectory: workspace.logsDirectory))
    }
    func setRegisteredConnector(_ connector: @escaping @MainActor (Profile) async throws -> any AutomationManagerEndpoint) {
        registeredConnector = connector
    }
    #endif
    private func now() -> Double {
        guard !clockFault else { return .nan }
        let value = clock()
        guard value.isFinite, lastClock.map({ value >= $0 }) ?? true else {
            clockFault = true
            Task { [weak self] in
                guard let self else { return }
                for entry in self.opens.values where entry.phase != .closed && entry.phase != .released { self.startClose(entry) }
            }
            return .nan
        }
        lastClock = value
        return value
    }
    private func failure(_ request: AutomationRequest, _ code: AutomationErrorCode) -> AutomationReply {
        AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: code)))
    }
    private func changed() { onPendingWorkChanged?() }
    /// The worker remains counted until it actually returns, even if its caller times out.
    private func runUntil<T>(deadline: Double, flag: CancellationFlag, owner: Entry? = nil, cleanup: Bool = false, work: @escaping @MainActor () async throws -> T, onReturn: @escaping @MainActor () -> Void = {}) async throws -> T {
        let startedAt = now()
        guard cleanup || (deadline.isFinite && startedAt.isFinite && startedAt < deadline) else { throw AutomationError(code: .timeout) }
        guard outstandingWorkers < (cleanup ? AutomationLimits.replayEntries : AutomationLimits.replayEntries - 8) else { throw AutomationError(code: .sessionBusy) }
        outstandingWorkers += 1
        let completion = Completion<T>(), operationID = UUID()
        owner?.cancellers[operationID] = (flag, { completion.claim(.failure(AutomationError(code: .cancelled)), onClaim: { flag.cancel() }) })
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let clock = self.clock, sleeper = self.sleepUntil
                let timer = Task {
                    guard deadline.isFinite, startedAt.isFinite else {
                        completion.claim(.failure(AutomationError(code: .timeout)), onClaim: { flag.cancel() }); return
                    }
                    do {
                        try await sleeper(deadline)
                        guard !Task.isCancelled else { return }
                        // A return is a deadline event. Early, non-finite or backward
                        // observations fail closed rather than spinning or extending it.
                        let end = clock()
                        if !end.isFinite || end < startedAt || end < deadline {
                            completion.claim(.failure(AutomationError(code: .timeout)), onClaim: { flag.cancel() }); return
                        }
                        completion.claim(.failure(AutomationError(code: .timeout)), onClaim: { flag.cancel() })
                    } catch {
                        if !Task.isCancelled { completion.claim(.failure(AutomationError(code: .timeout)), onClaim: { flag.cancel() }) }
                    }
                }
                Task { [weak self] in
                    let result: Result<T, Error>
                    do {
                        if !cleanup && flag.cancelled { throw AutomationError(code: .cancelled) }
                        result = .success(try await work())
                    } catch { result = .failure(error) }
                    timer.cancel()
                    let finishedAt = self?.now() ?? .nan
                    if !finishedAt.isFinite || !startedAt.isFinite || finishedAt < startedAt || !deadline.isFinite || finishedAt >= deadline {
                        completion.claim(.failure(AutomationError(code: .timeout)), onClaim: { flag.cancel() })
                    } else { completion.claim(result) }
                    self?.outstandingWorkers -= 1
                    owner?.cancellers.removeValue(forKey: operationID)
                    onReturn()
                }
            }
        }, onCancel: {
            completion.claim(.failure(AutomationError(code: .cancelled)), onClaim: { flag.cancel() })
        })
    }
    private func identityMatches(_ entry: Entry, _ endpoint: any AutomationManagerEndpoint) -> Bool {
        guard let identity = entry.identity else { return false }
        return endpoint.pid == identity.pid && endpoint.runnerInstanceID == identity.instance && endpoint.ownershipID == identity.ownership
    }
    private func armLease(_ entry: Entry, since forwardedAt: Double? = nil) {
        let startedAt = now()
        let deadline = (forwardedAt ?? startedAt) + AutomationLimits.idleSeconds
        guard startedAt.isFinite, deadline.isFinite, startedAt < deadline else { startClose(entry); return }
        entry.leaseDeadline = deadline
        // Reserve the existing cleanup budget before either independent cutoff.
        let lifetime = entry.registeredInteractive ? entry.endpoint?.absoluteLifetimeDeadline : nil
        let automaticAt = lifetime.map { min(deadline, $0) - AutomationLimits.cleanupSeconds - 1 }
        let scheduled = automaticAt.flatMap { $0.isFinite ? $0 : nil }.map { min(deadline, $0) } ?? deadline
        let generation = UUID(); entry.leaseGeneration = generation
        entry.leaseTimer?.cancel()
        let clock = self.clock, sleeper = self.sleepUntil
        entry.leaseTimer = Task { [weak self, weak entry] in
            do { try await sleeper(scheduled) } catch { if Task.isCancelled { return } }
            guard !Task.isCancelled else { return }
            _ = clock()
            guard let self, let entry, entry.phase == .active, entry.leaseGeneration == generation else { return }
            // Success, early return, throw, and invalid clocks all close the lease.
            let instant = self.now()
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if let lifetime, instant.isFinite, instant < min(deadline, lifetime) {
                NavigationDiagnostic.emit(entry.request, "manager.lease.budget.available")
            } else {
                NavigationDiagnostic.emit(entry.request, "manager.lease.budget.unavailable")
            }
            #endif
            if let lifetime, let automaticAt, instant.isFinite, instant >= automaticAt,
               instant < min(deadline, lifetime), let token = entry.token,
               self.sessions[token] === entry, let endpoint = entry.endpoint,
               self.identityMatches(entry, endpoint) {
                let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
                if entry.closeRequests.count < AutomationLimits.replayEntries,
                   self.opens[request.requestID] == nil, !entry.ordinaryIDs.contains(request.requestID),
                   entry.closeRequests[request.requestID] == nil, entry.releaseRequest?.requestID != request.requestID {
                    entry.closeRequests[request.requestID] = request
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    NavigationDiagnostic.emit(entry.request, "manager.lease.proof.requested")
                    #endif
                    self.startClose(entry, proofRequest: request, proofDeadline: min(deadline, lifetime))
                } else {
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    NavigationDiagnostic.emit(entry.request, "manager.lease.proof.skipped")
                    #endif
                    self.startClose(entry)
                }
            } else {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                NavigationDiagnostic.emit(entry.request, "manager.lease.proof.skipped")
                #endif
                self.startClose(entry)
            }
        }
    }
    private func matches(_ reply: AutomationReply, action: AutomationAction, target: AutomationTargetIdentity?) -> Bool {
        guard case .success(let result) = reply.outcome else { return true }
        switch (action, result) {
        case (.getState, .stateRead(let state)): return state.target == target
        case (.navigate, .navigationFinished), (.navigateByInput, .navigationFinished), (.screenshot, .snapshotWritten),
             (.move, .nativeDelivered), (.mouseDown, .nativeDelivered), (.mouseUp, .nativeDelivered),
             (.click, .nativeDelivered), (.scroll, .nativeDelivered), (.insertText, .nativeDelivered),
             (.key, .nativeDelivered): return true
        default: return false
        }
    }
    private func sameRequest(_ a: AutomationRequest, _ b: AutomationRequest) -> Bool {
        guard let lhs = try? AutomationCodec.encodeRequest(a), let rhs = try? AutomationCodec.encodeRequest(b) else { return false }
        return lhs == rhs
    }
    private func pruneRetainedRunners() {
        retainedRunners = retainedRunners.filter { $0.value.observedExit == nil }
    }
    private func release(_ request: AutomationRequest, entry: Entry) async -> AutomationReply {
        if let prior = entry.releaseRequest {
            guard prior.requestID == request.requestID, sameRequest(prior, request) else {
                return failure(request, prior.requestID == request.requestID ? .requestIDReused : .sessionBusy)
            }
            return entry.releaseReply ?? failure(request, .sessionBusy)
        }
        pruneRetainedRunners()
        guard retainedRunners.count + opens.values.filter({ $0.releaseWorkerRunning }).count < AutomationLimits.replayEntries else { return failure(request, .replayWindowFull) }
        guard entry.phase == .active, entry.cancellers.isEmpty, let token = entry.token,
              request.sessionID == token, let target = entry.target,
              let endpoint = entry.endpoint,
              identityMatches(entry, endpoint), target.profileID == entry.profileID,
              target.runnerInstanceID == endpoint.runnerInstanceID else { return failure(request, .sessionBusy) }
        let start = now(), deadline = min(start + AutomationLimits.actionSeconds, entry.leaseDeadline)
        guard start.isFinite, deadline.isFinite, start < deadline else { startClose(entry); return failure(request, .sessionExpired) }
        if entry.closeRequests[request.requestID] != nil { return failure(request, .requestIDReused) }
        switch entry.replay.begin(request, at: start) {
        case .replay(let reply): return reply
        case .inFlight: return failure(request, .sessionBusy)
        case .rejected(let code): return failure(request, code)
        case .reserved: entry.ordinaryIDs.insert(request.requestID)
        }
        entry.releaseRequest = request; entry.phase = .releasing
        entry.releaseWorkerRunning = true
        entry.leaseTimer?.cancel(); entry.leaseTimer = nil
        let flag = CancellationFlag(), sent = CancellationFlag()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticPhase = "start"
        func traceRelease(_ phase: String, relatedRequestID: UUID? = nil, result: String = "ok") {
            diagnosticPhase = phase
            let instant = DispatchTime.now().uptimeNanoseconds
            let elapsed = instant >= diagnosticStart ? (instant - diagnosticStart) / 1_000_000 : 0
            fputs("RELEASE_DIAG phase=\(phase) elapsed_ms=\(elapsed) monotonic_ms=\(instant / 1_000_000)\n", stderr)
            ReleaseDiagnostic.emit(request, phase: "manager." + phase,
                                   remainingSeconds: max(0, deadline - now()),
                                   relatedRequestID: relatedRequestID, result: result)
        }
        #endif
        func valid() -> Bool {
            !flag.cancelled && entry.phase == .releasing && !stopped && admission() && now() < deadline &&
            sessions[token] === entry && entry.token == token && entry.target == target && identityMatches(entry, endpoint)
        }
        do {
            let result = try await runUntil(deadline: deadline, flag: flag, owner: entry, work: { [self] in
                guard valid(), let profile = try await profileReader(entry.profileID), profile.id == entry.profileID,
                      valid() else { throw AutomationError(code: .profileNotAllowed) }
                let remaining = deadline - now()
                guard remaining > 0 else { throw AutomationError(code: .timeout) }
                sent.cancel()
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                traceRelease("prepare.before")
                #endif
                let preparedReply = try await endpoint.request(request, timeoutSeconds: remaining)
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                traceRelease("prepare.after")
                #endif
                guard valid(), preparedReply.requestID == request.requestID,
                      (try? AutomationCodec.decodeReply(AutomationCodec.encode(preparedReply))) == preparedReply,
                      case .success(.controlReleasePrepared(let preparation)) = preparedReply.outcome,
                      preparation.target == target, preparation.inputReleased, preparation.artifactsCleaned,
                      preparation.browserRetained else { throw AutomationError(code: .indeterminateResult, sideEffects: .possible) }
                let commit = AutomationRequest(version: 1, requestID: UUID(), sessionID: token,
                                               action: .commitControlRelease(transferID: preparation.transferID))
                NavigationDiagnostic.releaseChild(parent: request.requestID, child: commit.requestID)
                let commitRemaining = deadline - now()
                guard valid(), commitRemaining > 0 else { throw AutomationError(code: .timeout) }
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                traceRelease("commit.before", relatedRequestID: commit.requestID)
                #endif
                let commitReply = try await endpoint.request(commit, timeoutSeconds: commitRemaining)
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                traceRelease("commit.after", relatedRequestID: commit.requestID)
                #endif
                guard valid(), commitReply.requestID == commit.requestID,
                      (try? AutomationCodec.decodeReply(AutomationCodec.encode(commitReply))) == commitReply,
                      case .success(.controlReleased(let receipt)) = commitReply.outcome,
                      receipt.target == target, receipt.transferID == preparation.transferID,
                      receipt.inputReleased, receipt.artifactsCleaned, receipt.browserRetained,
                      receipt.manualInteractionEnabled else { throw AutomationError(code: .indeterminateResult, sideEffects: .possible) }
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                traceRelease("takeOwner.before", relatedRequestID: commit.requestID)
                #endif
                let owner = try await endpoint.takeReleasedOwner(matching: receipt)
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                traceRelease("takeOwner.after", relatedRequestID: commit.requestID)
                #endif
                let withinDeadline = valid() && owner.pid == endpoint.pid && owner.ownershipID == endpoint.ownershipID
                // The exact owner has already been taken even if timeout/cancellation won meanwhile.
                if !endpoint.registeredInteractive { retainedRunners[owner.ownershipID] = owner }
                entry.endpoint = nil; entry.phase = .released; changed()
                guard withinDeadline else { throw AutomationError(code: .indeterminateResult, sideEffects: .possible) }
                let reply = AutomationReply(requestID: request.requestID, outcome: .success(.controlReleased(receipt)))
                guard entry.replay.complete(request, reply: reply, at: now()) else { throw AutomationError(code: .indeterminateResult, sideEffects: .possible) }
                return reply
            }, onReturn: { entry.releaseWorkerRunning = false })
            entry.releaseReply = result
            return result
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            traceRelease("failed.after." + diagnosticPhase, result: (error as? AutomationError)?.code.rawValue ?? "unknown")
            #endif
            if !entry.cancellers.values.contains(where: { $0.flag === flag }) { entry.releaseWorkerRunning = false }
            if entry.phase != .released { startClose(entry, excluding: flag) }
            let code: AutomationErrorCode = sent.cancelled ? .indeterminateResult : ((error as? AutomationError)?.code ?? .cancelled)
            let reply = AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: code, sideEffects: sent.cancelled ? .possible : .none)))
            entry.releaseReply = reply
            return reply
        }
    }
    func handle(_ request: AutomationRequest, role: ExecutableRole,
                proof: AutomationScriptCallerProof?, currentUID: uid_t) async -> AutomationReply {
        guard let caller = proof, caller.isAuthorized(role: role, currentUID: currentUID) else { return failure(request, .unauthorized) }
        if case .capabilities = request.action {
            let reply = await AutomationScriptService.handle(request, role: role, proof: proof, currentUID: currentUID)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if case .success(.capabilities) = reply.outcome {
                let caps = AutomationCapabilities(backend: .unverified, uiPolicy: .unverified, coldLaunch: .unverified,
                                                  version: "1-bound-local-candidate", role: "manager", managerPID: Int(getpid()))
                return AutomationReply(requestID: request.requestID, outcome: .success(.capabilities(caps)))
            }
            #endif
            return reply
        }
        guard admission() else { return failure(request, .backgroundLaunchUnverified) }
        guard !stopped else { return failure(request, .cancelled) }
        guard (try? AutomationCodec.decode(AutomationCodec.encodeRequest(request))) != nil else { return failure(request, .invalidRequest) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if case let .launchInteractive(profileID, url, spi) = request.action {
            guard request.sessionID == nil, let registry = registeredRegistry else { return failure(request, .invalidRequest) }
            guard let profile = try? await profileReader(profileID), profile.id == profileID, profile.allowsAgentAccess else { return failure(request, .profileNotAllowed) }
            if let previous = interactiveLaunches[request.requestID] {
                guard previous.caller.sameCaller(as: caller), sameRequest(previous.request, request) else { return failure(request, .requestIDReused) }
                return previous.reply ?? failure(request, .sessionBusy)
            }
            guard interactiveLaunches.count < AutomationLimits.replayEntries else { return failure(request, .replayWindowFull) }
            interactiveLaunches[request.requestID] = (request, caller, nil)
            let reply: AutomationReply
            do {
                guard !Task.isCancelled, !stopped else { throw AutomationError(code: .cancelled) }
                let features = try spi.map { try SPIFeatures(parsing: $0) }
                try registry.launch(profile, url: url, spiOverride: features, nonActivatingPresentation: true)
                reply = AutomationReply(requestID: request.requestID, outcome: .success(.interactiveLaunched(profileID: profileID)))
            } catch is WorkspaceError { reply = failure(request, .profileAlreadyRunning) }
            catch let error as AutomationError { reply = AutomationReply(requestID: request.requestID, outcome: .failure(error)) }
            catch { reply = failure(request, .backendUnavailable) }
            interactiveLaunches[request.requestID] = (request, caller, reply)
            return reply
        }
        #else
        if case .launchInteractive = request.action { return failure(request, .backgroundLaunchUnverified) }
        #endif
        if case .commitControlRelease = request.action { return failure(request, .invalidRequest) }
        if case .openSession(let profileID) = request.action {
            return await open(request, caller: caller, profileID: profileID)
        }
        guard let token = request.sessionID, let entry = sessions[token], entry.caller.sameCaller(as: caller) else {
            return failure(request, .sessionNotFound)
        }
        if opens[request.requestID] != nil { return failure(request, .requestIDReused) }
        if let previous = entry.releaseRequest, previous.requestID == request.requestID,
           !sameRequest(previous, request) { return failure(request, .requestIDReused) }
        if entry.phase == .released {
            if let previous = entry.releaseRequest, previous.requestID == request.requestID {
                guard sameRequest(previous, request) else { return failure(request, .requestIDReused) }
                return entry.releaseReply ?? failure(request, .indeterminateResult)
            }
            return failure(request, .sessionExpired)
        }
        if case .releaseControl = request.action { return await release(request, entry: entry) }
        if entry.phase == .releasing {
            switch request.action {
            case .cancel, .closeSession:
                startClose(entry)
                return AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible)))
            default: return failure(request, .sessionBusy)
            }
        }
        let reducing: Bool
        switch request.action { case .cancel, .closeSession: reducing = true; default: reducing = false }
        if reducing { return await requestFlow(request, entry: entry, deadline: .infinity, flag: CancellationFlag(), sent: CancellationFlag()) }
        guard entry.phase == .active, now() < entry.leaseDeadline else {
            if entry.phase == .active { startClose(entry) }
            return failure(request, .sessionExpired)
        }
        let duration: Double
        if request.action.isNavigation { duration = AutomationLimits.navigationSeconds } else { duration = AutomationLimits.actionSeconds }
        let deadline = now() + duration, flag = CancellationFlag(), sent = CancellationFlag()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        let diagnosticMove: Bool
        if case .move = request.action { diagnosticMove = true } else { diagnosticMove = false }
        #endif
        do {
            return try await runUntil(deadline: deadline, flag: flag, owner: entry, work: { [self] in
                await requestFlow(request, entry: entry, deadline: deadline, flag: flag, sent: sent)
            })
        } catch let error as AutomationError {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if diagnosticMove {
                let instant = DispatchTime.now().uptimeNanoseconds
                let elapsed = instant >= diagnosticStart ? (instant - diagnosticStart) / 1_000_000 : 0
                fputs("HOVER_MANAGER phase=run_until.catch elapsed_ms=\(elapsed) code=\(error.code.rawValue)\n", stderr)
            }
            #endif
            if error.code == .sessionBusy { return failure(request, .sessionBusy) }
            startClose(entry)
            if sent.cancelled, case .getState = request.action { return AutomationReply(requestID: request.requestID, outcome: .failure(error)) }
            if sent.cancelled { return AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible))) }
            return AutomationReply(requestID: request.requestID, outcome: .failure(error))
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if diagnosticMove {
                let instant = DispatchTime.now().uptimeNanoseconds
                let elapsed = instant >= diagnosticStart ? (instant - diagnosticStart) / 1_000_000 : 0
                fputs("HOVER_MANAGER phase=run_until.catch elapsed_ms=\(elapsed) code=unknown\n", stderr)
            }
            #endif
            startClose(entry); return failure(request, .cancelled)
        }
    }
    private func requestFlow(_ request: AutomationRequest, entry: Entry, deadline: Double, flag: CancellationFlag, sent: CancellationFlag) async -> AutomationReply {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        NavigationDiagnostic.emit(request, "manager.flow.enter")
        #endif
        func valid() -> Bool { !flag.cancelled && now() < deadline && entry.phase == .active && admission() && !stopped }
        switch request.action {
        case .cancel, .closeSession: break
        default:
            guard entry.phase == .active, now() < entry.leaseDeadline else { if entry.phase == .active { startClose(entry, excluding: flag) }; return failure(request, .sessionExpired) }
            do {
                guard let profile = try await profileReader(entry.profileID), profile.id == entry.profileID, profile.allowsAgentAccess else {
                    startClose(entry, excluding: flag); return failure(request, .profileNotAllowed)
                }
            } catch { startClose(entry, excluding: flag); return failure(request, .profileNotAllowed) }
            guard valid(), now() < entry.leaseDeadline else { return failure(request, .cancelled) }
        }
        let reducing: Bool
        switch request.action { case .cancel, .closeSession: reducing = true; default: reducing = false }
        if reducing && entry.ordinaryIDs.contains(request.requestID) { return failure(request, .requestIDReused) }
        if !reducing && entry.closeRequests[request.requestID] != nil { return failure(request, .requestIDReused) }
        if reducing, let previous = entry.closeRequests[request.requestID] {
            guard sameRequest(previous, request) else { return failure(request, .requestIDReused) }
            let receipt = await close(entry, excluding: flag)
            return AutomationReply(requestID: request.requestID, outcome: .success(.sessionClosed(receipt)))
        }
        switch entry.replay.begin(request, at: now()) {
        case .replay(let reply): return reply
        case .inFlight: return failure(request, .sessionBusy)
        case .rejected(let code):
            guard reducing && (code == .replayWindowFull || code == .sessionExpired) else { return failure(request, code) }
        case .reserved:
            if !reducing { entry.ordinaryIDs.insert(request.requestID) }
        }
        switch request.action {
        case .cancel, .closeSession:
            guard entry.closeRequests.count < AutomationLimits.replayEntries else { return failure(request, .replayWindowFull) }
            entry.closeRequests[request.requestID] = request
            let receipt: CleanupReceipt
            if let existing = entry.closeReceipt { receipt = existing }
            else {
                guard entry.phase == .active || entry.phase == .releasing || entry.phase == .closing else { return failure(request, .sessionBusy) }
                receipt = await close(entry, excluding: flag, proofRequest: request)
            }
            let reply = AutomationReply(requestID: request.requestID, outcome: .success(.sessionClosed(receipt)))
            _ = entry.replay.complete(request, reply: reply, at: now())
            return reply
        default: break
        }
        guard entry.phase == .active, let endpoint = entry.endpoint else { return failure(request, .sessionNotFound) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        let diagnosticMove: Bool
        if case .move = request.action { diagnosticMove = true } else { diagnosticMove = false }
        #endif
        let reply: AutomationReply
        do {
            guard valid(), identityMatches(entry, endpoint) else { startClose(entry, excluding: flag); return failure(request, .cancelled) }
            guard entry.replay.renew(at: now()) else { _ = await close(entry, excluding: flag); return failure(request, .sessionExpired) }
            armLease(entry)
            let timeout: Double
            if request.action.isNavigation { timeout = AutomationLimits.navigationSeconds } else { timeout = AutomationLimits.actionSeconds }
            guard valid() else { return failure(request, .cancelled) }
            sent.cancel()
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            NavigationDiagnostic.emit(request, "manager.endpoint.before")
            if diagnosticMove {
                let instant = DispatchTime.now().uptimeNanoseconds
                let elapsed = instant >= diagnosticStart ? (instant - diagnosticStart) / 1_000_000 : 0
                fputs("HOVER_MANAGER phase=endpoint.before elapsed_ms=\(elapsed)\n", stderr)
            }
            #endif
            let result = try await endpoint.request(request, timeoutSeconds: timeout)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let traceResult: String
            switch result.outcome { case .success: traceResult = "ok"; case .failure(let error): traceResult = error.code.rawValue }
            NavigationDiagnostic.emit(request, "manager.endpoint.return", traceResult)
            if diagnosticMove {
                let instant = DispatchTime.now().uptimeNanoseconds
                let elapsed = instant >= diagnosticStart ? (instant - diagnosticStart) / 1_000_000 : 0
                let code: String
                switch result.outcome { case .success: code = "ok"; case .failure(let error): code = error.code.rawValue }
                fputs("HOVER_MANAGER phase=endpoint.return elapsed_ms=\(elapsed) code=\(code)\n", stderr)
            }
            #endif
            guard valid(), identityMatches(entry, endpoint), result.requestID == request.requestID else { return failure(request, .cancelled) }
            guard (try? AutomationCodec.decodeReply(AutomationCodec.encode(result))) != nil else { _ = await close(entry, excluding: flag); return failure(request, .invalidRequest) }
            guard matches(result, action: request.action, target: entry.target) else {
                _ = await close(entry, excluding: flag); return failure(request, .targetChanged)
            }
            reply = result
        } catch let error as AutomationError {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            NavigationDiagnostic.emit(request, "manager.endpoint.error", error.code.rawValue)
            if diagnosticMove {
                let instant = DispatchTime.now().uptimeNanoseconds
                let elapsed = instant >= diagnosticStart ? (instant - diagnosticStart) / 1_000_000 : 0
                fputs("HOVER_MANAGER phase=endpoint.catch elapsed_ms=\(elapsed) code=\(error.code.rawValue)\n", stderr)
            }
            #endif
            reply = AutomationReply(requestID: request.requestID, outcome: .failure(error))
        }
        catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            NavigationDiagnostic.emit(request, "manager.endpoint.catch", error is CancellationError ? "cancelled" : "other")
            if diagnosticMove {
                let instant = DispatchTime.now().uptimeNanoseconds
                let elapsed = instant >= diagnosticStart ? (instant - diagnosticStart) / 1_000_000 : 0
                let code = error is CancellationError ? "cancelled" : "unknown"
                fputs("HOVER_MANAGER phase=endpoint.catch elapsed_ms=\(elapsed) code=\(code)\n", stderr)
            }
            #endif
            let readOnly: Bool
            if case .getState = request.action { readOnly = true } else { readOnly = false }
            reply = AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: readOnly ? .runnerExited : .indeterminateResult, sideEffects: readOnly ? .none : .possible)))
        }
        _ = entry.replay.complete(request, reply: reply, at: now())
        if case .failure(let error) = reply.outcome, error.code == .runnerExited || error.code == .indeterminateResult {
            startClose(entry, excluding: flag)
        }
        return reply
    }
    private func open(_ request: AutomationRequest, caller: AutomationScriptCallerProof, profileID: UUID) async -> AutomationReply {
        pruneRetainedRunners()
        if let existing = opens[request.requestID] {
            guard existing.caller.sameCaller(as: caller), sameRequest(existing.request, request) else { return failure(request, .requestIDReused) }
            if existing.phase == .active && now() >= existing.leaseDeadline { startClose(existing); return failure(request, .sessionExpired) }
            if existing.phase == .active {
                let deadline = min(now() + AutomationLimits.startupSeconds, existing.leaseDeadline)
                let flag = CancellationFlag()
                do {
                    return try await runUntil(deadline: deadline, flag: flag, owner: existing, work: { [self] in
                        guard let profile = try await profileReader(profileID), profile.id == profileID, profile.allowsAgentAccess else { startClose(existing); return failure(request, .profileNotAllowed) }
                        guard !flag.cancelled, now() < deadline, existing.phase == .active, admission(), !stopped else { return failure(request, .cancelled) }
                        return existing.openReply ?? failure(request, .sessionBusy)
                    })
                } catch let error as AutomationError { return AutomationReply(requestID: request.requestID, outcome: .failure(error)) }
                catch { return failure(request, .profileNotAllowed) }
            }
            if let reply = existing.openReply, case .failure = reply.outcome { return reply }
            return failure(request, existing.phase == .opening ? .sessionBusy : .sessionExpired)
        }
        guard opens.count < AutomationLimits.replayEntries else { return failure(request, .replayWindowFull) }
        guard opens.values.filter({ ($0.phase != .closed && $0.phase != .released) || $0.openWorkerRunning || $0.closeWorkerRunning || !$0.cancellers.isEmpty }).count < 8 else { return failure(request, .sessionBusy) }
        guard !opens.values.contains(where: { entry in
            guard entry.profileID == profileID else { return false }
            if entry.phase == .released { return entry.registeredInteractive ? false : (entry.identity.map { retainedRunners[$0.ownership] != nil } ?? true) }
            return entry.phase != .closed || entry.openWorkerRunning || entry.closeWorkerRunning || !entry.cancellers.isEmpty
        }) else { return failure(request, .profileAlreadyRunning) }
        let entry = Entry(request, caller, profileID, now: now())
        opens[request.requestID] = entry; changed()
        entry.openWorkerRunning = true
        let deadline = now() + AutomationLimits.startupSeconds
        let flag = CancellationFlag(), sent = CancellationFlag()
        do {
            return try await runUntil(deadline: deadline, flag: flag, owner: entry, work: { [self] in
                await openFlow(request, entry: entry, profileID: profileID, deadline: deadline, flag: flag, sent: sent)
            }, onReturn: { entry.openWorkerRunning = false })
        } catch let error as AutomationError {
            if entry.cancellers.isEmpty { entry.openWorkerRunning = false }
            startClose(entry)
            let reported = sent.cancelled ? AutomationError(code: .indeterminateResult, sideEffects: .possible) : error
            return finishOpen(entry, AutomationReply(requestID: request.requestID, outcome: .failure(reported)))
        } catch {
            startClose(entry); return finishOpen(entry, failure(request, .cancelled))
        }
    }
    private func openFlow(_ request: AutomationRequest, entry: Entry, profileID: UUID, deadline: Double, flag: CancellationFlag, sent: CancellationFlag) async -> AutomationReply {
        func valid() -> Bool { !flag.cancelled && now() < deadline && entry.phase == .opening && admission() && !stopped }
        guard valid() else { return finishOpen(entry, failure(request, .cancelled)) }
        do {
            guard let profile = try await profileReader(profileID), profile.id == profileID, profile.allowsAgentAccess else { return finishOpen(entry, failure(request, .profileNotAllowed)) }
            guard valid() else { return finishOpen(entry, failure(request, .cancelled)) }
            let endpoint: any AutomationManagerEndpoint
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if let connector = registeredConnector {
                endpoint = try await connector(profile)
            } else {
                guard !(await humanRunning(profileID)) else { return finishOpen(entry, failure(request, .profileAlreadyRunning)) }
                guard valid() else { return finishOpen(entry, failure(request, .cancelled)) }
                endpoint = try await runnerFactory(profile)
            }
            #else
            guard !(await humanRunning(profileID)) else { return finishOpen(entry, failure(request, .profileAlreadyRunning)) }
            guard valid() else { return finishOpen(entry, failure(request, .cancelled)) }
            endpoint = try await runnerFactory(profile)
            #endif
            let identity = (endpoint.pid, endpoint.runnerInstanceID, endpoint.ownershipID)
            guard valid() else {
                let disposalDeadline = now() + AutomationLimits.cleanupSeconds
                let disposalFlag = CancellationFlag()
                entry.closeWorkerRunning = true
                do {
                    _ = try await runUntil(deadline: disposalDeadline, flag: disposalFlag, cleanup: true, work: {
                        guard endpoint.pid == identity.0, endpoint.runnerInstanceID == identity.1, endpoint.ownershipID == identity.2 else { return nil as ProcessExit? }
                        return try await endpoint.closeAndWait(timeoutSeconds: AutomationLimits.cleanupSeconds)
                    }, onReturn: { entry.closeWorkerRunning = false })
                } catch let error as AutomationError {
                    if error.code == .sessionBusy { entry.closeWorkerRunning = false }
                } catch { }
                return finishOpen(entry, failure(request, .cancelled))
            }
            entry.endpoint = endpoint
            entry.registeredInteractive = endpoint.registeredInteractive
            entry.identity = identity
            guard let fresh = try await profileReader(profileID), fresh.id == profileID, fresh.allowsAgentAccess else { _ = await close(entry, excluding: flag); return finishOpen(entry, failure(request, .profileNotAllowed)) }
            guard identityMatches(entry, endpoint) else { _ = await close(entry, excluding: flag); return finishOpen(entry, failure(request, .runnerExited)) }
            guard valid() else { _ = await close(entry, excluding: flag); return finishOpen(entry, failure(request, .cancelled)) }
            let openForwardedAt = now()
            sent.cancel()
            let reply = try await endpoint.request(request, timeoutSeconds: AutomationLimits.startupSeconds)
            guard valid(), now() < openForwardedAt + AutomationLimits.idleSeconds, identityMatches(entry, endpoint), reply.requestID == request.requestID else { _ = await close(entry, excluding: flag); return finishOpen(entry, failure(request, .cancelled)) }
            if (try? AutomationCodec.decodeReply(AutomationCodec.encode(reply))) != nil,
               case .failure = reply.outcome {
                _ = await close(entry, excluding: flag)
                return finishOpen(entry, reply)
            }
            guard (try? AutomationCodec.decodeReply(AutomationCodec.encode(reply))) != nil,
                  case .success(.sessionOpened(let token, let target, let viewport)) = reply.outcome,
                  AutomationSessionToken.isCanonical(token), target.profileID == profileID,
                  target.runnerInstanceID == endpoint.runnerInstanceID, endpoint.pid > 0,
                  NativeInputPreflight.viewportValid(viewport), sessions[token] == nil else {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                switch reply.outcome {
                case .failure(let error):
                    fputs("OPEN_DIAG phase=manager.reply kind=failure code=\(error.code.rawValue)\n", stderr)
                case .success(.sessionOpened(let token, let target, let viewport)):
                    let roundtrip = (try? AutomationCodec.decodeReply(AutomationCodec.encode(reply))) != nil
                    let canonical = AutomationSessionToken.isCanonical(token)
                    let profileMatches = target.profileID == profileID
                    let instanceMatches = target.runnerInstanceID == endpoint.runnerInstanceID
                    let pidPositive = endpoint.pid > 0
                    let viewportValid = NativeInputPreflight.viewportValid(viewport)
                    let tokenUnused = sessions[token] == nil
                    fputs("OPEN_DIAG phase=manager.reply kind=sessionOpened roundtrip=\(roundtrip) canonical=\(canonical) profileMatch=\(profileMatches) instanceMatch=\(instanceMatches) pidPositive=\(pidPositive) viewportValid=\(viewportValid) tokenUnused=\(tokenUnused)\n", stderr)
                case .success:
                    fputs("OPEN_DIAG phase=manager.reply kind=other\n", stderr)
                }
                #endif
                _ = await close(entry, excluding: flag); return finishOpen(entry, failure(request, .invalidRequest))
            }
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            #if SAFARIER_MANAGER_ROUTING_TESTS
            let requiresConcreteProof = injectedOwnedRegistrationProof?() != true
            #else
            let requiresConcreteProof = true
            #endif
            if requiresConcreteProof {
            // Observe only the existing Manager and the exact concrete owned
            // client's registration; PID comparison is not routing authority.
            #if SAFARIER_INTERNAL_TEST_APP
            let diagnosticBundleID = "sh.safarier.testing"
            #else
            let diagnosticBundleID = "sh.safarier.boundcandidate"
            #endif
            let registrations = NSRunningApplication.runningApplications(withBundleIdentifier: diagnosticBundleID)
            let managerPID = getpid()
            let managerCount = registrations.filter { $0.processIdentifier == managerPID }.count
            guard let concrete = Self.concreteOwnedClient(endpoint) else {
                fputs("OWNED_REG_DIAG proofAvailable=false matchingCount=\(registrations.count) managerRegistered=\(managerCount == 1)\n", stderr)
                _ = await close(entry, excluding: flag)
                return finishOpen(entry, failure(request, .runnerExited))
            }
            let runnerPID = concrete.pid
            let runnerCount = registrations.filter { $0.processIdentifier == runnerPID }.count
            let otherCount = registrations.filter { $0.processIdentifier != managerPID && $0.processIdentifier != runnerPID }.count
            let managerRegistered = managerCount == 1
            let originalOwnedRunnerRegistered = runnerPID != managerPID && runnerCount == 1
            let sameBefore = entry.endpoint.flatMap(Self.concreteOwnedClient) === concrete && identityMatches(entry, concrete)
            var realCoreRoundtripValidated = false
            let remaining = min(deadline, openForwardedAt + AutomationLimits.idleSeconds) - now()
            if managerRegistered && otherCount == 0 && sameBefore && valid() && remaining.isFinite && remaining > 0 {
                let observation = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
                do {
                    let observed = try await concrete.request(observation, timeoutSeconds: min(AutomationLimits.actionSeconds, remaining))
                    if observed.requestID == observation.requestID, case .success(.capabilities) = observed.outcome {
                        realCoreRoundtripValidated = true
                    }
                } catch { /* Failure is recorded below without the error payload. */ }
            }
            let sameEndpointOwnership = sameBefore && entry.endpoint.flatMap(Self.concreteOwnedClient) === concrete && identityMatches(entry, concrete)
            fputs("OWNED_REG_DIAG matchingCount=\(registrations.count) managerRegistered=\(managerRegistered) originalOwnedRunnerRegistered=\(originalOwnedRunnerRegistered) sameEndpointOwnership=\(sameEndpointOwnership) realCoreRoundtripValidated=\(realCoreRoundtripValidated) otherRegistrationsCount=\(otherCount)\n", stderr)
            guard managerRegistered, otherCount == 0,
                  sameEndpointOwnership, realCoreRoundtripValidated,
                  valid(), now() < openForwardedAt + AutomationLimits.idleSeconds, sessions[token] == nil else {
                _ = await close(entry, excluding: flag)
                return finishOpen(entry, failure(request, .runnerExited))
            }
            }
            #endif
            // No session request has used this cache yet. Startup time must not
            // consume the newly bound session's replay lifetime.
            entry.replay = AutomationReplayCache(startedAt: now())
            entry.token = token; entry.target = target; entry.phase = .active; sessions[token] = entry
            armLease(entry, since: openForwardedAt)
            guard entry.phase == .active else { return finishOpen(entry, failure(request, .sessionExpired)) }
            entry.openReply = reply; changed(); return reply
        } catch let error as AutomationError {
            if entry.endpoint != nil { _ = await close(entry, excluding: flag) }
            return finishOpen(entry, AutomationReply(requestID: request.requestID, outcome: .failure(error)))
        } catch {
            if entry.endpoint != nil { _ = await close(entry, excluding: flag) }
            let error = sent.cancelled ? AutomationError(code: .indeterminateResult, sideEffects: .possible) : AutomationError(code: .runnerExited)
            return finishOpen(entry, AutomationReply(requestID: request.requestID, outcome: .failure(error)))
        }
    }
    private func finishOpen(_ entry: Entry, _ reply: AutomationReply) -> AutomationReply {
        if entry.openReply == nil { entry.openReply = reply }
        if entry.phase != .closed && entry.closeTask == nil { entry.phase = .closed; changed() }
        return entry.openReply!
    }
    private func startClose(_ entry: Entry, excluding flag: CancellationFlag? = nil, proofRequest: AutomationRequest? = nil, proofDeadline: Double? = nil) {
        guard entry.closeTask == nil, entry.phase != .released else { return }
        // A reducing request is used only while this original generation is active.
        let explicitProof = entry.phase == .active ? proofRequest : nil
        entry.phase = .closing
        entry.leaseTimer?.cancel(); entry.leaseTimer = nil
        for operation in entry.cancellers.values where operation.flag !== flag { operation.cancel() }
        let endpoint = entry.endpoint
        let ownsEndpoint = endpoint.map { identityMatches(entry, $0) } ?? false
        let pid = entry.identity?.pid
        let originalToken = entry.token, originalTarget = entry.target
        entry.closeTask = Task { [weak self] in
            var observed = false, cleaned = false, borrowedDrainConfirmed = false
            var retainedBrowser: RetainedBrowserCleanup?
            if let self, let endpoint, ownsEndpoint, self.identityMatches(entry, endpoint) {
                let deadline = min(self.now() + AutomationLimits.cleanupSeconds, proofDeadline ?? .infinity)
                if let request = explicitProof, let token = originalToken, let target = originalTarget,
                   request.sessionID == token, AutomationSessionToken.isCanonical(token),
                   self.sessions[token] === entry, entry.token == token, entry.target == target,
                   target.profileID == entry.profileID, target.runnerInstanceID == endpoint.runnerInstanceID {
                    let proofFlag = CancellationFlag()
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    let proofDiagnosticStart = DispatchTime.now().uptimeNanoseconds
                    func proofElapsedMs() -> UInt64 {
                        let instant = DispatchTime.now().uptimeNanoseconds
                        return instant >= proofDiagnosticStart ? (instant - proofDiagnosticStart) / 1_000_000 : 0
                    }
                    var proofAccepted = false
                    #endif
                    do {
                        let reply = try await self.runUntil(deadline: deadline, flag: proofFlag, owner: entry, work: {
                            let remaining = deadline - self.now()
                            guard remaining.isFinite, remaining > 0, self.identityMatches(entry, endpoint),
                                  self.sessions[token] === entry, entry.token == token, entry.target == target else {
                                throw AutomationError(code: .cancelled)
                            }
                            #if SAFARIER_BOUND_LOCAL_CANDIDATE
                            fputs("CLOSE_DIAG phase=manager.proof.before elapsed_ms=\(proofElapsedMs()) remaining_ms=\(Int(remaining * 1000))\n", stderr)
                            #endif
                            return try await endpoint.request(request, timeoutSeconds: min(AutomationLimits.cleanupSeconds, remaining))
                        })
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        switch reply.outcome {
                        case .success(.sessionClosed(let receipt)):
                            fputs("CLOSE_DIAG phase=manager.proof.return elapsed_ms=\(proofElapsedMs()) kind=sessionClosed cleaned=\(receipt.cleaned) terminatedOwnedRunner=\(receipt.terminatedOwnedRunner)\n", stderr)
                        case .failure(let error):
                            fputs("CLOSE_DIAG phase=manager.proof.return elapsed_ms=\(proofElapsedMs()) kind=failure code=\(error.code.rawValue)\n", stderr)
                        case .success:
                            fputs("CLOSE_DIAG phase=manager.proof.return elapsed_ms=\(proofElapsedMs()) kind=other\n", stderr)
                        }
                        #endif
                        if !proofFlag.cancelled, self.now() < deadline, self.identityMatches(entry, endpoint),
                           self.sessions[token] === entry, entry.token == token, entry.target == target,
                           reply.requestID == request.requestID,
                           (try? AutomationCodec.decodeReply(AutomationCodec.encode(reply))) == reply,
                           case .success(.sessionClosed(let receipt)) = reply.outcome,
                           !receipt.terminatedOwnedRunner {
                            cleaned = receipt.cleaned
                            if endpoint.registeredInteractive, !receipt.cleaned,
                               let retained = receipt.retainedBrowser, retained.target == target, retained.confirmed {
                                retainedBrowser = retained
                            }
                            #if SAFARIER_BOUND_LOCAL_CANDIDATE
                            proofAccepted = true
                            #endif
                        }
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        fputs("CLOSE_DIAG phase=manager.proof.accepted elapsed_ms=\(proofElapsedMs()) accepted=\(proofAccepted)\n", stderr)
                        #endif
                    } catch {
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        let code = (error as? AutomationError)?.code.rawValue ?? "unknown"
                        fputs("CLOSE_DIAG phase=manager.proof.catch elapsed_ms=\(proofElapsedMs()) code=\(code)\n", stderr)
                        #endif
                        /* No proof: still close the original owned channel. */
                    }
                }
                let exitFlag = CancellationFlag()
                entry.closeWorkerRunning = true
                do {
                    let exit = try await self.runUntil(deadline: deadline, flag: exitFlag, cleanup: true, work: {
                        guard self.identityMatches(entry, endpoint) else { return nil as ProcessExit? }
                        let remaining = deadline - self.now()
                        // closeAndWait first closes the channel and requires a positive
                        // timeout even when no time remains for observing the exit.
                        let timeout = remaining.isFinite && remaining > 0
                            ? min(AutomationLimits.cleanupSeconds, remaining) : Double.leastNonzeroMagnitude
                        return try await endpoint.closeAndWait(timeoutSeconds: timeout)
                    }, onReturn: { entry.closeWorkerRunning = false })
                    observed = exit?.pid == pid && self.identityMatches(entry, endpoint)
                    borrowedDrainConfirmed = endpoint.registeredInteractive && self.identityMatches(entry, endpoint)
                } catch let error as AutomationError {
                    if error.code == .sessionBusy { entry.closeWorkerRunning = false }
                    observed = false
                } catch { observed = false }
                // A proof never becomes an exit proof, and ownership changes revoke it.
                if let token = originalToken, let target = originalTarget {
                    cleaned = cleaned && self.identityMatches(entry, endpoint) && self.sessions[token] === entry
                        && entry.token == token && entry.target == target
                    if !borrowedDrainConfirmed || !self.identityMatches(entry, endpoint) || self.sessions[token] !== entry || entry.token != token || entry.target != target {
                        retainedBrowser = nil
                    }
                } else { cleaned = false }
            }
            if !borrowedDrainConfirmed { retainedBrowser = nil }
            let receipt = CleanupReceipt(cleaned: cleaned, terminatedOwnedRunner: observed, retainedBrowser: retainedBrowser)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if let request = proofRequest { NavigationDiagnostic.cleanupReceipt(request, cleaned: cleaned, runnerExited: observed) }
            fputs("CLOSE_DIAG phase=manager.receipt cleaned=\(receipt.cleaned) terminatedOwnedRunner=\(receipt.terminatedOwnedRunner)\n", stderr)
            #endif
            entry.closeReceipt = receipt; if entry.phase != .released { entry.phase = .closed }; self?.changed()
            return receipt
        }
        changed()
    }
    private func close(_ entry: Entry, excluding flag: CancellationFlag? = nil, proofRequest: AutomationRequest? = nil) async -> CleanupReceipt {
        if let receipt = entry.closeReceipt { return receipt }
        startClose(entry, excluding: flag, proofRequest: proofRequest)
        return await entry.closeTask!.value
    }

    func profilePermissionsChanged(allowedProfileIDs: Set<UUID>) {
        for entry in opens.values where entry.phase != .closed && entry.phase != .released && !allowedProfileIDs.contains(entry.profileID) {
            startClose(entry)
        }
    }
    func shutdown() {
        stopped = true
        for entry in opens.values where entry.phase != .closed && entry.phase != .released { startClose(entry) }
    }
}
