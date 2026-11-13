import XCTest
import Foundation
@testable import SafarierCore

final class BookmarkStoreTests: XCTestCase {
    func testProfileIsolationRevisionConflictAndDeletionTombstone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let first = Profile(name: "one", mode: .ephemeral), second = Profile(name: "two", mode: .persistent)
        try workspace.profiles.insert(first); try workspace.profiles.insert(second)
        let a = BookmarkStore(workspace: workspace, profileID: first.id)
        let b = BookmarkStore(workspace: workspace, profileID: second.id)
        let initial = try a.load()
        XCTAssertTrue(initial.items.isEmpty)
        let item = try Bookmark(title: "one", url: URL(string: "https://example.test/path")!)
        let updated = try a.save([item], expectedRevision: initial.revision)
        XCTAssertEqual(updated.items, [item])
        XCTAssertTrue(try b.load().items.isEmpty)
        XCTAssertThrowsError(try a.save([], expectedRevision: initial.revision))
        _ = try a.deleteProfile { try workspace.profiles.delete(id: first.id) }
        XCTAssertThrowsError(try a.save([item], expectedRevision: updated.revision))
        try workspace.profiles.insert(first)
        XCTAssertThrowsError(try a.save([item], expectedRevision: updated.revision))
        XCTAssertTrue(try b.load().items.isEmpty)
    }

    func testDeleteFailureRetainsDataAndCleanupFailureIsExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root), profile = Profile(name: "fixture", mode: .persistent)
        try workspace.profiles.insert(profile)
        let store = BookmarkStore(workspace: workspace, profileID: profile.id)
        let empty = try store.load()
        let item = try Bookmark(title: "fixture", url: XCTUnwrap(URL(string: "https://example.test")))
        let saved = try store.save([item], expectedRevision: empty.revision)
        struct Refused: Error {}
        XCTAssertThrowsError(try store.deleteProfile { throw Refused() })
        XCTAssertEqual(try store.load(), saved)
        let data = root.appendingPathComponent("bookmarks").appendingPathComponent(profile.id.uuidString + ".json")
        try FileManager.default.removeItem(at: data)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.deleteProfile { try workspace.profiles.delete(id: profile.id) }) { error in
            guard case BookmarkStore.Error.profileDeletedCleanupFailed = error else { return XCTFail("expected partial failure") }
        }
        XCTAssertNil(try workspace.profiles.record(id: profile.id))
        XCTAssertThrowsError(try store.save([item], expectedRevision: saved.revision))
    }

    func testOtherProcessWriteCausesConflictInsteadOfLostUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root), profile = Profile(name: "fixture", mode: .persistent)
        try workspace.profiles.insert(profile)
        let store = BookmarkStore(workspace: workspace, profileID: profile.id)
        let empty = try store.load()
        let fixture = try Bookmark(title: "fixture", url: XCTUnwrap(URL(string: "https://example.test")))
        let initial = try store.save([fixture], expectedRevision: empty.revision)
        let folder = root.appendingPathComponent("bookmarks", isDirectory: true)
        let lock = folder.appendingPathComponent(profile.id.uuidString + ".lock").path
        let data = folder.appendingPathComponent(profile.id.uuidString + ".json").path
        let input = Pipe(), output = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import fcntl, json, os, sys, uuid
lock = open(sys.argv[1], 'r+b')
fcntl.flock(lock, fcntl.LOCK_EX)
sys.stdout.write('R'); sys.stdout.flush()
sys.stdin.read(1)
tmp = sys.argv[2] + '.external'
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump({'version': 1, 'snapshot': {'revision': str(uuid.uuid4()), 'items': []}}, f)
os.replace(tmp, sys.argv[2])
fcntl.flock(lock, fcntl.LOCK_UN)
""", lock, data]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
        let done = expectation(description: "blocked write resolves with conflict")
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { completed.signal(); done.fulfill() }
            do { _ = try store.save([], expectedRevision: initial.revision); XCTFail("stale write succeeded") }
            catch BookmarkStore.Error.conflict { }
            catch { XCTFail("unexpected storage failure") }
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 0.2), .timedOut)
        try input.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        wait(for: [done], timeout: 5)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNotEqual(try store.load().revision, initial.revision)
    }

    func testRejectsUnsafeBookmarkURLs() throws {
        for value in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pass@example.test/"] {
            XCTAssertThrowsError(try Bookmark(title: "x", url: XCTUnwrap(URL(string: value))))
        }
    }
}
