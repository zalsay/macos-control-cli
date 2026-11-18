// App boundary double. This does not authenticate processes or validate bundles.
import Foundation

public struct Profile: Sendable { public let id: UUID; public init(id: UUID) { self.id = id } }
public struct RunnerLaunchSpec: Sendable {
    public let registeredInteractive: Bool
    public init(registeredInteractive: Bool = true) { self.registeredInteractive = registeredInteractive }
}
public struct RunnerPreparationPlan: Sendable {
    public let profile: Profile
    public let binding: String
    public init(profile: Profile, binding: String = "original") { self.profile = profile; self.binding = binding }
}
public struct SafarierWorkspace { public init() {} }
public enum AutomationLimits { public static let cleanupSeconds = 2.0 }
public struct AutomationError: Error {
    public enum Code { case targetChanged, sessionExpired, cancelled, runnerExited, uiPolicyUnavailable, fileDialogUnsupported, indeterminateResult, timeout }
    public enum SideEffects { case possible }
    public let code: Code
    public init(code: Code, sideEffects: SideEffects? = nil) { self.code = code }
}
public enum AutomationAction {
    case capabilities, openSession, getState, screenshot, navigate, navigateByInput, move, mouseDown, mouseUp
    case selectFiles([String])
    case click, insertText, key, cancel, closeSession, releaseControl, commitControlRelease, unsupported
}
public struct AutomationRequest { public let action: AutomationAction; public init(action: AutomationAction) { self.action = action } }
public struct AutomationTargetIdentity { public let profileID: UUID }
public struct ControlReleaseReceipt { public let target: AutomationTargetIdentity }
public enum AutomationResult { case state, controlReleased(ControlReleaseReceipt) }
public enum AutomationOutcome { case success(AutomationResult), failure(AutomationError) }
public struct AutomationReply { public let outcome: AutomationOutcome; public init(outcome: AutomationOutcome) { self.outcome = outcome } }

@MainActor public final class RunnerBinderContext {
    public let profileID: UUID, runnerInstanceID = UUID()
    public var delay: Duration = .zero
    public var cutoff: ContinuousClock.Instant = .now + .seconds(10)
    public var identityAllowed = true
    private var closing = false
    public init(profileID: UUID) { self.profileID = profileID }
    public func checkLive() throws {
        try Task.checkCancellation()
        guard !closing, identityAllowed else { throw AutomationError(code: .targetChanged) }
        guard ContinuousClock.now < cutoff else { throw AutomationError(code: .timeout) }
    }
    private func check() async throws {
        try checkLive()
        try await Task.sleep(for: delay)
        try checkLive()
    }
    public func validate() async throws { try await check() }
    public func validate(profile: Profile) async throws {
        try await check()
        guard profile.id == profileID else { throw AutomationError(code: .targetChanged) }
    }
    public func validate(preparation: RunnerPreparationPlan) async throws {
        try await check()
        guard preparation.profile.id == profileID, preparation.binding == "original" else { throw AutomationError(code: .targetChanged) }
    }
    public func beginClosing() { closing = true }
}
