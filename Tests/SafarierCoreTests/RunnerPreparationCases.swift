import Foundation
@testable import SafarierCore

enum RunnerPreparationCases {
    struct Failure: Error { let label: String }
    enum ReaderFailure: Error, Equatable { case proxy, bound }
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            count += 1
            if !value() { throw Failure(label: label) }
        }
        func expect<E: Error & Equatable>(_ expected: E, _ label: String, _ body: () throws -> Void) throws {
            do { try body(); throw Failure(label: "\(label): did not throw") }
            catch let error as E { try check(error == expected, label) }
        }
        let id = UUID(), proxyID = UUID()
        var profile = Profile(id: id, name: "synthetic", mode: .ephemeral, proxyID: proxyID, allowsBackgroundAutomation: true)
        let proxy = ProxySettings(id: proxyID, name: "synthetic", kind: .socks5, host: "example.invalid", port: 1234)
        let node = SubscriptionNode(name: "synthetic", type: .socks, server: "example.invalid", serverPort: 1234)
        let subscription = Subscription(name: "synthetic", url: URL(string: "https://example.invalid")!, nodes: [node])
        let interactive = RunnerLaunchSpec(profileID: id)
        let background = RunnerLaunchSpec(profileID: id, startURL: URL(string: "about:blank")!, backgroundAutomation: true)
        var calls: [String] = []
        func resolve(_ p: Profile, _ s: RunnerLaunchSpec, _ readProxy: @escaping (UUID) throws -> ProxySettings? = { _ in nil }, _ readBound: @escaping (Profile) throws -> (subscription: Subscription, node: SubscriptionNode)? = { _ in nil }) throws -> RunnerPreparationPlan {
            try RunnerPreparationPlan.resolve(profile: p, spec: s, proxyReader: { calls.append("proxy"); return try readProxy($0) }, boundNodeReader: { calls.append("bound"); return try readBound($0) })
        }
        try expect(RunnerPreparationError.profileMismatch, "mismatch") { _ = try resolve(profile, RunnerLaunchSpec(profileID: UUID())) }
        try check(calls.isEmpty, "mismatch before readers")
        var invalids: [(Profile, RunnerLaunchSpec)] = []
        var p = profile; p.allowsBackgroundAutomation = false
        let legacyPlan = try resolve(p, background, { _ in proxy })
        try check(legacyPlan.profile == p && legacyPlan.proxy == proxy, "legacy false remains plannable")
        calls = []
        var s = background; s.probe = true; invalids.append((profile, s))
        s = background; s.startURL = nil; invalids.append((profile, s))
        s = background; s.startURL = URL(string: "https://example.invalid")!; invalids.append((profile, s))
        s = background; s.spiOverride = []; invalids.append((profile, s))
        for (badProfile, badSpec) in invalids {
            calls = []; try expect(RunnerPreparationError.invalidBackgroundLaunch, "background invalid") { _ = try resolve(badProfile, badSpec) }
            try check(calls.isEmpty, "invalid before readers")
        }
        p = profile; p.subscriptionID = subscription.id; p.nodeName = node.name
        calls = []; let boundPlan = try resolve(p, background, { _ in proxy }, { _ in (subscription, node) })
        try check(calls == ["proxy", "bound"] && boundPlan.proxy == nil && boundPlan.boundNode?.node == node, "background bound subscription")
        try expect(RunnerPreparationError.boundNodeMismatch, "missing binding") { _ = try resolve(p, background, { _ in proxy }) }
        var wrong = p; wrong.subscriptionID = UUID()
        try expect(RunnerPreparationError.boundNodeMismatch, "wrong subscription") { _ = try resolve(wrong, background, { _ in proxy }, { _ in (subscription, node) }) }
        wrong = p; wrong.nodeName = "wrong"
        try expect(RunnerPreparationError.boundNodeMismatch, "wrong node name") { _ = try resolve(wrong, background, { _ in proxy }, { _ in (subscription, node) }) }
        let duplicate = SubscriptionNode(name: node.name, type: .socks, server: "different.invalid", serverPort: 1234)
        var duplicateSubscription = subscription
        duplicateSubscription.nodes.append(duplicate)
        try expect(RunnerPreparationError.boundNodeMismatch, "duplicate name must select first node") { _ = try resolve(p, background, { _ in proxy }, { _ in (duplicateSubscription, duplicate) }) }
        let firstDuplicate = try resolve(p, background, { _ in proxy }, { _ in (duplicateSubscription, node) })
        try check(firstDuplicate.boundNode?.node == node, "duplicate name first node accepted")
        let interactiveDuplicate = try resolve(p, interactive, { _ in proxy }, { _ in (duplicateSubscription, duplicate) })
        try check(interactiveDuplicate.boundNode?.node == duplicate, "interactive duplicate semantics unchanged")
        let outsider = SubscriptionNode(name: node.name, type: .socks, server: "other.invalid", serverPort: 1234)
        try expect(RunnerPreparationError.boundNodeMismatch, "node outside subscription") { _ = try resolve(p, background, { _ in proxy }, { _ in (subscription, outsider) }) }
        wrong = profile; wrong.subscriptionID = nil; wrong.nodeName = nil
        try expect(RunnerPreparationError.boundNodeMismatch, "unexpected binding") { _ = try resolve(wrong, background, { _ in proxy }, { _ in (subscription, node) }) }
        wrong = p; wrong.nodeName = nil
        try expect(RunnerPreparationError.boundNodeMismatch, "missing node name") { _ = try resolve(wrong, background, { _ in proxy }, { _ in (subscription, node) }) }
        for flag in 0..<2 {
            p = profile; if flag == 0 { p.followProxyLanguages = true } else { p.followProxyTimeZone = true }
            calls = []; try expect(AutomationError(code: .backendUnavailable), "background geo") { _ = try resolve(p, background) }
            try check(calls.isEmpty, "geo before readers")
        }
        calls = []; let plan = try resolve(profile, background, { requested in
            try check(requested == proxyID, "requested proxy identity")
            return proxy
        }, { received in
            try check(received == profile, "bound reader receives original profile")
            return nil
        })
        try check(calls == ["proxy", "bound"], "reader order")
        try check(plan.profile == profile && plan.spec == background && plan.proxy == proxy && plan.boundNode == nil, "ordinary plan")
        calls = []; try expect(ReaderFailure.proxy, "proxy error") { _ = try resolve(profile, interactive, { _ in throw ReaderFailure.proxy }) }
        try check(calls == ["proxy"], "proxy error propagated before bound")
        calls = []; try expect(ReaderFailure.bound, "bound error") { _ = try resolve(profile, interactive, { _ in proxy }, { _ in throw ReaderFailure.bound }) }
        try check(calls == ["proxy", "bound"], "bound error propagated")
        calls = []; try expect(ReaderFailure.bound, "bound error precedes missing proxy") { _ = try resolve(profile, interactive, { _ in nil }, { _ in throw ReaderFailure.bound }) }
        try check(calls == ["proxy", "bound"], "missing does not suppress bound error")
        calls = []; try expect(RunnerPreparationError.proxyNotFound(proxyID), "missing proxy") { _ = try resolve(profile, interactive) }
        try check(calls == ["proxy", "bound"], "missing checked after bound")
        let other = ProxySettings(name: "other", kind: .socks5, host: "example.invalid", port: 1234)
        calls = []; try expect(RunnerPreparationError.proxyMismatch(expected: proxyID, got: other.id), "wrong proxy") { _ = try resolve(profile, interactive, { _ in other }) }
        try check(calls == ["proxy", "bound"], "identity checked after bound")
        p = profile; p.subscriptionID = subscription.id; p.nodeName = node.name
        for candidate: ProxySettings? in [nil, other, proxy] {
            calls = []; let result = try resolve(p, interactive, { _ in candidate }, { _ in (subscription, node) })
            try check(calls == ["proxy", "bound"], "subscription order")
            try check(result.proxy == nil && result.boundNode?.subscription == subscription && result.boundNode?.node == node, "subscription priority")
        }
        var authenticated = proxy
        for username in ["synthetic", "", "   "] {
            authenticated.username = username
            for policy in [background, interactive] {
                calls = []; let result = try resolve(profile, policy, { _ in authenticated })
                try check(result.proxy == authenticated && calls == ["proxy", "bound"], "authenticated metadata is plannable without password lookup")
            }
        }
        p = profile; p.proxyID = nil; calls = []; let direct = try resolve(p, background)
        try check(calls == ["bound"] && direct.proxy == nil, "direct only bound reader")
        profile.allowsBackgroundAutomation = false; profile.followProxyLanguages = true; profile.followProxyTimeZone = true
        s = interactive; s.probe = true; s.spiOverride = []; s.startURL = URL(string: "https://example.invalid")!
        authenticated.username = "synthetic"
        calls = []; let ordinary = try resolve(profile, s, { _ in authenticated })
        try check(ordinary.profile == profile && ordinary.spec == s && ordinary.proxy == authenticated && calls == ["proxy", "bound"], "interactive unrestricted")
        return count
    }
}
