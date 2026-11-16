import Foundation
import SafarierCore

@main struct RegisteredPreparationRegression {
    @MainActor static func main() async throws {
        let workspace = SafarierWorkspace(), profile = Profile(id: UUID()), spec = RunnerLaunchSpec()
        let plan = RunnerPreparationPlan(profile: profile)
        let context = RunnerBinderContext(profileID: profile.id), session = BrowserSession(profile: profile)
        let slot = BoundRunnerServiceSlot(registeredSession: session, registeredLaunchPlan: plan)
        try slot.install(context)
        // Mirrors the live boundary: one complete check fits; three do not.
        // This tests App orchestration, not the real deadline or identity collectors.
        context.delay = .milliseconds(400)
        context.cutoff = .now + .seconds(1)
        do { try await slot.prepare(context: context, profile: profile, spec: spec, workspace: workspace) }
        catch { fatalError("registered preparation exhausted its remaining budget before binding: \(error)") }
        context.delay = .zero
        guard case .success(.state) = await slot.handle(AutomationRequest(action: .getState)) else { fatalError("prepared service was not dispatched") }
        precondition(session.creations == 1)
        do {
            try await slot.prepare(context: context, profile: profile, spec: spec, workspace: workspace)
            fatalError("bound slot accepted a second preparation")
        } catch {}
        slot.beginClosing()
        guard case .failure = await slot.handle(AutomationRequest(action: .getState)) else { fatalError("closed slot dispatched") }

        // A full validation still denies stale identity, profile or proxy binding,
        // expiration and cancellation before service creation or dispatch.
        for mode in 0..<7 {
            let context = RunnerBinderContext(profileID: profile.id), session = BrowserSession(profile: profile)
            let candidate: RunnerPreparationPlan?
            switch mode {
            case 0: candidate = plan; context.identityAllowed = false
            case 1: candidate = RunnerPreparationPlan(profile: Profile(id: UUID()))
            case 2: candidate = RunnerPreparationPlan(profile: profile, binding: "changed-proxy")
            case 3: candidate = plan; context.delay = .milliseconds(60); context.cutoff = .now + .milliseconds(20)
            case 4: candidate = plan; context.delay = .seconds(1)
            case 5: candidate = nil
            default: candidate = plan
            }
            let slot = BoundRunnerServiceSlot(registeredSession: session, registeredLaunchPlan: candidate)
            try slot.install(context)
            let requestSpec = mode == 6 ? RunnerLaunchSpec(registeredInteractive: false) : spec
            let preparing = Task { @MainActor in
                try await slot.prepare(context: context, profile: profile, spec: requestSpec, workspace: workspace)
            }
            if mode == 4 { try await Task.sleep(for: .milliseconds(20)); preparing.cancel() }
            do { try await preparing.value; fatalError("invalid preparation accepted: \(mode)") } catch {}
            precondition(session.creations == 0, "failed preparation created a service: \(mode)")
            guard case .failure = await slot.handle(AutomationRequest(action: .getState)) else { fatalError("failed preparation dispatched: \(mode)") }
        }
        let backgroundContext = RunnerBinderContext(profileID: profile.id)
        backgroundContext.identityAllowed = false
        let backgroundSlot = BoundRunnerServiceSlot()
        try backgroundSlot.install(backgroundContext)
        do {
            try await backgroundSlot.prepare(context: backgroundContext, profile: profile,
                spec: RunnerLaunchSpec(registeredInteractive: false), workspace: workspace)
            fatalError("background preparation skipped identity validation")
        } catch let error as AutomationError {
            precondition(error.code == .targetChanged, "background preparation reached resources before validation")
        }
        print("PASS registered prepare: remaining budget, single bind, closed slot, identity/profile/plan/timeout/cancellation/missing plan/invalid mode rejection")
    }
}
