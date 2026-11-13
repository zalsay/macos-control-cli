import Foundation
#if SAFARIER_BOUND_LOCAL_CANDIDATE
import OSLog
#endif
import Darwin
import BinderIdentity

#if SAFARIER_BOUND_LOCAL_CANDIDATE
// Fixed labels/codes only; no request data or identity material.
func hoverCoreTrace(_ phase: String, _ code: String = "ok") {
    let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
    fputs("HOVER_CORE phase=\(phase) monotonic_ms=\(ms) code=\(code)\n", stderr)
}
private func boundServerTrace(_ phase: String, _ start: UInt64, _ result: String = "ok") {
    let now = DispatchTime.now().uptimeNanoseconds
    let ms = now >= start ? (now - start) / 1_000_000 : 0
    fputs("BOUND_DIAG phase=\(phase) elapsed_ms=\(ms) result=\(result)\n", stderr)
}
private func boundServerError(_ error: Error) -> String {
    if let error = error as? AutomationChannel.ChannelError {
        switch error {
        case .closed: return "channelClosed"
        case .invalidSocket: return "channelInvalidSocket"
        case .invalidFrameLength: return "channelInvalidFrame"
        case .sendBackpressure: return "channelBackpressure"
        case .truncatedFrame: return "channelTruncatedFrame"
        case .readerConflict: return "channelReaderConflict"
        case .systemCall: return "channelSystemCall"
        }
    }
    if let error = error as? AutomationError { return error.code.rawValue }
    if error is CancellationError { return "cancelled" }
    if let error = error as? HarnessError {
        switch error {
        case .identityNotReady: return "identityNotReady"
        case .invalidClock: return "invalidClock"
        case .deadline: return "deadline"
        case .eof: return "eof"
        case .invalidMode: return "invalidMode"
        case .environment: return "environment"
        }
    }
    if let error = error as? V1SeamError {
        switch error {
        case .invalidPhase: return "invalidPhase"
        case .foreignToken: return "foreignToken"
        case .eof: return "eof"
        case .disconnected: return "disconnected"
        }
    }
    if let error = error as? FixtureContextFailure {
        switch error {
        case .revoked: return "revoked"
        case .wrongChannel: return "wrongChannel"
        case .wrongPhase: return "wrongPhase"
        case .wrongProfile: return "wrongProfile"
        case .lifetime: return "lifetime"
        case .noPeer: return "noPeer"
        case .peerAlreadyPinned: return "peerAlreadyPinned"
        }
    }
    return "unknown"
}
#endif

// File-private construction: only this server implementation can mint these capabilities.
final class FixtureWriterBinding: @unchecked Sendable {
    private final class WeakRunner { weak var value: AutomationRunnerServer?; init(_ value: AutomationRunnerServer) { self.value = value } }
    private final class WeakController { weak var value: ControllerGenerationContext?; init(_ value: ControllerGenerationContext) { self.value = value } }
    private enum Owner { case runner(WeakRunner), controller(WeakController) }
    private let owner: Owner
    fileprivate var server: AutomationRunnerServer? { if case .runner(let ref) = owner { return ref.value }; return nil }
    fileprivate let context: FixtureContext?
    private let revocation: FixtureRevocation
    let channel: AutomationChannel
    let reader: AutomationChannel.ReaderLease
    fileprivate init(server: AutomationRunnerServer, context: FixtureContext, reader: AutomationChannel.ReaderLease) {
        self.owner = .runner(WeakRunner(server)); self.context = context; self.revocation = context.revocation
        self.channel = context.channel; self.reader = reader
    }
    fileprivate init(controller: ControllerGenerationContext) {
        self.owner = .controller(WeakController(controller)); self.context = nil; self.revocation = controller.revocation
        self.channel = controller.channel; self.reader = controller.reader
    }
    func validateOwnedQueuedWrite(_ admission: SealedWriteAdmission) async throws {
        switch owner {
        case .runner(let ref):
            guard let server = ref.value else { throw AutomationChannel.ChannelError.closed }
            try await server.validateOwnedQueuedWrite(admission)
        case .controller(let ref):
            guard let controller = ref.value else { throw AutomationChannel.ChannelError.closed }
            try await controller.validateOwnedQueuedWrite(admission)
        }
    }
    func checkCommit() throws {
        switch owner {
        case .runner(let ref): guard ref.value != nil else { throw AutomationChannel.ChannelError.closed }
        case .controller(let ref): guard ref.value != nil else { throw AutomationChannel.ChannelError.closed }
        }
        try revocation.check()
    }
    var isController: Bool { if case .controller = owner { return true }; return false }
    fileprivate func belongs(to context: ControllerGenerationContext) -> Bool {
        if case .controller(let ref) = owner { return ref.value === context }; return false
    }
    fileprivate func expire() { revocation.revoke() }
}
final class SealedWriteAdmission: @unchecked Sendable {
    fileprivate enum Kind { case ready, response(UUID), diagnostic, controllerHello, controllerRequest(UUID, generation: UUID) }
    let binding: FixtureWriterBinding
    let frame: Data
    let deadline: FrameDeadline
    let cutoff: UInt64
    fileprivate let kind: Kind
    private let lock = NSLock()
    private var claimed = false
    private var settled = false
    fileprivate init(binding: FixtureWriterBinding, frame: Data, deadline: FrameDeadline, cutoff: UInt64, kind: Kind) {
        self.binding = binding; self.frame = frame; self.deadline = deadline; self.cutoff = cutoff; self.kind = kind
    }
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed, !settled else { return false }; claimed = true; return true }
    fileprivate func armDeadline() {
        DispatchQueue.global().asyncAfter(deadline: DispatchTime(uptimeNanoseconds: cutoff)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.settled else { self.lock.unlock(); return }
            self.settled = true; self.lock.unlock()
            self.binding.expire()
        }
    }
    func finishDeadline() { lock.lock(); settled = true; lock.unlock() }
    var isControllerRequest: Bool { if case .controllerRequest = kind { return true }; return false }
    func isOwnedRequest(context: ControllerGenerationContext, id: UUID, generation: UUID) -> Bool {
        guard binding.belongs(to: context), case .controllerRequest(let expectedID, let expectedGeneration) = kind else { return false }
        return expectedID == id && expectedGeneration == generation
    }
}


