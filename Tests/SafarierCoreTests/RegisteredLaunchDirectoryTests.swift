#if SAFARIER_BOUND_LOCAL_CANDIDATE
import XCTest
import Darwin
@testable import SafarierCore

final class RegisteredLaunchDirectoryTests: XCTestCase {
    private enum Stop: Error { case beforeSpawn }
    private final class Spawner: ProcessSpawning, @unchecked Sendable {
        let workspace: SafarierWorkspace
        var reached = false
        var launchedSpec: RunnerLaunchSpec?
        init(_ workspace: SafarierWorkspace) { self.workspace = workspace }
        func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 { throw Stop.beforeSpawn }
        func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> OwnedRunnerProcess {
            reached = true
            let spec = try RunnerLaunchSpec.parse(arguments, environment: environment)
            launchedSpec = spec
            let lock = try ProfileLock.acquireForBoundCandidate(profileID: spec.profileID, in: workspace.locksDirectory)
            lock.release()
            XCTAssertEqual(logURL, workspace.runnerLogURL(for: spec.profileID))
            throw Stop.beforeSpawn
        }
    }
    func testFreshRegisteredLaunchPreparesPrivateLocksBeforeSpawn() throws {
        try check(kind: "missing", expectSpawn: true)
    }
    func testNonActivatingIntentReachesOwnedRunner() throws {
        try check(kind: "missing", expectSpawn: true, nonActivating: true)
    }
    func testUnsafeExistingLocksRejectedWithoutChmodOrSpawn() throws {
        try check(kind: "unsafe", expectSpawn: false)
    }
    func testSymlinkLocksRejectedWithoutFollowingOrSpawn() throws {
        try check(kind: "symlink", expectSpawn: false)
    }
    private func check(kind: String, expectSpawn: Bool, nonActivating: Bool = false) throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("sfr-launch-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        if kind == "unsafe" {
            try FileManager.default.createDirectory(at: workspace.locksDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        } else if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: workspace.locksDirectory, withDestinationURL: root)
        }
        let spawner = Spawner(workspace), pair = try AutomationChannel.makePair()
        defer { pair.parent.close(); try? pair.child.close() }
        let launcher = RunnerLauncher(executableURL: URL(fileURLWithPath: "/unused"), spawner: spawner, logDirectory: workspace.logsDirectory)
        do {
            _ = try workspace.launchOwnedInteractive(Profile(name: "fixture", mode: .persistent), launcher: launcher, registrationInput: pair.child, nonActivatingPresentation: nonActivating)
            XCTFail("must stop before actual spawn")
        } catch {
            if expectSpawn { XCTAssertTrue(error is Stop, "missing private locks must not reject candidate lock acquisition") }
        }
        XCTAssertEqual(spawner.reached, expectSpawn)
        if expectSpawn {
            XCTAssertEqual(spawner.launchedSpec?.registeredInteractive, true)
            XCTAssertEqual(spawner.launchedSpec?.nonActivatingPresentation, nonActivating)
        }
        var st = stat(); XCTAssertEqual(lstat(workspace.locksDirectory.path, &st), 0)
        if kind == "symlink" { XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK) }
        else { XCTAssertEqual(st.st_mode & 0o777, kind == "unsafe" ? 0o755 : 0o700) }
    }
}
#endif
