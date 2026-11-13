#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Foundation
import SafarierCore

/// One business-handler slot. The server, not this object, authenticates peers.
@MainActor
final class BoundRunnerServiceSlot {
    private var context: RunnerBinderContext?
    private var service: RunnerAutomationService?
    private var resources: RunnerPreparation.OwnedResources?
    private var preparing = false
    private var closed = false
    private var didBind = false
    private var controlReleased = false
    private let registeredSession: BrowserSession?

    private let registeredLaunchPlan: RunnerPreparationPlan?

    init(registeredSession: BrowserSession? = nil, registeredLaunchPlan: RunnerPreparationPlan? = nil) {
        self.registeredSession = registeredSession
        self.registeredLaunchPlan = registeredLaunchPlan
    }

    func install(_ context: RunnerBinderContext) throws {
        guard self.context == nil, !closed else { throw AutomationError(code: .sessionExpired) }
        self.context = context
    }

    static func finishRegisteredRelease(session: BrowserSession, receipt: ControlReleaseReceipt, service: RunnerAutomationService) -> Bool {
        session.profile.id == receipt.target.profileID && service.finishControlRelease(receipt)
    }

    func prepare(context: RunnerBinderContext, profile: Profile, spec: RunnerLaunchSpec, workspace: SafarierWorkspace) async throws {
        guard !closed, !didBind, !preparing, self.context === context else { throw AutomationError(code: .targetChanged) }
        preparing = true
        defer { preparing = false }
        let trace = registeredSession == nil ? nil : RegisteredPrepareTrace()
        defer { trace?.failureIfPending() }
        trace?.begin(.identity)
        try await context.validate()
        trace?.success()
        let service: RunnerAutomationService
        if let registeredSession {
            trace?.begin(.profile)
            guard let registeredLaunchPlan, spec.registeredInteractive, registeredSession.profile.id == profile.id else { throw AutomationError(code: .targetChanged) }
            // Compare the actual startup snapshot, including proxy/subscription, against
            // this generation's authenticated repository binding before touching the page.
            try await context.validate(profile: registeredLaunchPlan.profile)
            trace?.success(); trace?.begin(.plan)
            try await context.validate(preparation: registeredLaunchPlan)
            trace?.success(); trace?.begin(.service)
            guard !closed, !Task.isCancelled else { throw AutomationError(code: .cancelled) }
            service = try registeredSession.makeRegisteredAutomationService(workspace: workspace, context: context)
            trace?.success(); trace?.begin(.commit)
        } else {
            let result = try await RunnerPreparation.prepareBoundLocal(profile: profile, spec: spec, workspace: workspace, context: context)
            resources = result.resources
            guard !closed, !Task.isCancelled else { throw AutomationError(code: .cancelled) }
            service = try await RunnerMain.makeBoundAutomationService(prepared: result.prepared, workspace: workspace, context: context)
        }
        guard !closed, !Task.isCancelled, !didBind,
              service.matchesBoundIdentity(profileID: context.profileID, runnerInstanceID: context.runnerInstanceID) else {
            service.shutdown()
            throw AutomationError(code: .targetChanged)
        }
        try context.checkLive()
        didBind = true
        self.service = service
        trace?.success()
    }

    func handle(_ request: AutomationRequest) async -> AutomationOutcome {
        guard !closed, let context, let service else { return .failure(AutomationError(code: .runnerExited)) }
        switch request.action {
        #if SAFARIER_INTERNAL_TEST_APP
        case .capabilities, .openSession, .getState, .screenshot, .navigate, .navigateByInput, .move, .mouseDown, .mouseUp, .click, .insertText, .key, .cancel, .closeSession, .releaseControl, .commitControlRelease:
            break
        #else
        case .capabilities, .openSession, .getState, .screenshot, .move, .mouseDown, .mouseUp, .cancel, .closeSession, .releaseControl, .commitControlRelease:
            break
        case .click, .insertText, .key:
            // This slot has no live held state: false is only for static shape
            // filtering. The page independently checks actual held/focus/sequence.
            guard (try? BoundFixtureFormPolicy.validate(request.action, held: false)) != nil else {
                return .failure(AutomationError(code: .uiPolicyUnavailable))
            }
        case .navigateByInput:
            return .failure(AutomationError(code: .uiPolicyUnavailable))
        #endif
        default:
            return .failure(AutomationError(code: .uiPolicyUnavailable))
        }
        var dispatched = false
        do {
            try await context.validate()
            guard !closed else { throw AutomationError(code: .runnerExited) }
            dispatched = true
            let reply = await service.handle(request)
            try await context.validate()
            guard !closed else { throw AutomationError(code: .runnerExited) }
            if case .commitControlRelease = request.action,
               case .success(.controlReleased(let receipt)) = reply.outcome {
                if let registeredSession {
                    guard Self.finishRegisteredRelease(session: registeredSession, receipt: receipt, service: service) else { throw AutomationError(code: .targetChanged) }
                } else {
                    guard let resources, let owner = RunnerMain.prepareRetainedBrowser(resources: resources, receipt: receipt),
                          service.finishControlRelease(receipt) else { throw AutomationError(code: .targetChanged) }
                    RunnerMain.retainReleasedBrowser(owner)
                }
                controlReleased = true
            }
            return reply.outcome
        } catch {
            // Revoke the channel synchronously: Core must not commit a reply
            // after the binding is lost, especially after native side effects.
            // The client's existing attempted tracking decides the final result.
            beginClosing()
            return .failure(dispatched
                ? AutomationError(code: .indeterminateResult, sideEffects: .possible)
                : AutomationError(code: .runnerExited))
        }
    }

    func beginClosing() {
        guard !closed else { return }
        closed = true
        context?.beginClosing()
        if controlReleased { return }
        service?.shutdown()
    }

    func drain() async -> Bool {
        beginClosing()
        if controlReleased {
            if registeredSession != nil, let service { return await service.shutdownAndDrain() }
            return true
        }
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.cleanupSeconds)
        while preparing {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
        }
        if let service, !(await service.shutdownAndDrain()) { return false }
        if let resources, !(await resources.close()) { return false }
        return true
    }
}
#endif