/// One inherited channel and one reader. It is not an authorization or page backend.
public actor AutomationRunnerServer {
    public typealias Handler = @Sendable (AutomationRequest) async -> AutomationOutcome
    public typealias Shutdown = @Sendable () -> Void
    public nonisolated let runnerInstanceID: UUID
    private let profileID: UUID
    private let channel: AutomationChannel
    private let idleSeconds: Double
    private let maxOrdinaryRequests: Int
    private let handler: Handler
    private let shutdownHook: Shutdown
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ordinary: Set<UUID> = []
    private var reserved: Set<UUID> = []
    private struct QueuedWrite {
        let id: UUID
        let bytes: Data
        let reserved: Bool
        let admission: SealedWriteAdmission?
    }
    private var queuedWrites: [QueuedWrite] = []
    private var ordinaryWrites = 0
    private var reservedWrites = 0
    private var diagnosticWriting = false
    private var fixtureContext: FixtureContext?
    private var appContext: RunnerBinderContext?
    private var fixtureWriterBinding: FixtureWriterBinding?
    private var fixtureInstallAttempted = false
    private var fixtureInstalled = false
    private var fixtureFailure: String?
    private let seamID = UUID()
    private var seamPhase = 0
    private var seamLifetimeTimer: DispatchSourceTimer?
    private var seamPreparationTimer: DispatchSourceTimer?
    private var seamPreparation: V1PreparationCompletion?
    private var seamLifetimeEnd: UInt64?
    private var started = false
    private var stopped = false
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var hoverMoveIDs: Set<UUID> = []
    private var hoverFirstFailureLogged = false
    private func hoverFailure(_ phase: String, _ code: String) {
        guard !hoverFirstFailureLogged else { return }
        hoverFirstFailureLogged = true
        hoverCoreTrace(phase, code)
    }
    #endif
    private let reservedLimit = 2

    public init(profileID: UUID, runnerInstanceID: UUID = UUID(), channel: AutomationChannel, idleSeconds: Double = AutomationLimits.idleSeconds, maxOrdinaryRequests: Int = 8, handler: @escaping Handler, shutdown: @escaping Shutdown) {
        self.profileID = profileID; self.runnerInstanceID = runnerInstanceID; self.channel = channel
        self.idleSeconds = idleSeconds; self.maxOrdinaryRequests = maxOrdinaryRequests
        self.handler = handler; self.shutdownHook = shutdown
    }
    private static func validTimeout(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds > 0 && seconds < Double(UInt64.max) / 1_000_000_000
    }
    private func stop() {
        guard !stopped else { return }
        stopped = true
        if let context = fixtureContext {
            context.revocation.revoke()
            // The App returns the lock loan only after native resources drain.
        }
        seamLifetimeTimer?.cancel(); seamLifetimeTimer = nil
        seamPreparationTimer?.cancel(); seamPreparationTimer = nil
        seamPreparation?.cancel(); seamPreparation = nil
        channel.close()
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); ordinary.removeAll(); reserved.removeAll(); queuedWrites.removeAll()
        let hook = shutdownHook
        Task.detached { hook() }
    }
    public func serve() async -> Int32 {
        guard !started, !fixtureInstallAttempted else { return 1 }
        started = true
        guard Self.validTimeout(idleSeconds), (1...32).contains(maxOrdinaryRequests) else { stop(); return 1 }
        let result: Int32 = await withTaskCancellationHandler(operation: {
            do {
                guard let hello = try await AutomationChannelDeadline.run(channel: channel, seconds: idleSeconds, operation: { try await self.channel.receive() }) else { return 0 }
                let challenge = try AutomationHandshakeCodec.readChallenge(hello, expectedProfileID: profileID)
                let response = try AutomationHandshakeCodec.makeResponse(challenge, runnerInstanceID: runnerInstanceID, runnerPID: getpid())
                try await AutomationChannelDeadline.run(channel: channel, seconds: idleSeconds) { try await self.channel.send(response) }
                return try await self.requestLoop(receive: { try await self.channel.receive() }, checkDisconnect: false)
            } catch { return 1 }
        }, onCancel: { channel.close() })
        stop()
        return result
    }
    private func fixtureCheck(_ label: String, phase: Int, deadline: FrameDeadline? = nil, establishPeer: Bool = false, requestID: UUID? = nil) async throws {
        guard let context = fixtureContext else {
            if fixtureInstallAttempted { throw FixtureContextFailure.wrongPhase }
            return // unbound legacy mechanics only
        }
        do {
            guard !stopped, seamPhase == phase, context.channel === channel else { throw FixtureContextFailure.wrongPhase }
            if let requestID { guard tasks[requestID] != nil, ordinary.contains(requestID) || reserved.contains(requestID) else { throw FixtureContextFailure.wrongPhase } }
            let d = try deadline ?? FrameDeadline(lifetimeStart: context.lifetimeStart)
            try await withTaskCancellationHandler(operation: {
                try await context.check(deadline: d, establishPeer: establishPeer, requirePeer: !establishPeer)
            }, onCancel: { context.revocation.revoke() })
            guard fixtureContext === context, context.channel === channel, !stopped, seamPhase == phase else { throw FixtureContextFailure.wrongPhase }
            if let requestID { guard tasks[requestID] != nil, ordinary.contains(requestID) || reserved.contains(requestID) else { throw FixtureContextFailure.wrongPhase } }
            try context.revocation.check(); try Task.checkCancellation(); _ = try d.remaining()
        } catch {
            let diagnostic = "phase=\(label) type=\(String(reflecting:type(of:error))) error=\(error)"
            if !stopped { fputs("FIXTURE_DENIAL \(diagnostic)\n", stderr) }
            context.revocation.fail(error, diagnostic: diagnostic)
            fixtureFailure = context.revocation.diagnostic()
            throw error
        }
    }
    private func mintWrite(_ frame: Data, deadline: FrameDeadline, cap: Double?, kind: SealedWriteAdmission.Kind) throws -> SealedWriteAdmission {
        guard let binding = fixtureWriterBinding, binding.context === fixtureContext else { throw FixtureContextFailure.wrongPhase }
        var cutoff = try deadline.cutoffNanoseconds()
        if let cap {
            let now = DispatchTime.now().uptimeNanoseconds
            let (end, overflow) = now.addingReportingOverflow(UInt64(cap * 1_000_000_000))
            guard !overflow else { throw HarnessError.invalidClock }
            cutoff = min(cutoff, end)
        }
        guard DispatchTime.now().uptimeNanoseconds < cutoff else { throw HarnessError.deadline }
        let admission = SealedWriteAdmission(binding: binding, frame: frame, deadline: deadline, cutoff: cutoff, kind: kind)
        admission.armDeadline()
        return admission
    }
    func validateOwnedQueuedWrite(_ admission: SealedWriteAdmission) async throws {
        do { try await validateOwnedQueuedWriteImpl(admission) }
        catch {
            if let context = fixtureContext {
                context.revocation.fail(error, diagnostic: "phase=queue-attempt type=\(String(reflecting:type(of:error))) error=\(error)")
                fixtureFailure = context.revocation.diagnostic()
            }
            throw error
        }
    }
    private func validateOwnedQueuedWriteImpl(_ admission: SealedWriteAdmission) async throws {
        guard let binding = fixtureWriterBinding, admission.binding === binding,
              binding.server === self, binding.channel === channel, binding.context === fixtureContext else { throw FixtureContextFailure.wrongChannel }
        func checkState() throws -> (Int, UUID?) {
            guard !stopped else { throw FixtureContextFailure.wrongPhase }
            switch admission.kind {
            case .ready:
                guard seamPhase == 3 else { throw FixtureContextFailure.wrongPhase }
                return (3, nil)
            case .response(let id):
                try requireSeamCommit()
                guard seamPhase == 6, !diagnosticWriting, ordinaryWrites <= 2, reservedWrites <= 2,
                      tasks[id] != nil, ordinary.contains(id) || reserved.contains(id) else { throw FixtureContextFailure.wrongPhase }
                return (6, id)
            case .controllerHello, .controllerRequest:
                throw FixtureContextFailure.wrongPhase
            case .diagnostic:
                try requireSeamCommit()
                guard seamPhase == 6, diagnosticWriting, ordinaryWrites + reservedWrites < 4 else { throw FixtureContextFailure.wrongPhase }
                return (6, nil)
            }
        }
        let (phase, id) = try checkState()
        try await fixtureCheck("queue-attempt", phase: phase, deadline: admission.deadline, requestID: id)
        guard fixtureWriterBinding === binding, binding.server === self, binding.context === fixtureContext else { throw FixtureContextFailure.wrongPhase }
        _ = try checkState()
        guard DispatchTime.now().uptimeNanoseconds < admission.cutoff else { throw HarnessError.deadline }
    }
    private func handlerCheck(_ label: String, id: UUID, deadline: FrameDeadline? = nil) async -> Bool {
        do {
            try await fixtureCheck(label, phase: 6, deadline: deadline, requestID: id)
            if fixtureContext != nil {
                try requireSeamCommit()
                guard !diagnosticWriting, ordinaryWrites <= 2, reservedWrites <= 2,
                      tasks[id] != nil, ordinary.contains(id) || reserved.contains(id) else { throw FixtureContextFailure.wrongPhase }
            }
            return true
        }
        catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            switch label {
            case "handler-before": hoverFailure("server.handler_before_failure", boundServerError(error))
            case "handler-after": hoverFailure("server.handler_after_failure", boundServerError(error))
            case "write-before": hoverFailure("server.write_before_failure", boundServerError(error))
            case "write-after": hoverFailure("server.write_after_failure", boundServerError(error))
            case "enqueue": hoverFailure("server.enqueue_failure", boundServerError(error))
            default: break
            }
            #endif
            stop(); return false
        }
    }
    // A bound EOF is normal only if no revocation, terminal failure or cancellation
    // has already won. Unbound v1 retains its original EOF behavior.
    private func requestLoopEOFStatus() -> Int32 {
        guard let context = fixtureContext else { return 0 }
        guard !stopped, !Task.isCancelled, channel.isLocallyOpen(), fixtureFailure == nil else { return 1 }
        do { try context.revocation.check(); return 0 } catch { return 1 }
    }
    private func requestLoop(receive: @escaping @Sendable () async throws -> Data?, checkDisconnect: Bool) async throws -> Int32 {
                while !Task.isCancelled && !stopped {
                    do { try await fixtureCheck("receive-before", phase: 6) }
                    catch {
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        hoverFailure("server.receive_before_failure", boundServerError(error))
                        #endif
                        throw error
                    }
                    let frame: Data
                    do {
                        guard let received = try await AutomationChannelDeadline.run(channel: channel, seconds: idleSeconds, operation: { try await receive() }) else {
                            #if SAFARIER_BOUND_LOCAL_CANDIDATE
                            hoverFailure("server.read_eof", "eof")
                            #endif
                            return requestLoopEOFStatus()
                        }
                        frame = received
                    } catch {
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        hoverFailure("server.read_failure", boundServerError(error))
                        #endif
                        throw error
                    }
                    do { try await fixtureCheck("receive-after", phase: 6) }
                    catch {
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        hoverFailure("server.receive_after_failure", boundServerError(error))
                        #endif
                        throw error
                    }
                    if checkDisconnect { if try channel.observedDisconnect() { return 1 } }
                    let request: AutomationRequest
                    do { request = try AutomationCodec.decode(frame) }
                    catch {
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        hoverFailure("server.decode_failure", boundServerError(error))
                        #endif
                        // Preserve the original fixed malformed-frame diagnostic, then
                        // close this owned channel. Handshake failures remain silent.
                        await sendMalformedDiagnosticIfCapacity()
                        return 1
                    }
                    NavigationDiagnostic.emit(request, "runner.decoded")
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    let hoverIsMove: Bool
                    if case .move = request.action {
                        hoverIsMove = true; hoverMoveIDs.insert(request.requestID)
                        hoverCoreTrace("server.move_decoded")
                    } else { hoverIsMove = false }
                    #endif
                    try await fixtureCheck("admission", phase: 6)
                    if checkDisconnect { try requireSeamCommit() }
                    guard !stopped, tasks[request.requestID] == nil else { throw AutomationError(code: .invalidRequest) }
                    let isReserved: Bool
                    switch request.action { case .cancel, .closeSession, .releaseControl, .commitControlRelease: isReserved = true; default: isReserved = false }
                    guard isReserved ? reserved.count < reservedLimit : ordinary.count < maxOrdinaryRequests else { throw AutomationError(code: .sessionBusy) }
                    if isReserved { reserved.insert(request.requestID) } else { ordinary.insert(request.requestID) }
                    let handler = self.handler, cutoff = checkDisconnect ? seamLifetimeEnd : nil, ownedChannel = channel
                    let task = Task.detached { [weak self] in
                        if let cutoff { guard (try? ownedChannel.requireOpen(before: cutoff)) != nil, !Task.isCancelled else { await self?.seamExpired(); return } }
                        guard await self?.handlerCheck("handler-before", id: request.requestID) == true else { return }
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        if hoverIsMove { hoverCoreTrace("server.move_handler_before") }
                        #endif
                        let outcome = await handler(request)
                        NavigationDiagnostic.emit(request, "runner.handler.return", NavigationDiagnostic.result(outcome))
                        #if SAFARIER_BOUND_LOCAL_CANDIDATE
                        if hoverIsMove {
                            if case .failure(let error) = outcome { hoverCoreTrace("server.move_handler_after", error.code.rawValue) }
                            else { hoverCoreTrace("server.move_handler_after") }
                        }
                        #endif
                        guard !Task.isCancelled else { return }
                        guard await self?.handlerCheck("handler-after", id: request.requestID) == true else { return }
                        if let cutoff { guard (try? ownedChannel.requireOpen(before: cutoff)) != nil else { await self?.seamExpired(); return } }
                        await self?.sendOutcome(outcome, request: request)
                    }
                    tasks[request.requestID] = task
                }
                return requestLoopEOFStatus()
    }
    private func requireSeamCommit() throws {
        guard !stopped, seamPhase == 6, let end = seamLifetimeEnd else { throw V1SeamError.invalidPhase }
        try channel.requireOpen(before: end)
        if try channel.observedDisconnect() { throw V1SeamError.disconnected }
    }
    private func sendMalformedDiagnosticIfCapacity() async {
        do { try await fixtureCheck("diagnostic-before", phase: 6) } catch { stop(); return }
        if seamLifetimeEnd != nil { do { try requireSeamCommit() } catch { stop(); return } }
        guard !stopped, !diagnosticWriting else { return }
        // Stay in terminal state until serve() closes the channel; late handlers
        // cannot enqueue replies while the diagnostic is in flight.
        diagnosticWriting = true
        guard ordinaryWrites + reservedWrites < 4 else { return }
        guard let bytes = try? AutomationCodec.encode(AutomationReply(requestID: nil, outcome: .failure(AutomationError(code: .invalidRequest)))) else { return }
        // No extra queued writes: a saturated writer budget fails closed immediately.
        let cutoff = seamLifetimeEnd
        do {
            let admission: SealedWriteAdmission?
            if let context = fixtureContext {
                let deadline = try FrameDeadline(lifetimeStart: context.lifetimeStart)
                admission = try mintWrite(bytes, deadline: deadline, cap: min(idleSeconds, 2), kind: .diagnostic)
            } else { admission = nil }
            try await fixtureCheck("diagnostic-presend", phase: 6, deadline: admission?.deadline)
            if let admission, DispatchTime.now().uptimeNanoseconds >= admission.cutoff { throw HarnessError.deadline }
            guard !stopped, diagnosticWriting, ordinaryWrites + reservedWrites < 4 else { stop(); return }
            if let admission {
                try await channel.sendBound(admission)
            } else {
                try await AutomationChannelDeadline.run(channel: channel, seconds: min(idleSeconds, 2)) {
                    if let cutoff { try await self.channel.sendLeased(bytes, expiresAt: cutoff) }
                    else { try await self.channel.send(bytes) }
                }
            }
            try await fixtureCheck("diagnostic-after", phase: 6)
        } catch { stop() }
    }
    private func sendOutcome(_ outcome: AutomationOutcome, request: AutomationRequest) async {
        let requestID = request.requestID
        guard await handlerCheck("enqueue", id: requestID) else { return }
        if seamLifetimeEnd != nil { do { try requireSeamCommit() } catch { stop(); return } }
        guard !stopped, !diagnosticWriting, tasks[requestID] != nil else { return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        var hoverOutcomePhase = "server.encode_failure"
        #endif
        do {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let hoverIsMove = hoverMoveIDs.contains(requestID)
            if hoverIsMove { hoverCoreTrace("server.move_encode_before") }
            #endif
            let bytes = try AutomationCodec.encode(AutomationReply(requestID: requestID, outcome: outcome))
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if hoverIsMove { hoverCoreTrace("server.move_encode_after") }
            hoverOutcomePhase = "server.mint_failure"
            #endif
            let admission: SealedWriteAdmission?
            if let context = fixtureContext {
                let deadline = try FrameDeadline(lifetimeStart: context.lifetimeStart)
                admission = try mintWrite(bytes, deadline: deadline, cap: idleSeconds, kind: .response(requestID))
            } else { admission = nil }
            NavigationDiagnostic.emit(request, "runner.reply.queued", NavigationDiagnostic.result(outcome))
            queuedWrites.append(QueuedWrite(id: requestID, bytes: bytes, reserved: reserved.contains(requestID), admission: admission))
            scheduleWrites()
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            hoverFailure(hoverOutcomePhase, boundServerError(error))
            #endif
            stop()
        }
    }
    private func scheduleWrites() {
        guard !stopped, !diagnosticWriting else { return }
        while let index = queuedWrites.firstIndex(where: { $0.reserved && reservedWrites < 2 }) ?? queuedWrites.firstIndex(where: { !$0.reserved && ordinaryWrites < 2 }) {
            let write = queuedWrites.remove(at: index)
            if write.reserved { reservedWrites += 1 } else { ordinaryWrites += 1 }
            let channel = self.channel, timeout = idleSeconds, cutoff = seamLifetimeEnd
            let admission = write.admission
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let hoverIsMove = hoverMoveIDs.contains(write.id)
            #endif
            tasks[write.id] = Task.detached { [weak self] in
                do {
                    guard await self?.handlerCheck("write-before", id: write.id, deadline: admission?.deadline) == true else { return }
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    if hoverIsMove { hoverCoreTrace("server.move_write_before") }
                    #endif
                    if let admission {
                        try await channel.sendBound(admission)
                    } else {
                        try await AutomationChannelDeadline.run(channel: channel, seconds: timeout) {
                            if let cutoff { try await channel.sendLeased(write.bytes, expiresAt: cutoff) }
                            else { try await channel.send(write.bytes) }
                        }
                    }
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    if hoverIsMove { hoverCoreTrace("server.move_write_after") }
                    #endif
                    guard await self?.handlerCheck("write-after", id: write.id, deadline: admission?.deadline) == true else { return }
                    await self?.writeFinished(write, success: true)
                } catch {
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    await self?.writeFinished(write, success: false, failureCode: boundServerError(error))
                    #else
                    await self?.writeFinished(write, success: false)
                    #endif
                }
            }
        }
    }
    private func writeFinished(_ write: QueuedWrite, success: Bool, failureCode: String = "unknown") {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if !success { hoverFailure("server.write_failure", failureCode) }
        #endif
        if seamLifetimeEnd != nil { do { try requireSeamCommit() } catch { stop(); return } }
        guard !stopped else { return }
        if write.reserved { reservedWrites -= 1 } else { ordinaryWrites -= 1 }
        guard success else { stop(); return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        hoverMoveIDs.remove(write.id)
        #endif
        tasks.removeValue(forKey: write.id)
        ordinary.remove(write.id); reserved.remove(write.id)
        scheduleWrites()
    }
}

// Phase tokens only serialize v1 wire consumption. They do not authenticate a peer.
enum V1SeamError: Error { case invalidPhase, foreignToken, eof, disconnected }
private final class V1TokenGuard: @unchecked Sendable {
    let channel: AutomationChannel
    private let lock = NSLock()
    private var live = true
    private var deadlineTimer: DispatchSourceTimer?
    private var monitorTimer: DispatchSourceTimer?
    private let onExpire: @Sendable () -> Void
    init(channel: AutomationChannel, deadline: FrameDeadline, onExpire: @escaping @Sendable () -> Void) throws {
        self.channel = channel; self.onExpire = onExpire
        let expiration = try deadline.expiry()
        let deadlineTimer = DispatchSource.makeTimerSource(queue: .global())
        let monitorTimer = DispatchSource.makeTimerSource(queue: .global())
        self.deadlineTimer = deadlineTimer; self.monitorTimer = monitorTimer
        deadlineTimer.schedule(deadline: expiration)
        deadlineTimer.setEventHandler { [weak self] in self?.expire() }
        monitorTimer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        monitorTimer.setEventHandler { [weak self] in self?.monitor() }
        deadlineTimer.resume(); monitorTimer.resume()
    }
    private func monitor() {
        lock.lock(); let active = live; lock.unlock()
        guard active else { return }
        do { if try channel.observedDisconnect() { expire() } }
        catch { expire() }
    }
    private func finish() -> Bool {
        lock.lock()
        guard live else { lock.unlock(); return false }
        live = false
        let deadline = deadlineTimer, monitor = monitorTimer
        deadlineTimer = nil; monitorTimer = nil
        lock.unlock()
        deadline?.cancel(); monitor?.cancel()
        return true
    }
    private func expire() {
        if finish() { channel.close(); onExpire() }
    }
    func consume() -> Bool { finish() }
    func abandon() { expire() }
}

final class PendingV1Handshake: @unchecked Sendable {
    fileprivate let owner: UUID, deadline: FrameDeadline
    fileprivate let challenge: AutomationHandshakeChallenge
    fileprivate let lease: AutomationChannel.ReaderLease
    fileprivate let guardToken: V1TokenGuard
    fileprivate init(owner: UUID, deadline: FrameDeadline, challenge: AutomationHandshakeChallenge, lease: AutomationChannel.ReaderLease, channel: AutomationChannel, onExpire: @escaping @Sendable () -> Void) throws {
        self.owner = owner; self.deadline = deadline; self.challenge = challenge; self.lease = lease
        self.guardToken = try V1TokenGuard(channel: channel, deadline: deadline, onExpire: onExpire)
    }
    func close() { guardToken.abandon() }
    deinit { guardToken.abandon() }
}
final class V1Handoff: @unchecked Sendable {
    fileprivate let owner: UUID, deadline: FrameDeadline
    fileprivate let lease: AutomationChannel.ReaderLease
    fileprivate let guardToken: V1TokenGuard
    fileprivate init(owner: UUID, deadline: FrameDeadline, lease: AutomationChannel.ReaderLease, channel: AutomationChannel, onExpire: @escaping @Sendable () -> Void) throws {
        self.owner = owner; self.deadline = deadline; self.lease = lease
        self.guardToken = try V1TokenGuard(channel: channel, deadline: deadline, onExpire: onExpire)
    }
    func close() { guardToken.abandon() }
    deinit { guardToken.abandon() }
}
extension AutomationRunnerServer {
    private func seamExpired() { stop() }
    func beginV1Handshake(deadline: FrameDeadline) async throws -> PendingV1Handshake {
        let revocation = fixtureContext?.revocation
        return try await withTaskCancellationHandler(operation: { try await beginV1HandshakeImpl(deadline: deadline) }, onCancel: { revocation?.revoke() })
    }
    private func beginV1HandshakeImpl(deadline: FrameDeadline) async throws -> PendingV1Handshake {
        do {
            guard !started, !stopped, (!fixtureInstallAttempted || fixtureInstalled), Self.validTimeout(idleSeconds), (1...32).contains(maxOrdinaryRequests) else { throw V1SeamError.invalidPhase }
            started = true; seamPhase = 1
            let lease = try channel.claimExclusiveReader()
            if let context = fixtureContext {
                let binding = FixtureWriterBinding(server: self, context: context, reader: lease)
                try channel.installFixtureWriter(binding)
                fixtureWriterBinding = binding
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= deadline.lifetimeStart, now - deadline.lifetimeStart < UInt64(AutomationLimits.generationSeconds * 1_000_000_000) else { throw HarnessError.deadline }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            let (lifeEnd, overflow) = deadline.lifetimeStart.addingReportingOverflow(UInt64(AutomationLimits.generationSeconds * 1_000_000_000))
            guard !overflow else { throw HarnessError.invalidClock }
            seamLifetimeEnd = lifeEnd
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: lifeEnd))
            let ownedChannel = channel, revocation = fixtureContext?.revocation
            timer.setEventHandler { [weak self] in
                revocation?.revoke(); ownedChannel.close()
                Task { await self?.seamExpired() }
            }
            seamLifetimeTimer = timer; timer.resume()
            // Installation already made pre-hello checks; peer last-use cannot be asserted yet.
            guard let hello = try await deadline.run(channel: channel, operation: { try await lease.receive() }) else { throw V1SeamError.eof }
            guard seamPhase == 1, !stopped else { throw V1SeamError.invalidPhase }
            let challenge = try AutomationHandshakeCodec.readChallenge(hello, expectedProfileID: profileID)
            if let expected = fixtureContext?.registrationNonce {
                guard challenge.nonce.utf8.elementsEqual(expected.utf8) else { throw V1SeamError.invalidPhase }
            }
            try await fixtureCheck("hello-peer", phase: 1, deadline: deadline, establishPeer: true)
            try Task.checkCancellation(); _ = try deadline.remaining()
            guard seamPhase == 1, !stopped else { throw V1SeamError.invalidPhase }
            let tokenRevocation = fixtureContext?.revocation
            let token = try PendingV1Handshake(owner: seamID, deadline: deadline, challenge: challenge, lease: lease, channel: channel, onExpire: { [weak self] in tokenRevocation?.revoke(); Task { await self?.seamExpired() } })
            try Task.checkCancellation(); _ = try deadline.remaining()
            guard seamPhase == 1, !stopped else { throw V1SeamError.invalidPhase }
            seamPhase = 2; return token
        } catch { stop(); throw error }
    }
    func sendV1Ready(_ pending: PendingV1Handshake, deadline: FrameDeadline) async throws -> V1Handoff {
        guard pending.owner == seamID else { stop(); throw V1SeamError.foreignToken }
        let revocation = fixtureContext?.revocation
        return try await withTaskCancellationHandler(operation: { try await sendV1ReadyImpl(pending, deadline: deadline) }, onCancel: { revocation?.revoke() })
    }
    private func sendV1ReadyImpl(_ pending: PendingV1Handshake, deadline: FrameDeadline) async throws -> V1Handoff {
        do {
            guard seamPhase == 2, !stopped, pending.deadline.frameStart == deadline.frameStart, pending.deadline.lifetimeStart == deadline.lifetimeStart, pending.guardToken.consume() else { throw V1SeamError.invalidPhase }
            seamPhase = 3
            try await fixtureCheck("ready-before", phase: 3, deadline: deadline)
            let response = try AutomationHandshakeCodec.makeResponse(pending.challenge, runnerInstanceID: runnerInstanceID, runnerPID: getpid())
            if fixtureWriterBinding != nil {
                let admission = try mintWrite(response, deadline: deadline, cap: nil, kind: .ready)
                try await channel.sendBound(admission)
            } else {
                try await deadline.run(channel: channel) { try await self.channel.send(response) }
            }
            guard seamPhase == 3, !stopped else { throw V1SeamError.invalidPhase }
            try await fixtureCheck("ready-after", phase: 3, deadline: deadline)
            try Task.checkCancellation(); _ = try deadline.remaining()
            guard seamPhase == 3, !stopped else { throw V1SeamError.invalidPhase }
            let tokenRevocation = fixtureContext?.revocation
            let handoff = try V1Handoff(owner: seamID, deadline: deadline, lease: pending.lease, channel: channel, onExpire: { [weak self] in tokenRevocation?.revoke(); Task { await self?.seamExpired() } })
            try Task.checkCancellation(); _ = try deadline.remaining()
            guard seamPhase == 3, !stopped else { throw V1SeamError.invalidPhase }
            seamPhase = 4; return handoff
        } catch { stop(); throw error }
    }
    func serveV1Handoff(_ handoff: V1Handoff, prepare: @escaping @Sendable () async throws -> Void) async -> Int32 {
        guard handoff.owner == seamID else { stop(); return 1 }
        let revocation = fixtureContext?.revocation
        return await withTaskCancellationHandler(operation: { await serveV1HandoffImpl(handoff, prepare: prepare) }, onCancel: { revocation?.revoke() })
    }
    private func serveV1HandoffImpl(_ handoff: V1Handoff, prepare: @escaping @Sendable () async throws -> Void) async -> Int32 {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        let diagnosticEnabled = fixtureContext != nil
        var diagnosticPhase = "handoff.guard.before"
        if diagnosticEnabled { boundServerTrace(diagnosticPhase, diagnosticStart) }
        #endif
        do {
            guard seamPhase == 4, !stopped, handoff.guardToken.consume() else { throw V1SeamError.invalidPhase }
            seamPhase = 5
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "handoff.prepare_check.before"
            if diagnosticEnabled { boundServerTrace(diagnosticPhase, diagnosticStart) }
            #endif
            try await fixtureCheck("prepare-before", phase: 5, deadline: handoff.deadline)
            try Task.checkCancellation(); _ = try handoff.deadline.remaining()
            if try channel.observedDisconnect() { throw V1SeamError.disconnected }
            let completion = V1PreparationCompletion()
            seamPreparation = completion
            let monitor = DispatchSource.makeTimerSource(queue: .global())
            let owned = channel, revocation = fixtureContext?.revocation
            monitor.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
            monitor.setEventHandler { [weak self] in
                do {
                    if try owned.observedDisconnect() {
                        revocation?.revoke(); owned.close(); completion.cancel(); Task { await self?.seamExpired() }
                    }
                } catch { revocation?.revoke(); owned.close(); completion.cancel(); Task { await self?.seamExpired() } }
            }
            seamPreparationTimer = monitor; monitor.resume()
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "handoff.prepare_callback.before"
            if diagnosticEnabled { boundServerTrace(diagnosticPhase, diagnosticStart) }
            #endif
            try await handoff.deadline.run(channel: channel) { try await completion.run(prepare) }
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "handoff.prepare_callback.after"
            if diagnosticEnabled { boundServerTrace(diagnosticPhase, diagnosticStart) }
            #endif
            seamPreparationTimer?.cancel(); seamPreparationTimer = nil; seamPreparation = nil
            guard seamPhase == 5, !stopped else { throw V1SeamError.invalidPhase }
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "handoff.prepare_check.after_before"
            #endif
            try await fixtureCheck("prepare-after", phase: 5, deadline: handoff.deadline)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "handoff.prepare_check.after"
            if diagnosticEnabled { boundServerTrace(diagnosticPhase, diagnosticStart) }
            #endif
            try Task.checkCancellation()
            if try channel.observedDisconnect() { throw V1SeamError.disconnected }
            seamPhase = 6
            let result = try await withTaskCancellationHandler(operation: {
                try await self.requestLoop(receive: { try await handoff.lease.receive() }, checkDisconnect: true)
            }, onCancel: { revocation?.revoke(); self.channel.close() })
            stop(); return result
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if diagnosticEnabled { boundServerTrace(diagnosticPhase, diagnosticStart, boundServerError(error)) }
            #endif
            stop(); return 1
        }
    }
}

