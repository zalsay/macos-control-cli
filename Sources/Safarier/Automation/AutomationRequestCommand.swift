import Foundation
import Carbon
import Darwin
import OSLog
import SafarierCore

private enum AutomationRequestLifecycleDiagnostic {
    private static let logger = Logger(subsystem: "sh.safarier.testing", category: "automation-command")

    enum Phase: String {
        case received, suspended, completionQueued, resumeBefore = "resume.before"
        case resumeAfter = "resume.after", pendingRemoved
    }

    static func emit(_ id: UUID, phase: Phase, pending: Int, result: String = "ok") {
        let fixedResult = AutomationErrorCode(rawValue: result)?.rawValue ?? (result == "ok" ? "ok" : "INVALID_REQUEST")
        logger.notice("request=\(id.uuidString, privacy: .public) pending=\(pending, privacy: .public) phase=\(phase.rawValue, privacy: .public) result=\(fixedResult, privacy: .public)")
    }
}

/// Owns the one terminal transition for one suspended Apple Event command.
/// Cocoa permits resuming a suspended command from any thread, so this gate
/// must arbitrate completion without requiring the main actor.
final class AutomationRequestCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    @discardableResult
    func run(_ completion: () -> Void) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        completed = true
        lock.unlock()
        completion()
        return true
    }
}

@MainActor enum AutomationScriptPendingCommands {
    private static var pending: Set<UUID> = []
    static var count: Int { pending.count }
    static func register(_ id: UUID) { pending.insert(id) }
    static func didRegister() { ManagerAutomationHooks.pendingCommandCountDidChange?() }
    static func contains(_ id: UUID) -> Bool { pending.contains(id) }
    @discardableResult static func finish(_ id: UUID) -> Bool {
        guard pending.remove(id) != nil else { return false }
        ManagerAutomationHooks.pendingCommandCountDidChange?()
        return true
    }
}

@objc(SFRAutomationRequestCommand)
final class AutomationRequestCommand: NSScriptCommand, @unchecked Sendable {
    private static let coordinator = AutomationScriptCoordinator()

    @discardableResult
    static func completeSuspendedCommand(
        gate: AutomationRequestCompletionGate,
        result: Data,
        resume: (Data) -> Void
    ) -> Bool {
        gate.run { resume(result) }
    }

    /// Cocoa Scripting converts String values into Apple Event text descriptors.
    /// Passing the internal JSON Data object directly raises an Objective-C
    /// conversion exception while Cocoa builds the suspended command reply.
    static func appleEventResult(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? Self.errorText(.invalidRequest)
    }

