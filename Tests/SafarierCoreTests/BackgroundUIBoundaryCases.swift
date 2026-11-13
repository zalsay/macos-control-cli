import Foundation
import SafarierCore

public enum BackgroundUIBoundaryCases {
    struct Failure: Error { let label: String }
    public static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !value() { throw Failure(label: label) } }
        for mode in [BrowserExecutionPolicy.interactive, .automationBackground] {
            for request in BackgroundUIRequest.allCases {
                var performed = 0, denied = 0, notifications: [BackgroundUIRequest] = []
                let value = BackgroundPagePolicy(mode: mode).route(request, onBlocked: { notifications.append($0) }, perform: { performed += 1; return 7 }, deny: { denied += 1; return -1 })
                let allow = mode == .interactive || request == .proxyBoundAuthentication
                try check(value == (allow ? 7 : -1), "return value")
                try check(performed == (allow ? 1 : 0), "perform count")
                try check(denied == (allow ? 0 : 1), "deny count")
                try check(notifications == (allow ? [] : [request]), "notification count")
            }
        }
        // Callback-shaped deny closures run once and never run the perform closure.
        let policy = BackgroundPagePolicy(mode: .automationBackground)
        for request in [BackgroundUIRequest.alert, .confirm, .prompt, .fileSelection, .camera, .download, .httpAuthentication, .windowClose] {
            var events: [String] = []
            policy.route(request, onBlocked: { _ in events.append("blocked") }, perform: { events.append("perform") }, deny: { events.append("completion") })
            try check(events == ["blocked", "completion"], "callback ordering and counts")
        }
        for raw in ["https://example.com", "HTTP://example.com", "about:blank", "data:text/plain,ok", "blob:https://example.com/id"] {
            try check(BackgroundPagePolicy.navigationRequest(for: URL(string: raw)) == nil, "internal scheme")
        }
        for raw in ["mailto:user@example.com", "file:///tmp/a", "custom:thing", "javascript:alert(1)"] {
            try check(BackgroundPagePolicy.navigationRequest(for: URL(string: raw)) == .externalURL, "external scheme")
        }
        try check(BackgroundPagePolicy.navigationRequest(for: nil) == .unknown, "nil URL")
        try check(BackgroundPagePolicy.navigationRequest(for: URL(string: "relative/path")) == .unknown, "missing scheme")
        return checks
    }
}
