import Foundation

public enum RunnerPreparationError: Error, Equatable, Sendable {
    case profileMismatch
    case invalidBackgroundLaunch
    case boundNodeMismatch
    case proxyNotFound(UUID)
    case proxyMismatch(expected: UUID, got: UUID)
}

/// Pure preparation of existing outbound references; starting a subscription bridge remains the app's responsibility.
public struct RunnerPreparationPlan: Sendable {
    public let profile: Profile
    public let spec: RunnerLaunchSpec
    public let proxy: ProxySettings?
    public let boundNode: (subscription: Subscription, node: SubscriptionNode)?

    public static func resolve(
        profile: Profile,
        spec: RunnerLaunchSpec,
        proxyReader: (UUID) throws -> ProxySettings?,
        boundNodeReader: (Profile) throws -> (subscription: Subscription, node: SubscriptionNode)?
    ) throws -> RunnerPreparationPlan {
        guard profile.id == spec.profileID else { throw RunnerPreparationError.profileMismatch }
        if spec.backgroundAutomation {
            guard !spec.probe,
                  spec.startURL == URL(string: "about:blank"), spec.spiOverride == nil else {
                throw RunnerPreparationError.invalidBackgroundLaunch
            }
            guard !profile.followProxyLanguages, !profile.followProxyTimeZone else {
                throw AutomationError(code: .backendUnavailable)
            }
        }

        let proxy = try profile.proxyID.flatMap { try proxyReader($0) }
        let bound = try boundNodeReader(profile)
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let validateOwnedBinding = spec.backgroundAutomation || spec.registeredInteractive
        #else
        let validateOwnedBinding = spec.backgroundAutomation
        #endif
        if validateOwnedBinding {
            if let subscriptionID = profile.subscriptionID {
                guard let name = profile.nodeName, !name.isEmpty, let bound,
                      bound.subscription.id == subscriptionID, bound.node.name == name,
                      bound.subscription.nodes.first(where: { $0.name == name }) == bound.node else {
                    throw RunnerPreparationError.boundNodeMismatch
                }
            } else if profile.nodeName != nil || bound != nil {
                throw RunnerPreparationError.boundNodeMismatch
            }
        }
        if let bound {
            return RunnerPreparationPlan(profile: profile, spec: spec, proxy: nil, boundNode: bound)
        }
        if let proxyID = profile.proxyID {
            guard let proxy else { throw RunnerPreparationError.proxyNotFound(proxyID) }
            guard proxy.id == proxyID else { throw RunnerPreparationError.proxyMismatch(expected: proxyID, got: proxy.id) }
        }
        return RunnerPreparationPlan(profile: profile, spec: spec, proxy: proxy, boundNode: nil)
    }
}
