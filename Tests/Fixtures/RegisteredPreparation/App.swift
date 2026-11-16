import Foundation
import SafarierCore

@MainActor final class BrowserSession {
    let profile: Profile
    private(set) var creations = 0
    init(profile: Profile) { self.profile = profile }
    func makeRegisteredAutomationService(workspace: SafarierWorkspace, context: RunnerBinderContext) throws -> RunnerAutomationService {
        try context.checkLive()
        creations += 1
        return RunnerAutomationService(profileID: profile.id, runnerInstanceID: context.runnerInstanceID)
    }
}
@MainActor final class RunnerAutomationService {
    let profileID: UUID, runnerInstanceID: UUID
    init(profileID: UUID, runnerInstanceID: UUID) { self.profileID = profileID; self.runnerInstanceID = runnerInstanceID }
    func matchesBoundIdentity(profileID: UUID, runnerInstanceID: UUID) -> Bool { self.profileID == profileID && self.runnerInstanceID == runnerInstanceID }
    func handle(_ request: AutomationRequest) async -> AutomationReply { AutomationReply(outcome: .success(.state)) }
    func finishControlRelease(_ receipt: ControlReleaseReceipt) -> Bool { false }
    func shutdown() {}
    func shutdownAndDrain() async -> Bool { true }
}
@MainActor enum RunnerPreparation {
    final class OwnedResources { func close() async -> Bool { true } }
    struct Result {}
    struct BackgroundResult { let resources: OwnedResources; let prepared: Result }
    static func prepareBoundLocal(profile: Profile, spec: RunnerLaunchSpec, workspace: SafarierWorkspace, context: RunnerBinderContext) async throws -> BackgroundResult {
        throw AutomationError(code: .uiPolicyUnavailable)
    }
}
@MainActor enum RunnerMain {
    static func makeBoundAutomationService(prepared: RunnerPreparation.Result, workspace: SafarierWorkspace, context: RunnerBinderContext) async throws -> RunnerAutomationService {
        throw AutomationError(code: .uiPolicyUnavailable)
    }
    static func prepareRetainedBrowser(resources: RunnerPreparation.OwnedResources, receipt: ControlReleaseReceipt) -> Bool? { nil }
    static func retainReleasedBrowser(_ owner: Bool) {}
}