// Based on freeze-040 FullHarness one-shot profile-read completion. Only this
// box and the callback can survive timeout; no server or authority is retained.
private final class V1PreparationCompletion: @unchecked Sendable {
 private let lock = NSLock()
 private var continuation: CheckedContinuation<Void, Error>?
 private var result: Result<Void, Error>?
 private var worker: Task<Void, Never>?
 private func install(_ c: CheckedContinuation<Void, Error>) -> Bool {
  lock.lock(); if let result { lock.unlock(); c.resume(with: result); return false }
  continuation = c; lock.unlock(); return true
 }
 private func attach(_ task: Task<Void, Never>) {
  lock.lock(); let finished = result != nil; if !finished { worker = task }; lock.unlock()
  if finished { task.cancel() }
 }
 private func resolve(_ value: Result<Void, Error>) {
  lock.lock(); guard result == nil else { lock.unlock(); return }
  result = value; let c = continuation; continuation = nil; worker = nil; lock.unlock()
  c?.resume(with: value)
 }
 func cancel() {
  lock.lock(); guard result == nil else { lock.unlock(); return }
  result = .failure(CancellationError()); let c = continuation, task = worker
  continuation = nil; worker = nil; lock.unlock()
  task?.cancel(); c?.resume(throwing: CancellationError())
 }
 func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
  try await withTaskCancellationHandler(operation: {
   try await withCheckedThrowingContinuation { c in
    guard install(c) else { return }
    let task = Task { [self] in
     do { try Task.checkCancellation(); try await operation(); resolve(.success(())) }
     catch { resolve(.failure(error)) }
    }
    attach(task)
   }
  }, onCancel: { self.cancel() })
 }
}

