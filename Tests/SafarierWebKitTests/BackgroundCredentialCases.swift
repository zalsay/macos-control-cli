import Foundation
import SafarierCore
@testable import SafarierWebKit

@MainActor enum BackgroundCredentialCases {
    struct Failure: Error { let label: String }
    final class Spy: CredentialStore, @unchecked Sendable {
        var legacyKeys: [String] = []
        var noninteractiveKeys: [String] = []
        var legacy: Result<String?, Error> = .success("legacy")
        var noninteractive: Result<String?, Error> = .success("safe")
        func password(forKey key: String) throws -> String? { legacyKeys.append(key); return try legacy.get() }
        func passwordWithoutInteraction(forKey key: String) throws -> String? { noninteractiveKeys.append(key); return try noninteractive.get() }
        func setPassword(_ password: String, forKey key: String) throws {}
        func removePassword(forKey key: String) throws {}
    }
    final class Unsupported: CredentialStore, @unchecked Sendable {
        var reads = 0
        func password(forKey key: String) throws -> String? { reads += 1; return "legacy" }
        func setPassword(_ password: String, forKey key: String) throws {}
        func removePassword(forKey key: String) throws {}
    }
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
        var proxy = ProxySettings(name: "synthetic", kind: .socks5, host: "example.invalid", port: 1234)
        for policy: BrowserExecutionPolicy in [.interactive, .automationBackground] {
            let spy = Spy()
            let result = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: spy, executionPolicy: policy)
            try check(result == nil && spy.legacyKeys.isEmpty && spy.noninteractiveKeys.isEmpty, "nil username does not read")
        }
        for username in ["", "user"] {
            proxy.username = username
            let interactive = Spy()
            let legacy = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: interactive, executionPolicy: .interactive)
            try check(legacy == "legacy" && interactive.legacyKeys == [proxy.credentialKey] && interactive.noninteractiveKeys.isEmpty, "interactive reads legacy exactly once")
            let background = Spy()
            let safe = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: background, executionPolicy: .automationBackground)
            if username.isEmpty {
                try check(safe == nil && background.noninteractiveKeys.isEmpty && background.legacyKeys.isEmpty, "empty background username does not read")
            } else {
                try check(safe == "safe" && background.noninteractiveKeys == [proxy.credentialKey] && background.legacyKeys.isEmpty, "nonempty background username reads noninteractive exactly once")
            }
        }
        let emptyPassword = Spy(); emptyPassword.noninteractive = .success("")
        let empty = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: emptyPassword, executionPolicy: .automationBackground)
        try check(empty == "" && emptyPassword.noninteractiveKeys == [proxy.credentialKey] && emptyPassword.legacyKeys.isEmpty, "stored empty password is distinct from missing")
        let legacyError = Spy(); legacyError.legacy = .failure(CredentialStoreError.keychain(-1))
        try expect(CredentialStoreError.keychain(-1), "interactive error preserved") { _ = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: legacyError, executionPolicy: .interactive) }
        try check(legacyError.legacyKeys == [proxy.credentialKey] && legacyError.noninteractiveKeys.isEmpty, "interactive error has no fallback")
        let missing = Spy(); missing.noninteractive = .success(nil)
        try expect(AutomationError(code: .interactionRequired), "missing password fails closed") { _ = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: missing, executionPolicy: .automationBackground) }
        try check(missing.noninteractiveKeys == [proxy.credentialKey] && missing.legacyKeys.isEmpty, "missing never falls back")
        let locked = Spy(); locked.noninteractive = .failure(CredentialStoreError.interactionRequired)
        try expect(AutomationError(code: .interactionRequired), "interaction required translated") { _ = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: locked, executionPolicy: .automationBackground) }
        try check(locked.noninteractiveKeys == [proxy.credentialKey] && locked.legacyKeys.isEmpty, "interaction never falls back")
        let other = Spy(); other.noninteractive = .failure(CredentialStoreError.keychain(-1))
        try expect(CredentialStoreError.keychain(-1), "other typed error preserved") { _ = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: other, executionPolicy: .automationBackground) }
        try check(other.noninteractiveKeys == [proxy.credentialKey] && other.legacyKeys.isEmpty, "other error never falls back")
        let unsupported = Unsupported()
        try expect(AutomationError(code: .interactionRequired), "default implementation fails closed") { _ = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: unsupported, executionPolicy: .automationBackground) }
        try check(unsupported.reads == 0, "unsupported does not fall back")
        let absentLegacy = Spy(); absentLegacy.legacy = .success(nil)
        let absent = try WebViewConfigurationFactory.proxyPassword(for: proxy, credentials: absentLegacy, executionPolicy: .interactive)
        try check(absent == nil && absentLegacy.legacyKeys == [proxy.credentialKey], "interactive missing retains original behavior")
        return count
    }
}
