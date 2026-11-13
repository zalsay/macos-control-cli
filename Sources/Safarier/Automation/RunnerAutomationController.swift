import Foundation
import SafarierCore
#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Darwin
#endif

/// Serial owner of an existing offline reducer. Injected closures are the only
/// possible sources of facts and effects; this type never opens a page itself.
@MainActor final class RunnerAutomationController {
    typealias PermissionReader = @MainActor () async throws -> Bool
    typealias TargetReader = @MainActor () async throws -> AutomationTargetIdentity
    /// The injected native sink must synchronously recheck its actual bound objects
    /// on entry, before any native effect or suspension. This owner cannot make
    /// a cross-process authorization read atomic with the later native operation.
    typealias ActionSink = @MainActor (AutomationRequest, AutomationSessionTicket) async throws -> AutomationReply
    typealias CleanupSink = @MainActor (AutomationTargetIdentity, AutomationCloseReason, AutomationSessionCleanupTicket) async throws -> CleanupReceipt
    typealias Now = @MainActor () -> Double
    typealias SleepUntil = @MainActor (Double) async throws -> Void

    private final class Call {
        let request: AutomationRequest
        let continuation: CheckedContinuation<AutomationReply, Never>
        let cancellation: CancellationFlag
        var ticket: AutomationSessionTicket?
        var sinkStarted = false
        var worker: Task<Void, Never>?
        init(_ request: AutomationRequest, _ continuation: CheckedContinuation<AutomationReply, Never>, _ cancellation: CancellationFlag) { self.request = request; self.continuation = continuation; self.cancellation = cancellation }
    }
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false, completionClaimed = false
        func cancel() { lock.lock(); if !completionClaimed { value = true }; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        // Linearize a final sink result against cancellation from any thread.
        func claimCompletion() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !value, !completionClaimed else { return false }
            completionClaimed = true; return true
        }
    }
    private let machine: AutomationSessionMachine
    private let permissionReader: PermissionReader
    private let targetReader: TargetReader
    private let actionSink: ActionSink
    private let cleanupSink: CleanupSink
    private let borrowedCleanupReceipt: @MainActor () -> CleanupReceipt?
    private let now: Now
    private let sleepUntil: SleepUntil
    private var calls: [UUID: Call] = [:]
    // Retain a bounded slot until an uncooperative reader actually returns, even
    // after its caller has received cancellation. Only UUIDs and counts remain.
    private var readerCounts: [UUID: Int] = [:]
    private var timer: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupOwnership: AutomationSessionCleanupTicket?
    private var cleanupStarted = false
    private var cleanupInFlight = false
    private var cleanupReceipt: CleanupReceipt?
    private var activeSinks = 0
    private var schedulerBroken = false
    private var generation: UInt64 = 0

    init(machine: AutomationSessionMachine, permissionReader: @escaping PermissionReader, targetReader: @escaping TargetReader, actionSink: @escaping ActionSink, cleanupSink: @escaping CleanupSink, borrowedCleanupReceipt: @escaping @MainActor () -> CleanupReceipt? = { nil }, now: @escaping Now = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }, sleepUntil: @escaping SleepUntil = { deadline in
        let current = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let delay = max(0, deadline - current)
        guard delay.isFinite, delay < Double(UInt64.max) / 1_000_000_000 else { throw CancellationError() }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }) {
        self.machine = machine; self.permissionReader = permissionReader; self.targetReader = targetReader
        self.actionSink = actionSink; self.cleanupSink = cleanupSink; self.borrowedCleanupReceipt = borrowedCleanupReceipt; self.now = now; self.sleepUntil = sleepUntil
        scheduleDeadline()
    }
    deinit {
        timer?.cancel()
        if cleanupStarted { cleanupTask?.cancel() }
    }
    private func failure(_ request: AutomationRequest, _ code: AutomationErrorCode, effects: AutomationSideEffects = .none) -> AutomationReply {
        AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: code, sideEffects: effects)))
    }
    func handle(_ request: AutomationRequest) async -> AutomationReply {
        let id = UUID(), flag = CancellationFlag()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if flag.isCancelled || Task.isCancelled { continuation.resume(returning: failure(request, .cancelled)); return }
                guard machine.acceptsSessionID(request.sessionID) else { continuation.resume(returning: failure(request, .sessionNotFound)); return }
                guard (try? AutomationCodec.encodeRequest(request)) != nil else { continuation.resume(returning: failure(request, .invalidRequest)); return }
                guard let bound = machine.boundTarget else { continuation.resume(returning: failure(request, .targetChanged)); return }
                let reducing: Bool
                switch request.action { case .cancel, .closeSession: reducing = true; default: reducing = false }
                guard reducing || (calls.count < AutomationLimits.replayEntries && readerCounts.count < AutomationLimits.replayEntries) else { continuation.resume(returning: failure(request, .replayWindowFull)); return }
                calls[id] = Call(request, continuation, flag)
                if machine.state == .stopping || machine.state == .closed {
                    process(machine.begin(request, permission: true, target: bound, at: now()), origin: id)
                    return
                }
                switch request.action {
                case .cancel, .closeSession:
                    process(machine.begin(request, permission: true, target: bound, at: now()), origin: id)
                default:
                    authorize(id, postTicket: nil)
                }
            }
        }, onCancel: { [weak self] in
            flag.cancel()
            Task { @MainActor [weak self] in self?.cancelCall(id) }
        })
    }
    private func retainReader(_ id: UUID) { readerCounts[id, default: 0] += 1 }
    private func releaseReader(_ id: UUID) {
        guard let count = readerCounts[id] else { return }
        if count <= 1 { readerCounts.removeValue(forKey: id) } else { readerCounts[id] = count - 1 }
    }
    private func authorize(_ id: UUID, postTicket: AutomationSessionTicket?) {
        guard let call = calls[id] else { return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        switch call.request.action {
        case .releaseControl, .commitControlRelease: NavigationDiagnostic.emit(call.request, "runner.permission.initial.before")
        default: break
        }
        #endif
        let read = permissionReader
        retainReader(id)
        call.worker = Task { @MainActor [weak self] in
            defer { self?.releaseReader(id) }
            guard !Task.isCancelled, self?.isLive(id, ticket: postTicket) == true else { return }
            do { let value = try await read(); self?.permissionResult(id, value: value, ticket: postTicket) }
            catch { self?.permissionResult(id, value: false, ticket: postTicket) }
        }
    }
    private func permissionResult(_ id: UUID, value: Bool, ticket: AutomationSessionTicket?) {
        guard let call = calls[id], call.ticket == ticket else { return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        switch call.request.action {
        case .releaseControl, .commitControlRelease: NavigationDiagnostic.emit(call.request, "runner.permission.initial.after", value ? "ok" : AutomationErrorCode.profileNotAllowed.rawValue)
        default: break
        }
        #endif
        if let ticket, machine.currentTicket != ticket { return }
        guard value else {
            if let ticket {
                let denied = failure(call.request, .profileNotAllowed)
                process(machine.complete(ticket: ticket, reply: denied, at: now()))
                process(machine.event(.permissionRevoked, at: now()))
            } else {
                // A real revocation fact is allowed to stop an existing session.
                finish(id, failure(call.request, .profileNotAllowed))
                process(machine.event(.permissionRevoked, at: now()))
            }
            return
        }
        let read = targetReader
        retainReader(id)
        call.worker = Task { @MainActor [weak self] in
            defer { self?.releaseReader(id) }
            guard !Task.isCancelled, self?.isLive(id, ticket: ticket) == true else { return }
            do { let value = try await read(); self?.targetResult(id, value: value, ticket: ticket) }
            catch { self?.targetResult(id, value: nil, ticket: ticket) }
        }
    }
    private func targetResult(_ id: UUID, value: AutomationTargetIdentity?, ticket: AutomationSessionTicket?) {
        guard let call = calls[id], call.ticket == ticket else { return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        switch call.request.action {
        case .releaseControl, .commitControlRelease: NavigationDiagnostic.emit(call.request, ticket == nil ? "runner.target.initial.after" : "runner.target.ticket.after", value == machine.boundTarget ? "ok" : AutomationErrorCode.targetChanged.rawValue)
        default: break
        }
        #endif
        if let ticket, machine.currentTicket != ticket { return }
        guard let value, value == machine.boundTarget else {
            if let ticket {
                process(machine.complete(ticket: ticket, reply: failure(call.request, .targetChanged), at: now()))
            } else { finish(id, failure(call.request, .targetChanged)) }
            process(machine.event(.targetChanged, at: now()))
            return
        }
        if let ticket {
            guard machine.currentTicket == ticket else { return }
            let sink = actionSink, finalPermission = permissionReader, finalTarget = targetReader
            retainReader(id)
            call.worker = Task { @MainActor [weak self] in
                var readerHeld = true
                defer { if readerHeld { self?.releaseReader(id) } }
                guard !Task.isCancelled, self?.isLive(id, ticket: ticket) == true else { return }
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                if let request = self?.calls[id]?.request {
                    switch request.action {
                    case .releaseControl, .commitControlRelease: NavigationDiagnostic.emit(request, "runner.permission.final.before")
                    default: break
                    }
                }
                #endif
                let allowed = (try? await finalPermission()) ?? false
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                if let request = self?.calls[id]?.request {
                    switch request.action {
                    case .releaseControl, .commitControlRelease: NavigationDiagnostic.emit(request, "runner.permission.final.after", allowed ? "ok" : AutomationErrorCode.profileNotAllowed.rawValue)
                    default: break
                    }
                }
                #endif
                self?.releaseReader(id); readerHeld = false
                guard !Task.isCancelled, self?.isLive(id, ticket: ticket) == true else { return }
                guard allowed else { self?.finalPermissionDenied(id, ticket: ticket); return }
                guard let action = self?.prepareSink(id, ticket: ticket) else { return }
                self?.activeSinks += 1
                defer { self?.activeSinks -= 1 }
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                let diagnosticStart = DispatchTime.now().uptimeNanoseconds
                NavigationDiagnostic.emit(action, "runner.sink.before")
                let diagnosticMove: Bool
                if case .move = action.action { diagnosticMove = true } else { diagnosticMove = false }
                if diagnosticMove { fputs("HOVER_CONTROLLER phase=sink.before elapsed_ms=0\n", stderr) }
                #endif
                do {
                    let reply = try await sink(action, ticket)
                    switch action.action {
                    case .releaseControl, .commitControlRelease:
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        NavigationDiagnostic.emit(action, "runner.permission.post.before")
                        #endif
                        let allowed = (try? await finalPermission()) ?? false
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        NavigationDiagnostic.emit(action, "runner.permission.post.after", allowed ? "ok" : AutomationErrorCode.profileNotAllowed.rawValue)
                        #endif
                        guard !Task.isCancelled, self?.isLive(id, ticket: ticket) == true else { return }
                        guard allowed else { self?.finalPermissionDenied(id, ticket: ticket); return }
                        let observed = try await finalTarget()
                        guard !Task.isCancelled, self?.isLive(id, ticket: ticket) == true else { return }
                        guard observed == self?.machine.boundTarget else { self?.targetChanged(); return }
                    default: break
                    }
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    if diagnosticMove {
                        let now = DispatchTime.now().uptimeNanoseconds
                        let elapsed = now >= diagnosticStart ? (now - diagnosticStart) / 1_000_000 : 0
                        let code: String
                        switch reply.outcome { case .success: code = "ok"; case .failure(let error): code = error.code.rawValue }
                        fputs("HOVER_CONTROLLER phase=sink.return elapsed_ms=\(elapsed) code=\(code)\n", stderr)
                    }
                    #endif
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    let traceResult: String
                    switch reply.outcome { case .success: traceResult = "ok"; case .failure(let error): traceResult = error.code.rawValue }
                    NavigationDiagnostic.emit(action, "runner.sink.return", traceResult)
                    #endif
                    self?.actionResult(ticket, reply: reply)
                } catch {
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    NavigationDiagnostic.emit(action, "runner.sink.catch", (error as? AutomationError)?.code.rawValue ?? "other")
                    if diagnosticMove {
                        let now = DispatchTime.now().uptimeNanoseconds
                        let elapsed = now >= diagnosticStart ? (now - diagnosticStart) / 1_000_000 : 0
                        let code = (error as? AutomationError)?.code.rawValue ?? (error is CancellationError ? "cancelled" : "unknown")
                        fputs("HOVER_CONTROLLER phase=sink.catch elapsed_ms=\(elapsed) code=\(code)\n", stderr)
                    }
                    #endif
                    let effects: AutomationSideEffects
                    switch action.action { case .getState, .screenshot: effects = .none; default: effects = .possible }
                    self?.actionResult(ticket, reply: AutomationReply(requestID: action.requestID, outcome: .failure(AutomationError(code: .indeterminateResult, sideEffects: effects))))
                }
            }
        } else {
            process(machine.begin(call.request, permission: true, target: value, at: now()), origin: id)
        }
    }
    private func finalPermissionDenied(_ id: UUID, ticket: AutomationSessionTicket) {
        guard let call = calls[id], call.ticket == ticket, machine.currentTicket == ticket else { return }
        process(machine.complete(ticket: ticket, reply: failure(call.request, .profileNotAllowed), at: now()))
        process(machine.event(.permissionRevoked, at: now()))
    }
    private func isLive(_ id: UUID, ticket: AutomationSessionTicket?) -> Bool {
        guard let call = calls[id], !call.cancellation.isCancelled, call.ticket == ticket else { return false }
        return ticket == nil || machine.currentTicket == ticket
    }
    private func prepareSink(_ id: UUID, ticket: AutomationSessionTicket) -> AutomationRequest? {
        process(machine.tick(at: now()))
        guard let call = calls[id], !call.cancellation.isCancelled, !Task.isCancelled, call.ticket == ticket, machine.currentTicket == ticket else { return nil }
        call.sinkStarted = true
        return call.request
    }
    private func cleanupDidStart(_ ticket: AutomationSessionCleanupTicket) {
        guard cleanupOwnership == ticket else { return }
        cleanupStarted = true
        if schedulerBroken { scheduleFailedCleanupFinish(ticket) }
    }
    private func scheduleFailedCleanupFinish(_ ticket: AutomationSessionCleanupTicket) {
        Task { @MainActor [weak self] in self?.finishFailedSchedulerCleanup(ticket) }
    }
    private func finishFailedSchedulerCleanup(_ ticket: AutomationSessionCleanupTicket) {
        guard schedulerBroken, machine.currentCleanupTicket == ticket else { return }
        process(machine.event(.schedulingFailed, at: now()))
    }
    private func actionResult(_ ticket: AutomationSessionTicket, reply: AutomationReply) {
        guard machine.currentTicket == ticket, let owner = calls.first(where: { $0.value.ticket == ticket }) else { return }
        guard owner.value.cancellation.claimCompletion() else { cancelCall(owner.key); return }
        process(machine.complete(ticket: ticket, reply: reply, at: now()))
    }
    private func finish(_ id: UUID, _ reply: AutomationReply) {
        guard let call = calls.removeValue(forKey: id) else { return }
        call.worker?.cancel(); call.continuation.resume(returning: reply)
    }
    private func process(_ effects: [AutomationSessionEffect], origin: UUID? = nil) {
        for effect in effects {
            switch effect {
            case .reply(let reply): if let origin { finish(origin, reply) }
            case let .completion(ticket, reply):
                if let pair = calls.first(where: { $0.value.ticket == ticket }) {
                    var result = reply
                    if !pair.value.sinkStarted, case .failure(let error) = reply.outcome, error.sideEffects == .possible {
                        result = AutomationReply(requestID: reply.requestID, outcome: .failure(AutomationError(code: error.code, retryable: error.retryable, sideEffects: .none)))
                    }
                    finish(pair.key, result)
                }
            case .awaitCleanup(let ticket): if let origin { calls[origin]?.ticket = ticket }
            case let .dispatch(ticket, _):
                if let origin, let call = calls[origin] { call.ticket = ticket; authorize(origin, postTicket: ticket) }
            case let .destroyOwnedTarget(target, reason, ticket):
                cleanupOwnership = ticket
                cleanupStarted = false
                cleanupInFlight = true
                let sink = cleanupSink
                cleanupTask = Task { @MainActor [weak self] in
                    // The reducer emits each owned cleanup intent once. Even if the
                    // deadline or owner release occurs before this task starts, make
                    // the one safe cleanup attempt; only its late receipt is ignored.
                    self?.cleanupDidStart(ticket)
                    do {
                        let receipt = try await sink(target, reason, ticket)
                        self?.cleanupReceipt = receipt
                        self?.cleanupInFlight = false
                        self?.cleanupResult(ticket, receipt: receipt)
                    } catch {
                        self?.cleanupInFlight = false
                    }
                }
            }
        }
        if machine.state == .stopping || machine.state == .closed {
            let pending = calls.filter { $0.value.ticket == nil }
            for (id, call) in pending { finish(id, failure(call.request, .cancelled)) }
        }

        scheduleDeadline()
    }
    private func cleanupResult(_ ticket: AutomationSessionCleanupTicket, receipt: CleanupReceipt) {
        process(machine.event(.cleanupFinished(ticket: ticket, receipt: receipt), at: now()))
    }
    private func cancelCall(_ id: UUID) {
        guard let call = calls[id] else { return }
        if let ticket = call.ticket, machine.currentTicket == ticket {
            process(machine.event(.channelClosed, at: now()))
        }
        if let remaining = calls[id] { finish(id, failure(remaining.request, .cancelled, effects: remaining.sinkStarted ? .possible : .none)) }
    }
    private func scheduleDeadline() {
        generation &+= 1; let version = generation
        timer?.cancel(); timer = nil
        guard !schedulerBroken, let deadline = machine.nextDeadline else { return }
        let sleep = sleepUntil
        timer = Task { @MainActor [weak self] in
            do { try await sleep(deadline); self?.deadlineFired(version, deadline: deadline) } catch { self?.deadlineFailed(version) }
        }
    }
    private func deadlineFailed(_ version: UInt64) {
        guard generation == version, !schedulerBroken else { return }
        schedulerBroken = true
        timer = nil
        generation &+= 1
        if machine.state == .stopping {
            if cleanupStarted, let ticket = cleanupOwnership { scheduleFailedCleanupFinish(ticket) }
        } else {
            process(machine.event(.schedulingFailed, at: now()))
        }
    }
    private func deadlineFired(_ version: UInt64, deadline: Double) {
        guard generation == version else { return }
        let instant = now()
        guard instant.isFinite, instant >= deadline else { deadlineFailed(version); return }
        process(machine.tick(at: instant))
    }
    func blockUI(_ request: BackgroundUIRequest) {
        if request == .proxyBoundAuthentication { return }
        process(machine.event(request == .windowClose ? .targetChanged : .blocked, at: now()))
    }
    func webContentLost() { process(machine.event(.targetChanged, at: now())) }
    func permissionRevoked() { process(machine.event(.permissionRevoked, at: now())) }
    func targetChanged() { process(machine.event(.targetChanged, at: now())) }
    func shutdown() { process(machine.event(.channelClosed, at: now())) }

    /// A reducer deadline is not proof that a native sink or cleanup returned.
    func shutdownAndDrain() async -> Bool {
        shutdown()
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.cleanupSeconds)
        while !readerCounts.isEmpty || activeSinks != 0 || cleanupInFlight {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
        }
        let receipt = cleanupReceipt ?? borrowedCleanupReceipt()
        return receipt?.cleaned == true || (receipt?.retainedBrowser?.target == machine.boundTarget && receipt?.retainedBrowser?.confirmed == true)
    }
}
