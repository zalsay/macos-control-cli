// Offline dispatch double, not identity/cleanup proof or a runnable browser.
import Foundation
public struct ControlReleaseReceipt: Sendable { public init() {} }
public struct AutomationRequest: Sendable {}
public struct AutomationReply: Sendable {}
public struct ProcessExit: Sendable {}
public enum AutomationLimits { public static let cleanupSeconds = 2.0 }
public struct OwnedRunnerProcess: Sendable { public let pid: Int32 = 1; public let ownershipID = UUID(); public init() {} }
public struct AutomationError: Error {
    public enum Code { case backendUnavailable, sessionExpired, indeterminateResult }
    public init(code: Code) {}
}
public actor AutomationRunnerClient {
    public nonisolated let pid: Int32 = 1
    public nonisolated let runnerInstanceID = UUID()
    public nonisolated let ownershipID = UUID()
    public private(set) var transfers = 0, borrowedReleases = 0
    public init() {}
    public func takeValidatedReleasedOwner(matching receipt: ControlReleaseReceipt) throws -> OwnedRunnerProcess {
        transfers += 1
        return OwnedRunnerProcess()
    }
    public func confirmRegisteredRelease(matching receipt: ControlReleaseReceipt) throws { borrowedReleases += 1 }
    public func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply { AutomationReply() }
    public func close() {}
    public func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? { nil }
}
public actor RegisteredRunnerChannel {
    public private(set) var drains = 0
    public init() {}
    public func confirmDrained(epoch: UUID, timeoutSeconds: Double = 2) async throws { drains += 1 }
}
