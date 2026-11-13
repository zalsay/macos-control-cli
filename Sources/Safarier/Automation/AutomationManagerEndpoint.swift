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
}

extension AutomationManagerEndpoint {
    var absoluteLifetimeDeadline: Double? { nil }
    var registeredInteractive: Bool { false }
    func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess {
        guard let client = self as? AutomationRunnerClient else { throw AutomationError(code: .backendUnavailable) }
        return try await client.takeValidatedReleasedOwner(matching: receipt)
    }
}

extension AutomationRunnerClient: AutomationManagerEndpoint {}
