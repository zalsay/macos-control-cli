import Foundation
import Security
import LocalAuthentication
@testable import SafarierCore

enum NonInteractiveCredentialCases {
    struct Failure: Error { let label: String }
    final class UnsafeStore: CredentialStore, @unchecked Sendable {
        var reads = 0
        func password(forKey key: String) throws -> String? { reads += 1; return "unsafe" }
        func setPassword(_ password: String, forKey key: String) throws {}
        func removePassword(forKey key: String) throws {}
    }
    final class FakeReader: @unchecked Sendable {
        private let lock = NSLock()
        var status: OSStatus = errSecSuccess
        var item: CFTypeRef? = Data("synthetic".utf8) as CFData
        var queries: [CFDictionary] = []
        var interactionStates: [Bool?] = []
        func read(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
            lock.lock(); defer { lock.unlock() }
            queries.append(query)
            interactionStates.append(((query as NSDictionary)[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed)
            return (status, item)
        }
    }
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            count += 1
            if try !value() { throw Failure(label: label) }
        }
        func expect(_ expected: CredentialStoreError, _ label: String, _ body: () throws -> Void) throws {
            do { try body(); throw Failure(label: "\(label): did not throw") }
            catch let error as CredentialStoreError { try check(error == expected, label) }
        }
        let unsafe = UnsafeStore()
        let existential: any CredentialStore = unsafe
        try expect(.interactionRequired, "default rejects") { _ = try existential.passwordWithoutInteraction(forKey: "synthetic") }
        try check(unsafe.reads == 0, "default never invokes unsafe read")
        let memory = InMemoryCredentialStore()
        try check(try memory.passwordWithoutInteraction(forKey: "missing") == nil, "memory missing")
        try memory.setPassword("synthetic", forKey: "key")
        try check(try memory.passwordWithoutInteraction(forKey: "key") == "synthetic", "memory existing")
        try memory.removePassword(forKey: "key")
        try check(try memory.passwordWithoutInteraction(forKey: "key") == nil, "memory removed")

        let fake = FakeReader()
        let store = KeychainCredentialStore(service: "synthetic-service", nonInteractiveRead: { fake.read($0) })
        try check(try store.passwordWithoutInteraction(forKey: "synthetic-key") == "synthetic", "successful read")
        try check(fake.queries.count == 1, "single query")
        let query = fake.queries[0] as NSDictionary
        try check(query[kSecClass] as? String == kSecClassGenericPassword as String, "generic password")
        try check(query[kSecAttrService] as? String == "synthetic-service", "service")
        try check(query[kSecAttrAccount] as? String == "synthetic-key", "account")
        try check(query[kSecReturnData] as? Bool == true, "return data")
        try check(query[kSecMatchLimit] as? String == kSecMatchLimitOne as String, "one match")
        try check(query[kSecUseDataProtectionKeychain] as? Bool == true, "data protection only")
        guard let context = query[kSecUseAuthenticationContext] as? LAContext else { throw Failure(label: "authentication context") }
        try check(fake.interactionStates[0] == true, "interaction forbidden at query")
        fake.status = errSecItemNotFound; fake.item = nil
        try check(try store.passwordWithoutInteraction(forKey: "missing") == nil, "not found")
        try check(fake.queries.count == 2, "no legacy fallback")
        let second = fake.queries[1] as NSDictionary
        guard let secondContext = second[kSecUseAuthenticationContext] as? LAContext else { throw Failure(label: "second context") }
        try check(secondContext !== context && fake.interactionStates[1] == true, "fresh restricted context at query")
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            fake.status = status
            let before = fake.queries.count
            try expect(.interactionRequired, "auth refusal") { _ = try store.passwordWithoutInteraction(forKey: "key") }
            try check(fake.queries.count == before + 1, "auth refusal no retry")
        }
        fake.status = errSecParam
        try expect(.keychain(errSecParam), "other status") { _ = try store.passwordWithoutInteraction(forKey: "key") }
        fake.status = errSecSuccess; fake.item = nil
        try expect(.keychain(errSecDecode), "missing result") { _ = try store.passwordWithoutInteraction(forKey: "key") }
        fake.item = "not data" as CFString
        try expect(.keychain(errSecDecode), "malformed result") { _ = try store.passwordWithoutInteraction(forKey: "key") }
        fake.item = Data([0xff]) as CFData
        try expect(.keychain(errSecDecode), "non utf8") { _ = try store.passwordWithoutInteraction(forKey: "key") }
        return count
    }
}
