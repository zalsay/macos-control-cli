import Foundation
import SafarierCore

protocol AutomationManagerEndpoint: Sendable {
    var pid: Int32 { get }
    var runnerInstanceID: UUID { get }
    var ownershipID: UUID { get }
    var absoluteLifetimeDeadline: Double? { get }
    func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply
    func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit?
    var registeredInteractive: Bool { get }
    func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess
    func finishRegisteredRelease(matching receipt: ControlReleaseReceipt) async throws
}

extension AutomationManagerEndpoint {
    var absoluteLifetimeDeadline: Double? { nil }
    var registeredInteractive: Bool { false }
    func finishRegisteredRelease(matching receipt: ControlReleaseReceipt) async throws {
        // Existing endpoint doubles may still supply a retained child.
        let child = try await takeReleasedOwner(matching: receipt)
        guard child.pid == pid, child.ownershipID == ownershipID else { throw AutomationError(code: .indeterminateResult) }
    }
    func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess {
        guard let client = self as? AutomationRunnerClient else { throw AutomationError(code: .backendUnavailable) }
        return try await client.takeValidatedReleasedOwner(matching: receipt)
    }
}

extension AutomationRunnerClient: AutomationManagerEndpoint {}