// Staged fixture-only retained context; not a production grant.
private final class FixtureRevocation: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private var firstError: Error?
    private var firstDiagnostic: String?
    private let channel: AutomationChannel
    init(channel: AutomationChannel) { self.channel = channel }
    func revoke(fileID: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) { lock.lock(); revoked = true; channel.close(fileID: fileID, line: line, function: function); lock.unlock() }
    func fail(_ error: Error, diagnostic: String, fileID: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        lock.lock()
        if !revoked { firstError = error; firstDiagnostic = diagnostic }
        revoked = true
        channel.close(fileID: fileID, line: line, function: function)
        lock.unlock()
    }
    func diagnostic() -> String? { lock.lock(); defer { lock.unlock() }; return firstDiagnostic }
    func check() throws { lock.lock(); defer { lock.unlock() }; if revoked { throw firstError ?? FixtureContextFailure.revoked } }
}
private enum FixtureContextFailure: Error { case revoked, wrongChannel, wrongPhase, wrongProfile, lifetime, noPeer, peerAlreadyPinned }
// Closed enum mapping without widening the private error type or rendering Error.
func fixtureContextFailureDiagnostic(_ error: Error) -> String? {
    guard let error = error as? FixtureContextFailure else { return nil }
    switch error {
    case .revoked: return "fixture_revoked"
    case .wrongChannel: return "fixture_wrongChannel"
    case .wrongPhase: return "fixture_wrongPhase"
    case .wrongProfile: return "fixture_wrongProfile"
    case .lifetime: return "fixture_lifetime"
    case .noPeer: return "fixture_noPeer"
    case .peerAlreadyPinned: return "fixture_peerAlreadyPinned"
    }
}
private actor FixtureContext {
    nonisolated let revocation: FixtureRevocation
    nonisolated let channel: AutomationChannel
    nonisolated let lifetimeStart: UInt64
    nonisolated let registrationNonce: String?
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    nonisolated let registeredInteractive: Bool
    #endif
    private let bridge: KernelIdentityBridge
    private let parent: BIProcess
    private let provider: RepositoryBindingProvider
    private let inspector: FileHandle
    private var peerPinned = false
    private var released = false
    private var releaseTask: Task<Void, Never>?
    fileprivate init(channel: AutomationChannel, lifetimeStart: UInt64, bridge: KernelIdentityBridge, parent: BIProcess, provider: RepositoryBindingProvider, inspector: FileHandle, registeredInteractive: Bool = false, registrationNonce: String? = nil) {
        self.channel = channel; self.lifetimeStart = lifetimeStart; self.bridge = bridge
        self.registrationNonce = registrationNonce
        self.parent = parent; self.provider = provider; self.inspector = inspector
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        self.registeredInteractive = registeredInteractive
        #endif
        self.revocation = FixtureRevocation(channel: channel)
    }
    func check(deadline: FrameDeadline, establishPeer: Bool, requirePeer: Bool, expectedProfile: Profile? = nil, expectedPreparation: RunnerPreparationPlan? = nil, trace: BinderValidationTrace? = nil) async throws {
        defer { trace?.failureIfPending() }
        trace?.begin(.initial)
        try revocation.check(); try Task.checkCancellation()
        guard !released, deadline.lifetimeStart == lifetimeStart else { throw FixtureContextFailure.lifetime }
        _ = try deadline.remaining(); try channel.requireOpen(before: deadline.cutoffNanoseconds())
        trace?.success(); trace?.begin(.selfIdentity)
        try bridge.checkSelf(deadline: deadline)
        trace?.success(); trace?.begin(.resources)
        try bridge.checkResources(deadline: deadline)
        trace?.success(); trace?.begin(.parentFirst)
        try bridge.checkActualParent(parent, deadline: deadline)
        trace?.success()
        if establishPeer && peerPinned { throw FixtureContextFailure.peerAlreadyPinned }
        if establishPeer || peerPinned {
            trace?.begin(.peer)
            try bridge.checkPeer(fd: inspector.fileDescriptor, expected: parent, deadline: deadline)
            trace?.success(); trace?.begin(.parentSecond)
            try bridge.checkActualParent(parent, deadline: deadline)
            trace?.success()
            if establishPeer { peerPinned = true }
        } else if requirePeer { throw FixtureContextFailure.noPeer }
        let ms = min(2999, Int((try deadline.remaining() * 1000).rounded(.down)))
        guard ms > 0 else { throw HarnessError.deadline }
        let cDeadline = bi_deadline_after_ms(UInt32(ms))
        guard cDeadline != 0 else { throw HarnessError.deadline }
        trace?.begin(.repository)
        let observed = try await provider.read(deadline: cDeadline)
        trace?.success(); trace?.begin(.final)
        if let expectedProfile, observed.profile != expectedProfile { throw FixtureContextFailure.wrongProfile }
        if let plan = expectedPreparation {
            guard observed.profile == plan.profile, observed.spec == plan.spec, observed.proxy == plan.proxy,
                  observed.subscription == plan.boundNode?.subscription, observed.node == plan.boundNode?.node else { throw FixtureContextFailure.wrongProfile }
        }
        try revocation.check(); try Task.checkCancellation(); _ = try deadline.remaining()
        guard !released else { throw FixtureContextFailure.revoked }
        try channel.requireOpen(before: deadline.cutoffNanoseconds())
        trace?.success()
    }
    func release() async {
        if let releaseTask { await releaseTask.value; return }
        released = true
        let provider = self.provider, inspector = self.inspector
        let task = Task { await provider.release(); try? inspector.close() }
        releaseTask = task
        await task.value
    }
}
extension AutomationRunnerServer {
    // Staged fixture only; no product authorization.
    private func installFixtureContext(workspace: SafarierWorkspace, originalLock: ProfileLock, expectedSpec: RunnerLaunchSpec, actualArgs: [String], environment: [String:String], deadline: FrameDeadline, registrationNonce: String? = nil) async throws {
        try await withTaskCancellationHandler(operation: {
            try await installFixtureContextImpl(workspace: workspace, originalLock: originalLock, expectedSpec: expectedSpec, actualArgs: actualArgs, environment: environment, deadline: deadline, registrationNonce: registrationNonce)
        }, onCancel: { channel.close(origin: .cancellation) })
    }
    private func installFixtureContextImpl(workspace: SafarierWorkspace, originalLock: ProfileLock, expectedSpec: RunnerLaunchSpec, actualArgs: [String], environment: [String:String], deadline: FrameDeadline, registrationNonce: String?) async throws {
        guard !started, !stopped, seamPhase == 0, !fixtureInstallAttempted else { stop(); throw FixtureContextFailure.wrongPhase }
        fixtureInstallAttempted = true
        var inspector: FileHandle?
        do {
            guard expectedSpec.profileID == profileID else { throw FixtureContextFailure.wrongProfile }
            let acquiredInspector = try channel.duplicateInspector()
            inspector = acquiredInspector
            let bridge = try KernelIdentityBridge(deadline: deadline)
            guard bridge.role == .runner else { throw IdentityBridgeError.rejected }
            let parent = try bridge.actualParentMetadata(deadline: deadline)
            let provider = try RepositoryBindingProvider.create(workspace: workspace, role: .runner, expectedSpec: expectedSpec, actualArgs: actualArgs, environment: environment, originalLock: originalLock)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let registered = expectedSpec.registeredInteractive
            #else
            let registered = false
            #endif
            guard registered == (registrationNonce != nil), registrationNonce.map(AutomationSessionToken.isCanonical) ?? true else { throw FixtureContextFailure.wrongPhase }
            let context = FixtureContext(channel: channel, lifetimeStart: deadline.lifetimeStart, bridge: bridge, parent: parent, provider: provider, inspector: acquiredInspector, registeredInteractive: registered, registrationNonce: registrationNonce)
            fixtureContext = context
            try await withTaskCancellationHandler(operation: {
                try await context.check(deadline: deadline, establishPeer: false, requirePeer: false)
            }, onCancel: { context.revocation.revoke() })
            guard fixtureContext === context, context.channel === channel, !started, !stopped, seamPhase == 0 else { throw FixtureContextFailure.wrongPhase }
            try context.revocation.check()
            guard let loan = provider.lock else { throw FixtureContextFailure.revoked }
            let revocation = context.revocation
            loan.setRevocation { revocation.revoke() }
            guard loan.check() else { throw FixtureContextFailure.revoked }
            try revocation.check()
            appContext = RunnerBinderContext(profileID: profileID, runnerInstanceID: runnerInstanceID, context: context, loan: loan, executablePath: bridge.executablePath)
            fixtureInstalled = true
        } catch {
            let context = fixtureContext
            stop()
            if let context { await context.release() }
            else { try? inspector?.close() }
            throw error
        }
    }
}


