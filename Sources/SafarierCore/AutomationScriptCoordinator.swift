import Foundation
import Darwin
import OSLog

/// Fixed metadata only. Request payloads and arbitrary error text are never logged.
public enum NavigationDiagnostic {
    private static let logger = Logger(subsystem: "sh.safarier.testing", category: "navigation-trace")
    public static func category(_ action: AutomationAction) -> String? {
        switch action {
        case .openSession: return "connect"
        case .screenshot: return "observe"
        case .click, .navigateByInput(input: .click, viewVersion: _): return "click"
        case .move: return "move"
        case .mouseDown: return "mouseDown"
        case .mouseUp: return "mouseUp"
        case .scroll: return "scroll"
        case .key: return "press"
        case .insertText: return "type"
        case .releaseControl, .commitControlRelease: return "release"
        case .closeSession: return "close"
        case .cancel: return "cancel"
        case .navigate, .navigateByInput(input: .enter, viewVersion: _): return "navigate"
        case .getState: return "state"
        default: return nil
        }
    }
    public static func category(_ operation: ControlOperation) -> String? {
        switch operation {
        case .connect: return "connect"
        case .observe: return "observe"
        case .click, .clickTarget, .clickAndWait: return "click"
        case .type, .typeFromStdin: return "type"
        case .move: return "move"
        case .mouseDown: return "mouseDown"
        case .mouseUp: return "mouseUp"
        case .press: return "press"
        case .release: return "release"
        case .disconnect: return "close"
        case .cancel: return "cancel"
        case .navigate, .pressEnterAndWait: return "navigate"
        case .state: return "state"
        default: return nil
        }
    }
    public static func result(_ outcome: AutomationOutcome) -> String {
        switch outcome { case .success: return "ok"; case .failure(let error): return error.code.rawValue }
    }
    static func safeResult(_ value: String) -> String {
        if AutomationErrorCode(rawValue: value) != nil { return value }
        switch value {
        case "ok", "received", "lost", "cancelled", "other", "error", "indeterminate",
             "sender_unavailable", "sender_indeterminate", "cancellation_error", "decoding_error", "encoding_error",
             "ns_cocoa", "ns_posix", "ns_osstatus", "ns_url", "route", "staticIdentity", "deadline",
             "preIdentity", "address", "permission", "postPermissionIdentity", "createEvent", "parameter",
             "preSendIdentity", "send", "postReplyIdentity", "replyAudit", "replyError", "replyObject", "complete", "unknown",
             "INVALID_FRAME", "INVALID_REPLY", "CLEANUP_UNCONFIRMED", "UNAVAILABLE",
             "MODEL_DISABLED", "MODEL_NOT_CONFIGURED", "OCR_UNAVAILABLE", "JEV_REQUEST_FAILED",
             "JEV_INVALID_RESPONSE", "TARGET_NOT_FOUND", "TARGET_AMBIGUOUS": return value
        default: return "other"
        }
    }
    public static func emitID(_ id: UUID, _ phase: StaticString, _ result: String = "ok") {
        write(id, category: "unknown", phase: phase, result: safeResult(result))
    }
    public static func emit(_ request: AutomationRequest, _ phase: StaticString, _ result: String = "ok") {
        guard let category = category(request.action) else { return }
        write(request.requestID, category: category, phase: phase, result: safeResult(result))
    }
    public static func senderTransportFailure(_ request: AutomationRequest, phase: String, status: Int32) {
        guard let action = category(request.action) else { return }
        let safePhase = safeResult(phase)
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        logger.notice("request=\(request.requestID.uuidString, privacy: .public) action=\(action, privacy: .public) monotonic_ms=\(ms, privacy: .public) phase=sender.transport.failed transport_phase=\(safePhase, privacy: .public) osStatus=\(status, privacy: .public)")
    }
    public static func emit(_ request: ControlRequest, _ phase: StaticString, _ result: String = "ok") {
        guard let category = category(request.operation) else { return }
        write(request.requestID, category: category, phase: phase, result: safeResult(result))
    }
    public static func brokerAdmission(_ request: ControlRequest, reserved: Bool, active: Bool, awaiting: Bool, uncertain: Bool) {
        guard let action = category(request.operation) else { return }
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        logger.notice("request=\(request.requestID.uuidString, privacy: .public) action=\(action, privacy: .public) monotonic_ms=\(ms, privacy: .public) phase=broker.admission reserved=\(reserved, privacy: .public) active=\(active, privacy: .public) awaiting=\(awaiting, privacy: .public) uncertain=\(uncertain, privacy: .public)")
    }
    public static func cleanupReceipt(_ request: AutomationRequest, cleaned: Bool, runnerExited: Bool) {
        guard let action = category(request.action) else { return }
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        logger.notice("request=\(request.requestID.uuidString, privacy: .public) action=\(action, privacy: .public) monotonic_ms=\(ms, privacy: .public) phase=manager.cleanup.receipt cleaned=\(cleaned, privacy: .public) runner_exited=\(runnerExited, privacy: .public)")
    }
    /// A release receipt's reported ability to return control, not an observed focus change.
    public static func releaseReceipt(_ request: AutomationRequest, outcome: AutomationOutcome) {
        guard case .releaseControl = request.action,
              case .success(.controlReleased(let receipt)) = outcome else { return }
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        logger.notice("request=\(request.requestID.uuidString, privacy: .public) action=release monotonic_ms=\(ms, privacy: .public) phase=release.receipt manual_interaction_enabled=\(receipt.manualInteractionEnabled, privacy: .public)")
    }
    public static func screenshotChild(parent: UUID, child: UUID) {
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        logger.notice("request=\(parent.uuidString, privacy: .public) related_request=\(child.uuidString, privacy: .public) action=click monotonic_ms=\(ms, privacy: .public) phase=broker.screenshot.child result=ok")
    }
    public static func releaseChild(parent: UUID, child: UUID) {
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        logger.notice("request=\(parent.uuidString, privacy: .public) related_request=\(child.uuidString, privacy: .public) action=release monotonic_ms=\(ms, privacy: .public) phase=manager.release.child result=ok")
    }
    private static func write(_ id: UUID, category: String, phase: StaticString, result: String) {
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        logger.notice("request=\(id.uuidString, privacy: .public) action=\(category, privacy: .public) monotonic_ms=\(ms, privacy: .public) phase=\(String(describing: phase), privacy: .public) result=\(result, privacy: .public)")
    }
}
#if SAFARIER_BOUND_LOCAL_CANDIDATE
/// Diagnostic metadata only: never accepts payloads, tokens or page data.
public enum ReleaseDiagnostic {
    private static let logger = Logger(subsystem: "sh.safarier.testing", category: "navigation-trace")
    public static func emit(_ request: AutomationRequest, phase: String,
                            remainingSeconds: Double, relatedRequestID: UUID? = nil,
                            result: String = "ok") {
        switch request.action {
        case .releaseControl, .commitControlRelease: break
        default: return
        }
        let line = "RELEASE_DIAG request=\(request.requestID.uuidString) related_request=\(relatedRequestID?.uuidString ?? "none") monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000) phase=\(phase) remaining_ms=\(remainingSeconds * 1000) result=\(result)"
        logger.notice("\(line, privacy: .public)")
    }
}
#endif

