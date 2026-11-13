import XCTest
import Darwin
@testable import SafarierCore

final class WorkspaceMigrationTests: XCTestCase {
    private var base: URL!
    private var old: URL { base.appendingPathComponent("Safarier Test") }
    private var new: URL { base.appendingPathComponent("Safarier AI") }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func oldWorkspace() throws {
        try FileManager.default.createDirectory(at: old.appendingPathComponent("locks"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("fixture".utf8).write(to: old.appendingPathComponent("profiles.json"))
    }
    func testDefaultRejectsOldDirectoryIncludingCoexistenceAndReappearance() throws {
        try oldWorkspace()
        XCTAssertThrowsError(try FileManager.prepareInternalTestWorkspace(in: base))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try FileManager.prepareInternalTestWorkspace(in: base))
        try FileManager.default.removeItem(at: old)
        XCTAssertEqual(try FileManager.prepareInternalTestWorkspace(in: base), new)
        try oldWorkspace()
        XCTAssertThrowsError(try FileManager.prepareInternalTestWorkspace(in: base))
    }
    func testMigrationRequiresConfirmationAndPreservesContents() throws {
        try oldWorkspace()
        XCTAssertThrowsError(try FileManager.migrateInternalTestWorkspace(in: base, confirmed: false))
        try FileManager.migrateInternalTestWorkspace(in: base, confirmed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("profiles.json")), Data("fixture".utf8))
        XCTAssertEqual(try FileManager.prepareInternalTestWorkspace(in: base), new)
    }
    func testMigrationRejectsExistingTargetAndHeldLock() throws {
        try oldWorkspace()
        let lock = try ProfileLock.acquire(profileID: UUID(), in: old.appendingPathComponent("locks"))
        XCTAssertThrowsError(try FileManager.migrateInternalTestWorkspace(in: base, confirmed: true))
        lock.release()
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try FileManager.migrateInternalTestWorkspace(in: base, confirmed: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("profiles.json").path))
    }
    func testMigrationRejectsSymlinkSourceAndTarget() throws {
        try FileManager.default.createSymbolicLink(at: old, withDestinationURL: base)
        XCTAssertThrowsError(try FileManager.migrateInternalTestWorkspace(in: base, confirmed: true))
        try FileManager.default.removeItem(at: old)
        try oldWorkspace()
        try FileManager.default.createSymbolicLink(at: new, withDestinationURL: base)
        XCTAssertThrowsError(try FileManager.migrateInternalTestWorkspace(in: base, confirmed: true))
    }
    func testOverrideRemainsIndependentAndMigrationRefusesOverride() throws {
        let previous = getenv("SAFARIER_HOME").map { String(cString: $0) }
        setenv("SAFARIER_HOME", base.path, 1)
        defer {
            if let previous { setenv("SAFARIER_HOME", previous, 1) }
            else { unsetenv("SAFARIER_HOME") }
        }
        XCTAssertEqual(try FileManager.safarierSupportDirectory().standardizedFileURL, base.standardizedFileURL)
        XCTAssertThrowsError(try FileManager.migrateDefaultInternalTestWorkspace(confirmed: true))
    }
}