struct ControllerDeadlineSeal: Sendable {
    let cutoff: UInt64
    fileprivate init(cutoff: UInt64) { self.cutoff = cutoff }
}

actor ControllerGenerationContext {
    nonisolated let executablePath: String
    nonisolated let runnerExecutablePath: String
    nonisolated let channel: AutomationChannel
    nonisolated let reader: AutomationChannel.ReaderLease
    private let inspector: FileHandle
    private let bridge: KernelIdentityBridge
    private let provider: RepositoryBindingProvider
    fileprivate nonisolated let revocation: FixtureRevocation
    nonisolated let lifetimeStart: UInt64
    private let startupCutoff: UInt64
    private let registrationNonce: String?
    private let expectedSpec: RunnerLaunchSpec
    private let actualArgs: [String]
    private let environment: [String: String]
    private var owner: OwnedRunnerProcess?
    private var birth: BIProcess?
    private var attachAttempted = false
    private var closed = false
    private var closeTask: Task<Void, Never>?
    private enum BootstrapPhase { case beforeHello, helloInProgress, ready, clientAttached }
    private var bootstrapPhase: BootstrapPhase = .beforeHello
    private var binding: FixtureWriterBinding?
    private var helloAdmission: SealedWriteAdmission?
    private var readyResponse: AutomationHandshakeResponse?
    private var peerPinned = false
    private weak var client: AutomationRunnerClient?

    private init(channel: AutomationChannel, reader: AutomationChannel.ReaderLease,
                 inspector: FileHandle, bridge: KernelIdentityBridge,
                 provider: RepositoryBindingProvider, lifetimeStart: UInt64,
                 startupCutoff: UInt64, registrationNonce: String?, expectedSpec: RunnerLaunchSpec,
                 actualArgs: [String], environment: [String: String]) {
        self.channel = channel; self.reader = reader; self.inspector = inspector
        self.bridge = bridge; self.executablePath = bridge.executablePath; self.runnerExecutablePath = bridge.runnerExecutablePath; self.provider = provider; self.revocation = FixtureRevocation(channel: channel)
        self.lifetimeStart = lifetimeStart; self.startupCutoff = startupCutoff
        self.registrationNonce = registrationNonce
        self.expectedSpec = expectedSpec; self.actualArgs = actualArgs; self.environment = environment
    }

    static func prepare(channel: AutomationChannel, workspace: SafarierWorkspace, expectedSpec: RunnerLaunchSpec,
                        actualArgs: [String], environment: [String: String],
                        lifetimeStart: UInt64, startupCutoff: UInt64, registrationNonce: String? = nil) async throws -> ControllerGenerationContext {
        enum Stage: String { case deadline, bridge, role, inspector, reader, provider, nonce, beforeSpawn }
        var stage = Stage.deadline
        var inspector: FileHandle?
        var provider: RepositoryBindingProvider?
        do {
            let deadline = try FrameDeadline(lifetimeStart: lifetimeStart, controller: ControllerDeadlineSeal(cutoff: startupCutoff))
            stage = .bridge
            let bridge = try KernelIdentityBridge(deadline: deadline)
            stage = .role
            guard bridge.role == .main else { throw IdentityBridgeError.rejected }
            stage = .inspector
            let retainedInspector = try channel.duplicateInspector(); inspector = retainedInspector
            stage = .reader
            let retainedReader = try channel.claimExclusiveReader()
            stage = .provider
            let retainedProvider = try RepositoryBindingProvider.create(workspace: workspace, role: .controller, expectedSpec: expectedSpec, actualArgs: actualArgs, environment: environment, originalLock: nil)
            provider = retainedProvider
            stage = .nonce
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            guard expectedSpec.registeredInteractive == (registrationNonce != nil), registrationNonce.map(AutomationSessionToken.isCanonical) ?? true else { throw FixtureContextFailure.wrongPhase }
            #else
            guard registrationNonce == nil else { throw FixtureContextFailure.wrongPhase }
            #endif
            let context = ControllerGenerationContext(channel: channel, reader: retainedReader, inspector: retainedInspector, bridge: bridge, provider: retainedProvider, lifetimeStart: lifetimeStart, startupCutoff: startupCutoff, registrationNonce: registrationNonce, expectedSpec: expectedSpec, actualArgs: actualArgs, environment: environment)
            stage = .beforeSpawn
            try await context.checkBeforeSpawn()
            return context
        } catch {
            RootIdentityDiagnostic.emit("CONTROLLER_PREPARE_DIAG stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            channel.close()
            if let provider { await provider.release() }
            try? inspector?.close()
            throw error
        }
    }

    // Concrete client stop uses this same first-terminal record synchronously;
    // the actor task only drains/releases the owned resources afterward.
    nonisolated func stopFromClient(_ code: AutomationErrorCode) {
        let error = AutomationError(code: code)
        revocation.fail(error, diagnostic: "phase=controller-client type=AutomationError error=\(code)")
    }
    nonisolated func revokeFromClientDeinit() { revocation.revoke() }
    private func startupDeadline() throws -> FrameDeadline {
        try FrameDeadline(lifetimeStart: lifetimeStart, controller: ControllerDeadlineSeal(cutoff: startupCutoff))
    }
    private func checkOpen(_ deadline: FrameDeadline) throws {
        try revocation.check(); try Task.checkCancellation()
        guard !closed else { throw FixtureContextFailure.revoked }
        _ = try deadline.remaining()
        try channel.requireOpen(before: deadline.cutoffNanoseconds())
    }
    private func checkRepositoryAndSelf(_ deadline: FrameDeadline) async throws {
        enum Stage: String { case checkOpen, selfCheck, resources, deadline, repository, checkOpenAfter }
        var stage = Stage.checkOpen
        do {
            try checkOpen(deadline)
            stage = .selfCheck
            try bridge.checkSelf(deadline: deadline)
            stage = .resources
            try bridge.checkResources(deadline: deadline)
            stage = .deadline
            let ms = min(2999, Int((try deadline.remaining() * 1000).rounded(.down)))
            guard ms > 0 else { throw HarnessError.deadline }
            let cDeadline = bi_deadline_after_ms(UInt32(ms))
            guard cDeadline != 0 else { throw HarnessError.deadline }
            stage = .repository
            _ = try await provider.read(deadline: cDeadline)
            stage = .checkOpenAfter
            try checkOpen(deadline)
        } catch {
            RootIdentityDiagnostic.emit("CONTROLLER_REPOSITORY_DIAG stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            throw error
        }
    }
    func checkBeforeSpawn() async throws {
        do {
            guard !attachAttempted, owner == nil else { throw FixtureContextFailure.wrongPhase }
            let d = try startupDeadline()
            try await checkRepositoryAndSelf(d)
            guard !attachAttempted, owner == nil else { throw FixtureContextFailure.wrongPhase }
        } catch { revocation.fail(error, diagnostic: "controller-before-spawn"); throw error }
    }
    // Actual original owned-child metadata only; never consumes a wire PID.
    func captureOwnedBirth(_ originalOwner: OwnedRunnerProcess) throws -> BIProcess {
        do {
            guard !attachAttempted, owner == nil else { throw FixtureContextFailure.wrongPhase }
            let d = try startupDeadline(); try checkOpen(d)
            let result = try bridge.ownedChildMetadata(originalOwner, deadline: d)
            try checkOpen(d); return result
        } catch { revocation.fail(error, diagnostic: "controller-capture-birth"); throw error }
    }
    func attachOwnedChildOnce(_ originalOwner: OwnedRunnerProcess, birth originalBirth: BIProcess) async throws {
        do {
            guard !attachAttempted, owner == nil else { throw FixtureContextFailure.wrongPhase }
            attachAttempted = true
            let d = try startupDeadline(); try checkOpen(d)
            let fresh = try bridge.ownedChildMetadata(originalOwner, deadline: d)
            guard KernelIdentityBridge.sameProcessIdentity(originalBirth, fresh) else { throw IdentityBridgeError.rejected }
            owner = originalOwner; birth = originalBirth
            try await checkAfterSpawnImpl(deadline: d)
        } catch { revocation.fail(error, diagnostic: "controller-attach"); throw error }
    }
    func checkAfterSpawn() async throws {
        do { try await checkAfterSpawnImpl(deadline: startupDeadline()) }
        catch { revocation.fail(error, diagnostic: "controller-after-spawn"); throw error }
    }
    private func checkAfterSpawnImpl(deadline d: FrameDeadline) async throws {
        try checkOpen(d)
        guard attachAttempted, let originalOwner = owner, let originalBirth = birth else { throw FixtureContextFailure.wrongPhase }
        let fresh = try bridge.ownedChildMetadata(originalOwner, deadline: d)
        guard KernelIdentityBridge.sameProcessIdentity(originalBirth, fresh) else { throw IdentityBridgeError.rejected }
        let requirePeer = peerPinned
        if requirePeer { try bridge.checkPeer(fd: inspector.fileDescriptor, expected: originalBirth, deadline: d) }
        try await checkRepositoryAndSelf(d)
        try checkOpen(d)
        guard let currentOwner = owner, currentOwner === originalOwner, let currentBirth = birth,
              KernelIdentityBridge.sameProcessIdentity(originalBirth, currentBirth),
              !requirePeer || peerPinned else { throw FixtureContextFailure.wrongPhase }
        let after = try bridge.ownedChildMetadata(originalOwner, deadline: d)
        guard KernelIdentityBridge.sameProcessIdentity(originalBirth, after) else { throw IdentityBridgeError.rejected }
        // A pin established while the provider read was suspended also requires a peer check.
        if peerPinned { try bridge.checkPeer(fd: inspector.fileDescriptor, expected: originalBirth, deadline: d) }
        try checkOpen(d)
    }
    // The one canonical hello is minted here, by the concrete owner, in the
    // same lexical file as the fileprivate admission constructors.
    func negotiateBound(startupCutoff requestedCutoff: UInt64) async throws -> AutomationHandshakeResponse {
        enum Stage: String {
            case guardState, checkOpen, checkAfterSpawnBeforeHello, makeHello, sendHello,
                 receiveReady, parseReady, postReadyCheck, peerCheck, finalCheck
        }
        var stage = Stage.guardState
        do {
            guard requestedCutoff == startupCutoff, bootstrapPhase == .beforeHello,
                  binding == nil, let originalOwner = owner, birth != nil else { throw FixtureContextFailure.wrongPhase }
            stage = .checkOpen
            let d = try FrameDeadline(lifetimeStart: lifetimeStart, controller: ControllerDeadlineSeal(cutoff: requestedCutoff))
            try checkOpen(d); bootstrapPhase = .helloInProgress
            stage = .checkAfterSpawnBeforeHello
            try await checkAfterSpawnImpl(deadline: d)
            guard bootstrapPhase == .helloInProgress, binding == nil else { throw FixtureContextFailure.wrongPhase }
            let newBinding = FixtureWriterBinding(controller: self)
            binding = newBinding
            try channel.installFixtureWriter(newBinding)
            stage = .makeHello
            let nonce = try registrationNonce ?? AutomationSessionToken.generate()
            let hello = try AutomationHandshakeCodec.makeChallenge(profileID: expectedSpec.profileID, nonce: nonce)
            let admission = SealedWriteAdmission(binding: newBinding, frame: hello, deadline: d,
                                                  cutoff: try d.cutoffNanoseconds(), kind: .controllerHello)
            helloAdmission = admission; admission.armDeadline()
            stage = .sendHello
            try await d.run(channel: channel) { try await self.channel.sendBound(admission) }
            try checkOpen(d)
            guard bootstrapPhase == .helloInProgress, binding === newBinding, helloAdmission === admission else { throw FixtureContextFailure.wrongPhase }
            helloAdmission = nil
            stage = .receiveReady
            guard let data = try await d.run(channel: channel, operation: { try await self.reader.receive() }) else { throw AutomationError(code: .runnerExited) }
            try checkOpen(d)
            guard bootstrapPhase == .helloInProgress, binding === newBinding, owner === originalOwner,
                  let originalBirth = birth else { throw FixtureContextFailure.wrongPhase }
            stage = .parseReady
            let response = try AutomationHandshakeCodec.readResponse(data, expectedProfileID: expectedSpec.profileID,
                                                                      expectedNonce: nonce, expectedPID: originalOwner.pid)
            stage = .postReadyCheck
            try await checkAfterSpawnImpl(deadline: d)
            guard bootstrapPhase == .helloInProgress, binding === newBinding else { throw FixtureContextFailure.wrongPhase }
            guard !peerPinned else { throw FixtureContextFailure.peerAlreadyPinned }
            stage = .peerCheck
            try bridge.checkPeer(fd: inspector.fileDescriptor, expected: originalBirth, deadline: d)
            peerPinned = true
            stage = .finalCheck
            try await checkAfterSpawnImpl(deadline: d)
            try checkOpen(d)
            guard bootstrapPhase == .helloInProgress, binding === newBinding, owner === originalOwner else { throw FixtureContextFailure.wrongPhase }
            readyResponse = response; bootstrapPhase = .ready
            return response
        } catch {
            RootIdentityDiagnostic.emit("CONTROLLER_HANDSHAKE_DIAG side=manager stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            revocation.fail(error, diagnostic: "controller-bootstrap"); throw error
        }
    }
    // The bytes and cutoff are read only from the exact attached client's Pending;
    // callers cannot provide an arbitrary frame for the authority factory.
    func mintOwnedRequest(client candidate: AutomationRunnerClient, id: UUID, generation: UUID) async throws -> SealedWriteAdmission? {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        var closeMintPhase = "close.controller.mint_before_begin_failure"
        #endif
        do {
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate,
                  candidate.fixtureContext === self, let binding else { throw FixtureContextFailure.wrongPhase }
            guard let (frame, callerCutoff) = await candidate.beginOwnedRequestMint(context: self, id: id, generation: generation) else {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                hoverCoreTrace("close.controller.begin_nil", "no_longer_live")
                #endif
                return nil
            }
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            closeMintPhase = "close.controller.after_begin_failure"
            #endif
            try revocation.check(); try Task.checkCancellation()
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate, self.binding === binding else { throw FixtureContextFailure.wrongPhase }
            if DispatchTime.now().uptimeNanoseconds >= callerCutoff {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                hoverCoreTrace("close.controller.after_begin_deadline", "deadline")
                #endif
                return nil
            }
            let d = try FrameDeadline(lifetimeStart: lifetimeStart, controller: ControllerDeadlineSeal(cutoff: callerCutoff))
            try checkOpen(d)
            let admission = SealedWriteAdmission(binding: binding, frame: frame, deadline: d,
                                                 cutoff: try d.cutoffNanoseconds(),
                                                 kind: .controllerRequest(id, generation: generation))
            // Do not arm the generation-wide timer until the original client marks attempted.
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            closeMintPhase = "close.controller.install_failure"
            #endif
            do { try await candidate.installOwnedRequestAdmission(context: self, id: id, generation: generation, admission: admission) }
            catch ControllerRequestMintUnavailable.noLongerLive {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                hoverCoreTrace("close.controller.install_no_longer_live", "no_longer_live")
                #endif
                return nil
            }
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            closeMintPhase = "close.controller.after_install_failure"
            #endif
            try revocation.check(); try Task.checkCancellation()
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate, self.binding === binding else { throw FixtureContextFailure.wrongPhase }
            return admission
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            hoverCoreTrace(closeMintPhase, boundServerError(error))
            #endif
            revocation.fail(error, diagnostic: "controller-mint"); throw error
        }
    }
    func armOwnedRequest(client candidate: AutomationRunnerClient, id: UUID, generation: UUID,
                         admission: SealedWriteAdmission) async throws {
        do {
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate,
                  let binding, admission.binding === binding,
                  admission.isOwnedRequest(context: self, id: id, generation: generation) else { throw FixtureContextFailure.wrongPhase }
            try await candidate.checkQueuedPending(context: self, id: id, generation: generation, admission: admission)
            try checkOpen(admission.deadline)
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate, self.binding === binding else { throw FixtureContextFailure.wrongPhase }
            admission.armDeadline()
        } catch { revocation.fail(error, diagnostic: "controller-arm"); throw error }
    }
    func validateOwnedQueuedWrite(_ admission: SealedWriteAdmission) async throws {
        do {
            guard let binding, admission.binding === binding else { throw FixtureContextFailure.wrongPhase }
            switch admission.kind {
            case .controllerHello:
                guard bootstrapPhase == .helloInProgress, helloAdmission === admission else { throw FixtureContextFailure.wrongPhase }
                try await checkAfterSpawnImpl(deadline: admission.deadline)
                try checkOpen(admission.deadline)
                guard bootstrapPhase == .helloInProgress, self.binding === binding, helloAdmission === admission else { throw FixtureContextFailure.wrongPhase }
            case .controllerRequest(let id, let generation):
                guard bootstrapPhase == .clientAttached, peerPinned, let candidate = client else { throw FixtureContextFailure.wrongPhase }
                try await candidate.checkQueuedPending(context: self, id: id, generation: generation, admission: admission)
                guard bootstrapPhase == .clientAttached, peerPinned, client === candidate, self.binding === binding else { throw FixtureContextFailure.wrongPhase }
                try await checkAfterSpawnImpl(deadline: admission.deadline)
                guard bootstrapPhase == .clientAttached, peerPinned, client === candidate, self.binding === binding else { throw FixtureContextFailure.wrongPhase }
                try await candidate.checkQueuedPending(context: self, id: id, generation: generation, admission: admission)
                try checkOpen(admission.deadline)
                guard bootstrapPhase == .clientAttached, peerPinned, client === candidate, self.binding === binding else { throw FixtureContextFailure.wrongPhase }
            default: throw FixtureContextFailure.wrongPhase
            }
            guard DispatchTime.now().uptimeNanoseconds < admission.cutoff else { throw HarnessError.deadline }
        } catch {
            revocation.fail(error, diagnostic: "phase=controller-queue type=\(String(reflecting: type(of: error))) error=\(error)")
            throw error
        }
    }
    nonisolated func checkBackpressureHealth(_ admission: SealedWriteAdmission, id: UUID, generation: UUID) throws {
        guard admission.isOwnedRequest(context: self, id: id, generation: generation) else { throw AutomationChannel.ChannelError.closed }
        try channel.requireOpen(before: admission.cutoff)
        try revocation.check()
        try channel.requireOpen(before: admission.cutoff)
    }
    func validateInbound(client candidate: AutomationRunnerClient, id: UUID, generation: UUID, reply: AutomationReply) async throws {
        do {
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate, candidate.fixtureContext === self else { throw FixtureContextFailure.wrongPhase }
            let cutoff = try await candidate.inboundPendingDeadline(context: self, id: id, generation: generation, reply: reply)
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate else { throw FixtureContextFailure.wrongPhase }
            let d = try FrameDeadline(lifetimeStart: lifetimeStart, controller: ControllerDeadlineSeal(cutoff: cutoff))
            try await checkAfterSpawnImpl(deadline: d)
            guard bootstrapPhase == .clientAttached, peerPinned, client === candidate else { throw FixtureContextFailure.wrongPhase }
            let freshCutoff = try await candidate.inboundPendingDeadline(context: self, id: id, generation: generation, reply: reply)
            try checkOpen(d)
            guard freshCutoff == cutoff, bootstrapPhase == .clientAttached, peerPinned, client === candidate else { throw FixtureContextFailure.wrongPhase }
        } catch {
            revocation.fail(error, diagnostic: "phase=controller-inbound type=\(String(reflecting: type(of: error))) error=\(error)")
            throw error
        }
    }
    private func requireReady(_ response: AutomationHandshakeResponse, originalOwner: OwnedRunnerProcess) throws {
        guard bootstrapPhase == .ready, peerPinned, readyResponse == response,
              let currentOwner = owner, currentOwner === originalOwner,
              originalOwner.pid == response.runnerPID else { throw FixtureContextFailure.wrongPhase }
    }
    func clientParameters(for response: AutomationHandshakeResponse) async throws -> (OwnedRunnerProcess, UUID, AutomationChannel) {
        do {
            let d = try startupDeadline(); try checkOpen(d)
            guard let originalOwner = owner else { throw FixtureContextFailure.wrongPhase }
            try requireReady(response, originalOwner: originalOwner)
            try await checkAfterSpawnImpl(deadline: d)
            try checkOpen(d); try requireReady(response, originalOwner: originalOwner)
            return (originalOwner, expectedSpec.profileID, channel)
        } catch { revocation.fail(error, diagnostic: "controller-client-parameters"); throw error }
    }
    private func requireCandidate(_ candidate: AutomationRunnerClient, response: AutomationHandshakeResponse,
                                  originalOwner: OwnedRunnerProcess) throws {
        guard candidate.fixtureContext === self, candidate.ownershipID == originalOwner.ownershipID,
              candidate.pid == originalOwner.pid, candidate.runnerInstanceID == response.runnerInstanceID else { throw FixtureContextFailure.wrongPhase }
    }
    func attachClientOnce(_ candidate: AutomationRunnerClient, response: AutomationHandshakeResponse) async throws -> AutomationChannel.ReaderLease {
        do {
            let d = try startupDeadline(); try checkOpen(d)
            guard let originalOwner = owner, client == nil else { throw FixtureContextFailure.wrongPhase }
            try requireReady(response, originalOwner: originalOwner)
            try requireCandidate(candidate, response: response, originalOwner: originalOwner)
            try await checkAfterSpawnImpl(deadline: d)
            try checkOpen(d); try requireReady(response, originalOwner: originalOwner)
            try requireCandidate(candidate, response: response, originalOwner: originalOwner)
            guard client == nil else { throw FixtureContextFailure.wrongPhase }
            client = candidate; bootstrapPhase = .clientAttached
            return reader
        } catch { revocation.fail(error, diagnostic: "controller-client-attach"); throw error }
    }
    func validateAttachedClient(_ candidate: AutomationRunnerClient, response: AutomationHandshakeResponse) async throws {
        do {
            let d = try startupDeadline(); try checkOpen(d)
            guard bootstrapPhase == .clientAttached, peerPinned, readyResponse == response,
                  client === candidate, let originalOwner = owner else { throw FixtureContextFailure.wrongPhase }
            try requireCandidate(candidate, response: response, originalOwner: originalOwner)
            try await checkAfterSpawnImpl(deadline: d)
            try checkOpen(d)
            guard bootstrapPhase == .clientAttached, peerPinned, readyResponse == response,
                  client === candidate, owner === originalOwner else { throw FixtureContextFailure.wrongPhase }
            try requireCandidate(candidate, response: response, originalOwner: originalOwner)
        } catch { revocation.fail(error, diagnostic: "controller-client-delivery"); throw error }
    }
    func safeClose() async {
        if let closeTask { await closeTask.value; return }
        closed = true; revocation.revoke()
        let provider = self.provider, inspector = self.inspector
        let task = Task { await provider.release(); try? inspector.close() }
        closeTask = task; await task.value
    }
}

/// Opaque binding to the one authenticated Runner and its originally held lock.
public final class RunnerBinderContext: @unchecked Sendable {
    public let profileID: UUID
    public let runnerInstanceID: UUID
    private let context: FixtureContext
    private let loan: ProfileLock.Lease
    private let fixtureURL: URL
    private let mutex = NSLock()
    private var active = false
    private var closing = false
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var registeredTarget: AutomationTargetIdentity?
    #endif
    fileprivate init(profileID: UUID, runnerInstanceID: UUID, context: FixtureContext, loan: ProfileLock.Lease, executablePath: String) {
        self.profileID = profileID; self.runnerInstanceID = runnerInstanceID
        self.context = context; self.loan = loan
        self.fixtureURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/control-fixture.html")
    }
    fileprivate func activate() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !closing, !active, loan.check() else { throw FixtureContextFailure.revoked }
        try context.revocation.check(); active = true
    }
    public func checkLive() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard active, !closing, loan.check(), context.channel.isLocallyOpen() else { throw FixtureContextFailure.revoked }
        try context.revocation.check()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= context.lifetimeStart, now - context.lifetimeStart < UInt64(AutomationLimits.generationSeconds * 1_000_000_000) else { throw FixtureContextFailure.lifetime }
    }
    public func validate() async throws {
        try checkLive()
        let deadline = try FrameDeadline(lifetimeStart: context.lifetimeStart)
        do { try await context.check(deadline: deadline, establishPeer: false, requirePeer: true); try checkLive() }
        catch { beginClosing(); throw error }
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    public func validatePermissionFirst() async throws { try await validatePermission(checkpoint: .first) }
    public func validatePermissionSecond() async throws { try await validatePermission(checkpoint: .second) }
    private func validatePermission(checkpoint: BinderValidationTrace.Checkpoint) async throws {
        try checkLive()
        let deadline = try FrameDeadline(lifetimeStart: context.lifetimeStart)
        do { try await context.check(deadline: deadline, establishPeer: false, requirePeer: true, trace: BinderValidationTrace(checkpoint: checkpoint)); try checkLive() }
        catch { beginClosing(); throw error }
    }
    #endif
    public func validate(profile: Profile) async throws {
        try checkLive()
        let deadline = try FrameDeadline(lifetimeStart: context.lifetimeStart)
        do { try await context.check(deadline: deadline, establishPeer: false, requirePeer: true, expectedProfile: profile); try checkLive() }
        catch { beginClosing(); throw error }
    }
    public func validate(preparation: RunnerPreparationPlan) async throws {
        try checkLive()
        let deadline = try FrameDeadline(lifetimeStart: context.lifetimeStart)
        do { try await context.check(deadline: deadline, establishPeer: false, requirePeer: true, expectedPreparation: preparation); try checkLive() }
        catch { beginClosing(); throw error }
    }
    public func localFixtureURL() throws -> URL {
        try checkLive()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        guard !context.registeredInteractive else { throw FixtureContextFailure.wrongPhase }
        #endif
        return fixtureURL
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    /// The Runner binds its selected native objects once per authenticated generation.
    /// The application must independently keep and check the actual object references.
    public func sealRegisteredTarget(_ target: AutomationTargetIdentity) throws {
        try checkLive()
        mutex.lock(); defer { mutex.unlock() }
        guard context.registeredInteractive, active, !closing, loan.check(),
              target.profileID == profileID, target.runnerInstanceID == runnerInstanceID,
              registeredTarget == nil else { throw FixtureContextFailure.wrongPhase }
        try context.revocation.check()
        registeredTarget = target
    }
    public func validateRegisteredTarget(_ target: AutomationTargetIdentity) throws {
        try checkLive()
        mutex.lock(); defer { mutex.unlock() }
        guard context.registeredInteractive, active, !closing, loan.check(), registeredTarget == target else {
            throw FixtureContextFailure.wrongProfile
        }
        try context.revocation.check()
    }
    #endif
    public func beginClosing() {
        mutex.lock(); closing = true; active = false; context.revocation.revoke(); mutex.unlock()
    }
    public func finishAfterResourcesDrained() async {
        beginClosing(); await context.release()
    }
}

extension AutomationRunnerServer {
    public func installAppContext(workspace: SafarierWorkspace, spec: RunnerLaunchSpec, originalLock: ProfileLock, arguments: [String], environment: [String:String], registrationEpoch: UUID? = nil) async throws -> RunnerBinderContext {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        boundServerTrace("install_context.before", diagnosticStart)
        #endif
        do {
        let deadline = try FrameDeadline(lifetimeStart: DispatchTime.now().uptimeNanoseconds)
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let nonce = registrationEpoch.map(RegistrationFrame.nonce)
        #else
        guard registrationEpoch == nil else { throw FixtureContextFailure.wrongPhase }
        let nonce: String? = nil
        #endif
        try await installFixtureContext(workspace: workspace, originalLock: originalLock, expectedSpec: spec, actualArgs: arguments, environment: environment, deadline: deadline, registrationNonce: nonce)
        guard let appContext else { throw FixtureContextFailure.revoked }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        boundServerTrace("install_context.after", diagnosticStart)
        #endif
        return appContext
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            boundServerTrace("install_context.failure", diagnosticStart, boundServerError(error))
            #endif
            throw error
        }
    }
    public func serveAppBound(prepare: @escaping @Sendable (RunnerBinderContext) async throws -> Void) async -> Int32 {
        guard let appContext, let fixtureContext else { stop(); return 1 }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticPhase = "app_bound.deadline.before"
        boundServerTrace(diagnosticPhase, diagnosticStart)
        #endif
        do {
            let deadline = try FrameDeadline(lifetimeStart: fixtureContext.lifetimeStart)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "app_bound.hello.before"; boundServerTrace(diagnosticPhase, diagnosticStart)
            #endif
            let pending = try await beginV1Handshake(deadline: deadline)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "app_bound.ready.before"; boundServerTrace(diagnosticPhase, diagnosticStart)
            #endif
            let handoff = try await sendV1Ready(pending, deadline: deadline)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            diagnosticPhase = "app_bound.ready.after"; boundServerTrace(diagnosticPhase, diagnosticStart)
            #endif
            try appContext.activate()
            return await serveV1Handoff(handoff) { try await prepare(appContext) }
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            boundServerTrace(diagnosticPhase, diagnosticStart, boundServerError(error))
            #endif
            appContext.beginClosing(); stop(); return 1
        }
    }
}
