import Foundation
import Darwin

/// The adapter supplies a snapshot of system attributes. Test proofs are synthetic;
/// constructing this value alone is not proof of an OS-authenticated Apple Event.
public struct AutomationScriptCallerProof: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let effectiveUID: uid_t
    public let pid: Int32
    private let auditToken: Data
    public init(effectiveUID: uid_t, pid: Int32, auditToken: Data) { self.effectiveUID = effectiveUID; self.pid = pid; self.auditToken = auditToken }
    public var description: String { "AutomationScriptCallerProof(redacted)" }
    public var debugDescription: String { description }
    /// Compare identity without disclosing the authenticated audit-token bytes.
    public func sameCaller(as other: AutomationScriptCallerProof) -> Bool {
        effectiveUID == other.effectiveUID && pid == other.pid && auditToken == other.auditToken
    }
    public func isAuthorized(role: ExecutableRole, currentUID: uid_t) -> Bool {
        role == .manager && effectiveUID == currentUID && pid > 0 && auditToken.count == MemoryLayout<audit_token_t>.size
    }
}
public enum AutomationScriptService {
    public static func handle(_ request: AutomationRequest, role: ExecutableRole, proof: AutomationScriptCallerProof?, currentUID: uid_t) async -> AutomationReply {
        guard proof?.isAuthorized(role: role, currentUID: currentUID) == true else { return AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .unauthorized))) }
        if case .capabilities = request.action {
            let caps = AutomationCapabilities(backend: .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: "1", role: "manager", managerPID: Int(getpid()))
            return AutomationReply(requestID: request.requestID, outcome: .success(.capabilities(caps)))
        }
        return AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .backgroundLaunchUnverified)))
    }
}