/// A one-shot reply coordinator. Its handler may outlive cancellation; late results
/// are discarded and are never retried. No Apple Event descriptor is retained here.
public final class AutomationScriptCoordinator: @unchecked Sendable {
    public typealias Handler = @Sendable (AutomationRequest) async throws -> AutomationReply
    public typealias Completion = @Sendable (Data) -> Void
    private final class Entry {
        let request: AutomationRequest
        let completion: Completion
        let deadline: UInt64
        var started = false
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        init(_ request: AutomationRequest, _ completion: @escaping Completion, deadline: UInt64) { self.request = request; self.completion = completion; self.deadline = deadline }
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    // Reservations include cancelled handlers until they actually return.
    private var workerSlots: Set<UUID> = []
    public init() {}
    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    private func encode(_ reply: AutomationReply) -> Data {
        (try? AutomationCodec.encode(reply)) ?? Data(#"{"version":1,"requestID":null,"status":"error","error":{"code":"INVALID_REQUEST","retryable":false,"sideEffects":"none"}}"#.utf8)
    }
    private func reject(_ code: AutomationErrorCode, id: UUID? = nil, completion: Completion) {
        completion(encode(AutomationReply(requestID: id, outcome: .failure(AutomationError(code: code)))))
    }
    @discardableResult public func start(data: Data, role: ExecutableRole, proof: AutomationScriptCallerProof?, currentUID: uid_t, timeoutSeconds: Double, handler: @escaping Handler, completion: @escaping Completion) -> UUID? {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        guard proof?.isAuthorized(role: role, currentUID: currentUID) == true else { reject(.unauthorized, completion: completion); return nil }
        let request: AutomationRequest
        do { request = try AutomationCodec.decode(data) }
        catch let e as AutomationError { reject(e.code, completion: completion); return nil }
        catch { reject(.invalidRequest, completion: completion); return nil }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds < 1_000_000_000 else { reject(.invalidRequest, id: request.requestID, completion: completion); return nil }
        let duration = UInt64((timeoutSeconds * 1_000_000_000).rounded(.up))
        let (deadline, overflow) = receivedAt.addingReportingOverflow(duration)
        guard !overflow else { reject(.invalidRequest, id: request.requestID, completion: completion); return nil }
        let key = UUID(), entry = Entry(request, completion, deadline: deadline)
        let capacity: Int
        switch request.action {
        case .cancel, .closeSession: capacity = AutomationLimits.replayEntries
        default: capacity = AutomationLimits.replayEntries - 2
        }
        lock.lock()
        guard workerSlots.count < capacity else {
            lock.unlock()
            reject(.replayWindowFull, id: request.requestID, completion: completion)
            return nil
        }
        workerSlots.insert(key)
        entries[key] = entry
        entry.worker = Task { [weak self] in
            guard let self else { return }
            defer { self.releaseWorkerSlot(key) }
            guard self.markStarted(key) else { return }
            do {
                let result = try await handler(request)
                if result.requestID == request.requestID { self.finish(key, reply: result, handlerFinished: true) }
                else { self.finish(key, code: .indeterminateResult, handlerFinished: true) }
            } catch { self.finish(key, code: .indeterminateResult, handlerFinished: true) }
        }
        entry.timer = Task { [weak self] in
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline > now ? deadline - now : 0
            do { try await Task.sleep(nanoseconds: remaining) }
            catch { return }
            self?.finish(key, code: .timeout)
        }
        lock.unlock()
        return key
    }
    private func releaseWorkerSlot(_ key: UUID) {
        lock.lock(); workerSlots.remove(key); lock.unlock()
    }
    private func markStarted(_ key: UUID) -> Bool {
        lock.lock()
        guard let entry = entries[key] else { lock.unlock(); return false }
        let refusal: AutomationErrorCode?
        if Task.isCancelled { refusal = .cancelled }
        else if DispatchTime.now().uptimeNanoseconds >= entry.deadline { refusal = .timeout }
        else { entry.started = true; refusal = nil }
        lock.unlock()
        if let refusal { finish(key, code: refusal); return false }
        return true
    }
    private func finish(_ key: UUID, reply: AutomationReply? = nil, code: AutomationErrorCode = .cancelled, handlerFinished: Bool = false) {
        lock.lock()
        guard let entry = entries.removeValue(forKey: key) else { lock.unlock(); return }
        let expired = handlerFinished && DispatchTime.now().uptimeNanoseconds >= entry.deadline
        lock.unlock()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let instant = DispatchTime.now().uptimeNanoseconds
        let remaining = instant < entry.deadline ? Double(entry.deadline - instant) / 1_000_000_000 : 0
        // Only the entry-removal winner logs completion. A late handler cannot
        // overwrite the timer's outcome or claim a second completion.
        let winner = handlerFinished ? (expired ? "worker_expired" : "worker") : code.rawValue
        #endif
        entry.worker?.cancel(); entry.timer?.cancel()
        let readOnly: Bool
        switch entry.request.action { case .capabilities, .getState: readOnly = true; default: readOnly = false }
        let effects: AutomationSideEffects = entry.started && !readOnly ? .possible : .none
        let result = (!expired ? reply : nil) ?? AutomationReply(requestID: entry.request.requestID, outcome: .failure(AutomationError(code: expired ? .timeout : code, sideEffects: effects)))
        let data: Data
        let loggedOutcome: AutomationOutcome
        if let encoded = try? AutomationCodec.encode(result) { data = encoded; loggedOutcome = result.outcome }
        else {
            let failure = AutomationReply(requestID: entry.request.requestID, outcome: .failure(AutomationError(code: .indeterminateResult, sideEffects: effects)))
            data = encode(failure); loggedOutcome = failure.outcome
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let outcome: String
        switch result.outcome {
        case .failure(let error): outcome = error.code.rawValue
        case .success: outcome = "success"
        }
        ReleaseDiagnostic.emit(entry.request, phase: "coordinator.finish", remainingSeconds: remaining, result: winner + ":" + outcome)
        #endif
        NavigationDiagnostic.emit(entry.request, "manager.reply", NavigationDiagnostic.result(loggedOutcome))
        NavigationDiagnostic.releaseReceipt(entry.request, outcome: loggedOutcome)
        entry.completion(data)
    }
    public func cancel(_ handle: UUID) { finish(handle, code: .cancelled) }
    public func cancelAll() {
        lock.lock(); let keys = Array(entries.keys); lock.unlock()
        for key in keys { finish(key, code: .cancelled) }
    }
}
