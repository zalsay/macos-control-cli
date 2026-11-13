import XCTest
import Foundation
@testable import SafarierCore

final class WebCredentialStoreTests: XCTestCase {
    func testSaveAndQueryCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-profile", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = WebCredentialStore(workspace: workspace, profileID: profile.id)
        XCTAssertTrue(store.all().isEmpty)

        let saved = try store.save(domain: "github.com", username: "alice@example.com", password: "secret-password-123")
        XCTAssertEqual(saved.domain, "github.com")
        XCTAssertEqual(saved.username, "alice@example.com")
        XCTAssertEqual(saved.password, "secret-password-123")

        // Exact domain query
        let matches = store.credentials(for: "github.com")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.username, "alice@example.com")

        // Subdomain query matches parent domain
        let subMatches = store.credentials(for: "gist.github.com")
        XCTAssertEqual(subMatches.count, 1)
        XCTAssertEqual(subMatches.first?.id, saved.id)

        // Case insensitivity
        let upperMatches = store.credentials(for: "GITHUB.COM")
        XCTAssertEqual(upperMatches.count, 1)
    }

    func testUpdateExistingCredentialPassword() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-profile", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = WebCredentialStore(workspace: workspace, profileID: profile.id)
        let first = try store.save(domain: "example.com", username: "bob", password: "initial-password")
        XCTAssertEqual(store.all().count, 1)

        let updated = try store.save(domain: "example.com", username: "bob", password: "new-password")
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.password, "new-password")
        XCTAssertEqual(store.all().count, 1)

        let loaded = store.credentials(for: "example.com")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.password, "new-password")
    }

    func testNeverSaveDomain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-profile", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store1 = WebCredentialStore(workspace: workspace, profileID: profile.id)
        XCTAssertFalse(store1.isNeverSave(for: "secure.bank.com"))

        try store1.setNeverSave(for: "secure.bank.com")
        XCTAssertTrue(store1.isNeverSave(for: "secure.bank.com"))
        XCTAssertTrue(store1.isNeverSave(for: "SECURE.BANK.COM"))

        // Persists across re-instantiation
        let store2 = WebCredentialStore(workspace: workspace, profileID: profile.id)
        XCTAssertTrue(store2.isNeverSave(for: "secure.bank.com"))
    }

    func testDeleteCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-profile", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = WebCredentialStore(workspace: workspace, profileID: profile.id)
        let cred1 = try store.save(domain: "site1.com", username: "u1", password: "p1")
        let cred2 = try store.save(domain: "site2.com", username: "u2", password: "p2")
        XCTAssertEqual(store.all().count, 2)

        try store.delete(id: cred1.id)
        let remaining = store.all()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, cred2.id)
    }

    func testEphemeralStoreInMemoryOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "ephemeral-profile", mode: .ephemeral)
        try workspace.profiles.insert(profile)

        let store = WebCredentialStore(workspace: workspace, profileID: profile.id, isEphemeral: true)
        _ = try store.save(domain: "incognito.test", username: "secretUser", password: "secretPassword")
        XCTAssertEqual(store.credentials(for: "incognito.test").first?.username, "secretUser")

        // Credentials directory should not exist or should not have this profile's JSON
        let credDir = root.appendingPathComponent("credentials")
        let file = credDir.appendingPathComponent(profile.id.uuidString + ".json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAtomicAndSafeStoragePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-profile", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = WebCredentialStore(workspace: workspace, profileID: profile.id)
        _ = try store.save(domain: "test.com", username: "user", password: "pwd")

        let credDir = root.appendingPathComponent("credentials")
        var dirSt = stat()
        XCTAssertEqual(lstat(credDir.path, &dirSt), 0)
        XCTAssertEqual(dirSt.st_mode & 0o777, 0o700)

        let credFile = credDir.appendingPathComponent(profile.id.uuidString + ".json")
        var fileSt = stat()
        XCTAssertEqual(lstat(credFile.path, &fileSt), 0)
        XCTAssertEqual(fileSt.st_mode & 0o777, 0o600)
    }
}
