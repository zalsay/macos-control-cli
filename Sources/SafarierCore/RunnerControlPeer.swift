import Darwin
import Foundation
import BinderIdentity

/// A control identity may be borrowed. Only the original child exposes process ownership.
final class RunnerControlPeer: @unchecked Sendable {
    let child: OwnedRunnerProcess?
    let pid: Int32
    let ownershipID: UUID
    init(child: OwnedRunnerProcess) {
        self.child = child; pid = child.pid; ownershipID = child.ownershipID
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    init(reconnectCandidatePID: Int32) {
        child = nil; pid = reconnectCandidatePID; ownershipID = UUID()
    }
    #endif
    var isRunning: Bool { child?.isRunning ?? (kill(pid, 0) == 0) }
    func metadata(using bridge: KernelIdentityBridge, deadline: FrameDeadline) throws -> BIProcess {
        if let child { return try bridge.ownedChildMetadata(child, deadline: deadline) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        return try bridge.registrationPeerMetadata(pid, deadline: deadline)
        #else
        throw IdentityBridgeError.rejected
        #endif
    }
}