    /// Only call synchronously while Cocoa is handling the current Apple Event.
    static func copyCallerProof(from event: NSAppleEventDescriptor?) -> AutomationScriptCallerProof? {
        guard let event else { return nil }
        return copyCallerProof(euidDescriptor: event.attributeDescriptor(forKeyword: AEKeyword(keySenderEUIDAttr)),
                               pidDescriptor: event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)),
                               auditDescriptor: event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr)))
    }
    // Sender integers use native Apple Event byte order; preserve all UID bits.
    private static func senderWord(_ descriptor: NSAppleEventDescriptor?) -> UInt32? {
        guard let descriptor, descriptor.descriptorType == DescType(typeSInt32) || descriptor.descriptorType == DescType(typeUInt32) else { return nil }
        let bytes = descriptor.data
        guard bytes.count == MemoryLayout<UInt32>.size else { return nil }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { bytes.copyBytes(to: $0) }
        return value
    }
    // Parses attribute snapshots only; OS provenance is established by the caller.
    static func copyCallerProof(euidDescriptor: NSAppleEventDescriptor?, pidDescriptor: NSAppleEventDescriptor?, auditDescriptor: NSAppleEventDescriptor?) -> AutomationScriptCallerProof? {
        guard let uid = senderWord(euidDescriptor), let pid = senderWord(pidDescriptor),
              pid > 0, pid <= UInt32(Int32.max),
              let audit = auditDescriptor, audit.descriptorType == DescType(typeAuditToken) else { return nil }
        let auditBytes = audit.data
        guard auditBytes.count == MemoryLayout<audit_token_t>.size else { return nil }
        return AutomationScriptCallerProof(effectiveUID: uid_t(uid), pid: Int32(pid), auditToken: Data(auditBytes))
    }
    private static func errorText(_ code: AutomationErrorCode, requestID: UUID? = nil) -> String {
        let reply = AutomationReply(requestID: requestID, outcome: .failure(AutomationError(code: code)))
        guard let data = try? AutomationCodec.encode(reply), let text = String(data: data, encoding: .utf8) else { return #"{"version":1,"requestID":null,"status":"error","error":{"code":"INVALID_REQUEST","retryable":false,"sideEffects":"none"}}"# }
        return text
    }
    override func performDefaultImplementation() -> Any? {
        guard Thread.isMainThread, NSScriptCommand.current() === self,
              ExecutableRole.resolve(Array(ProcessInfo.processInfo.arguments.dropFirst())) == .manager else { return Self.errorText(.unauthorized) }
        MainActor.assumeIsolated {
            ManagerAutomationHooks.willHandleRequest?()
            ManagerAutomationHooks.pendingCommandCount = { AutomationScriptPendingCommands.count }
            ManagerAutomationHooks.cancelPendingCommands = { Self.coordinator.cancelAll() }
        }
        // Copy all primitive attributes now; never capture the descriptor in a Task.
        let proof = Self.copyCallerProof(from: appleEvent)
        guard proof?.isAuthorized(role: .manager, currentUID: geteuid()) == true else { return Self.errorText(.unauthorized) }
        guard let text = directParameter as? String, let data = text.data(using: .utf8) else { return Self.errorText(.invalidRequest) }
        let request: AutomationRequest
        do { request = try AutomationCodec.decode(data) }
        catch let error as AutomationError { return Self.errorText(error.code) }
        catch { return Self.errorText(.invalidRequest) }
        MainActor.assumeIsolated {
            AutomationRequestLifecycleDiagnostic.emit(request.requestID, phase: .received,
                pending: AutomationScriptPendingCommands.count)
        }
        NavigationDiagnostic.emit(request, "manager.received")
        let intakeLimit: Int
        switch request.action {
        case .cancel, .closeSession, .releaseControl: intakeLimit = AutomationLimits.replayEntries
        default: intakeLimit = AutomationLimits.replayEntries - 2
        }
        guard MainActor.assumeIsolated({ AutomationScriptPendingCommands.count < intakeLimit }) else { return Self.errorText(.replayWindowFull) }
        let timeout: Double
        switch request.action {
        case .openSession: timeout = AutomationLimits.startupSeconds
        default: timeout = request.action.isNavigation ? AutomationLimits.navigationSeconds : AutomationLimits.actionSeconds
        }
        suspendExecution()
        let pendingID = UUID()
        MainActor.assumeIsolated { AutomationScriptPendingCommands.register(pendingID) }
        let completionGate = MainActor.assumeIsolated { AutomationRequestCompletionGate() }
        let pendingAtSuspension = MainActor.assumeIsolated { AutomationScriptPendingCommands.count }
        MainActor.assumeIsolated {
            AutomationRequestLifecycleDiagnostic.emit(request.requestID, phase: .suspended,
                pending: AutomationScriptPendingCommands.count)
        }
        let uid = geteuid()
        let complete: @Sendable (Data) -> Void = { [self] data in
            let result: String
            if let reply = try? AutomationCodec.decodeReply(data) {
                switch reply.outcome {
                case .success: result = "ok"
                case .failure(let error): result = error.code.rawValue
                }
            } else {
                result = AutomationErrorCode.invalidRequest.rawValue
            }
            guard Self.completeSuspendedCommand(gate: completionGate, result: data, resume: { response in
                AutomationRequestLifecycleDiagnostic.emit(request.requestID, phase: .completionQueued,
                    pending: pendingAtSuspension, result: result)
                AutomationRequestLifecycleDiagnostic.emit(request.requestID, phase: .resumeBefore,
                    pending: pendingAtSuspension, result: result)
                // NSScriptCommand explicitly allows this call off the main
                // thread. A busy UI queue must not delay the AppleEvent reply.
                self.resumeExecution(withResult: Self.appleEventResult(from: response))
                AutomationRequestLifecycleDiagnostic.emit(request.requestID, phase: .resumeAfter,
                    pending: pendingAtSuspension, result: result)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if AutomationScriptPendingCommands.finish(pendingID) {
                            AutomationRequestLifecycleDiagnostic.emit(request.requestID, phase: .pendingRemoved,
                                pending: AutomationScriptPendingCommands.count, result: result)
                        }
                    }
                }
            }) else { return }
        }
        let started = Self.coordinator.start(data: data, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: timeout, handler: { request in
            await ManagerAutomationHooks.dispatch(request, role: .manager, proof: proof, currentUID: uid)
        }, completion: complete)
        if started == nil {
            complete(Self.errorText(.replayWindowFull, requestID: request.requestID).data(using: .utf8) ?? Data())
        }
        MainActor.assumeIsolated { AutomationScriptPendingCommands.didRegister() }
        return nil
    }
}
