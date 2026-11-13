import Foundation
import Darwin
import SafarierCore

@MainActor enum ManagerAutomationHooks {
    static var handleRequest: ((AutomationRequest, ExecutableRole, AutomationScriptCallerProof?, uid_t) async -> AutomationReply)?
    static var pendingAutomationWork: (() -> Int)?
    static var shutdownAutomation: (() -> Void)?
    static var profilePermissionsChanged: ((Set<UUID>) -> Void)?
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    static var launchRegisteredInteractive: ((Profile, FoundationProcessSpawner) throws -> Void)?
    #endif
    static var combinedPendingWork: Int { (pendingCommandCount?() ?? 0) + (pendingAutomationWork?() ?? 0) }
    static func cancelPending() { cancelPendingCommands?(); shutdownAutomation?() }
    static func dispatch(_ request: AutomationRequest, role: ExecutableRole, proof: AutomationScriptCallerProof?, currentUID: uid_t) async -> AutomationReply {
        if let handleRequest { return await handleRequest(request, role, proof, currentUID) }
        return await AutomationScriptService.handle(request, role: role, proof: proof, currentUID: currentUID)
    }
    static var willHandleRequest: (() -> Void)?
    static var pendingCommandCount: (() -> Int)?
    static var cancelPendingCommands: (() -> Void)?
    static var pendingCommandCountDidChange: (() -> Void)?
}
