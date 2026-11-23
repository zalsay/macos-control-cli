import Darwin
import Foundation

private enum FixtureError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "fixture failed" }
}

@main
private struct ControlStaleSocketFixture {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureError.failed(message) }
    }

    static func makeRuntimeDirectory() throws -> String {
        let path = NSHomeDirectory() + "/.safarier-socket-test-" + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return path
    }

    static func socketPin(_ path: String) throws -> stat {
        var pin = stat()
        guard lstat(path, &pin) == 0 else { throw FixtureError.failed("lstat failed: \(errno)") }
        return pin
    }

    static func bindAndClose(_ path: String) throws -> stat {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.failed("socket failed: \(errno)") }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw FixtureError.failed("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, 0o600) == 0 else { throw FixtureError.failed("bind/chmod failed: \(errno)") }
        return try socketPin(path)
    }

    static func testStaleRecovery() throws {
        let path = try makeRuntimeDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runtime = try ControlRuntime(path: path, create: false)
        guard let firstLock = try runtime.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("initial lock busy") }
        let (oldListener, oldPin) = try runtime.listenSocket(lockedBy: firstLock)
        close(oldListener) // retain path + durable pin as if the daemon exited uncleanly
        firstLock.release()
        guard let observationLock = try runtime.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("observation lock busy") }
        guard case .stale(let oldIdentity) = try runtime.startupSocketState(lockedBy: observationLock) else {
            throw FixtureError.failed("closed listener was not stale")
        }
        observationLock.release()

        let restarted = try ControlRuntime(path: path, create: false)
        guard let newLock = try restarted.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("restart lock busy") }
        defer { newLock.release() }
        guard case .stale(let observed) = try restarted.startupSocketState(lockedBy: newLock), observed == oldIdentity else {
            throw FixtureError.failed("expected a stale socket whose durable pin matches")
        }
        let (newListener, newPin) = try restarted.listenSocket(lockedBy: newLock)
        defer { close(newListener); try? restarted.removeOwnedSocket(newPin, lockedBy: newLock) }
        let newStat = try socketPin(path + "/control.sock")
        try require(newStat.st_ino != oldPin.st_ino || newStat.st_birthtimespec.tv_sec != oldPin.st_birthtimespec.tv_sec ||
                    newStat.st_birthtimespec.tv_nsec != oldPin.st_birthtimespec.tv_nsec,
                    "serve reused the old socket inode and birthtime")
        let connectable = try restarted.endpointIsConnectable()
        try require(connectable, "replacement listener is not connectable")
        guard case .active = try restarted.startupSocketState(lockedBy: newLock) else {
            throw FixtureError.failed("replacement listener was not active")
        }
    }

    static func testActiveAndUntrackedSockets() throws {
        let activePath = try makeRuntimeDirectory()
        defer { try? FileManager.default.removeItem(atPath: activePath) }
        let runtime = try ControlRuntime(path: activePath, create: false)
        guard let lock = try runtime.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("active lock busy") }
        let (listener, pin) = try runtime.listenSocket(lockedBy: lock)
        defer { close(listener); try? runtime.removeOwnedSocket(pin, lockedBy: lock); lock.release() }
        guard case .active = try runtime.startupSocketState(lockedBy: lock) else { throw FixtureError.failed("active listener misclassified") }
        do { _ = try runtime.listenSocket(lockedBy: lock); throw FixtureError.failed("second listener unexpectedly bound") }
        catch is ControlRuntime.Failure { }
        let after = try socketPin(activePath + "/control.sock")
        try require(after.st_dev == pin.st_dev && after.st_ino == pin.st_ino, "active listener path was changed")

        let legacyPath = try makeRuntimeDirectory()
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        let legacySocket = legacyPath + "/control.sock"
        let original = try bindAndClose(legacySocket)
        let legacy = try ControlRuntime(path: legacyPath, create: false)
        guard let legacyLock = try legacy.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("legacy lock busy") }
        defer { legacyLock.release() }
        do { _ = try legacy.startupSocketState(lockedBy: legacyLock); throw FixtureError.failed("untracked stale socket accepted") }
        catch is ControlRuntime.Failure { }
        do { _ = try legacy.listenSocket(lockedBy: legacyLock); throw FixtureError.failed("untracked stale socket removed") }
        catch is ControlRuntime.Failure { }
        let retained = try socketPin(legacySocket)
        try require(retained.st_dev == original.st_dev && retained.st_ino == original.st_ino, "untracked socket was removed")
    }

    static func testUnexpectedAndReplacedPaths() throws {
        let regularPath = try makeRuntimeDirectory()
        defer { try? FileManager.default.removeItem(atPath: regularPath) }
        let regularSocket = regularPath + "/control.sock"
        guard FileManager.default.createFile(atPath: regularSocket, contents: Data("keep".utf8)) else {
            throw FixtureError.failed("could not create regular path")
        }
        let regular = try ControlRuntime(path: regularPath, create: false)
        guard let regularLock = try regular.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("regular lock busy") }
        defer { regularLock.release() }
        do { _ = try regular.listenSocket(lockedBy: regularLock); throw FixtureError.failed("regular path accepted") }
        catch is ControlRuntime.Failure { }
        let regularContents = try Data(contentsOf: URL(fileURLWithPath: regularSocket))
        try require(regularContents == Data("keep".utf8), "regular path was modified")

        let replacePath = try makeRuntimeDirectory()
        defer { try? FileManager.default.removeItem(atPath: replacePath) }
        let first = try ControlRuntime(path: replacePath, create: false)
        guard let firstLock = try first.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("first lock busy") }
        let (listener, _) = try first.listenSocket(lockedBy: firstLock)
        close(listener)
        firstLock.release()
        let runtime = try ControlRuntime(path: replacePath, create: false)
        guard let lock = try runtime.acquireStartupLock(waitSeconds: 0) else { throw FixtureError.failed("replacement lock busy") }
        defer { lock.release() }
        guard case .stale(let observed) = try runtime.startupSocketState(lockedBy: lock) else { throw FixtureError.failed("expected stale original") }
        let socketPath = replacePath + "/control.sock"
        try require(unlink(socketPath) == 0, "could not replace stale socket")
        guard FileManager.default.createFile(atPath: socketPath, contents: Data("replacement".utf8)) else {
            throw FixtureError.failed("could not create replacement")
        }
        do { try runtime.removeStaleSocket(observed, lockedBy: lock); throw FixtureError.failed("replacement inode was unlinked") }
        catch is ControlRuntime.Failure { }
        let replacementContents = try Data(contentsOf: URL(fileURLWithPath: socketPath))
        try require(replacementContents == Data("replacement".utf8), "replacement path contents changed")
    }

    static func testConcurrentServeLock() throws {
        let path = try makeRuntimeDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try ControlRuntime(path: path, create: false)
        let second = try ControlRuntime(path: path, create: false)
        let bound = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { firstDone.signal() }
            guard let lock = try? first.acquireStartupLock(waitSeconds: 0) else { return }
            defer { lock.release() }
            guard let (listener, pin) = try? first.listenSocket(lockedBy: lock) else { return }
            bound.signal()
            _ = releaseFirst.wait(timeout: .now() + 3)
            try? first.removeOwnedSocket(pin, lockedBy: lock)
            close(listener)
        }
        try require(bound.wait(timeout: .now() + 3) == .success, "first writer did not bind")
        let secondLock = try second.acquireStartupLock(waitSeconds: 0.15)
        try require(secondLock == nil, "second writer entered while lifetime lock was held")
        releaseFirst.signal()
        try require(firstDone.wait(timeout: .now() + 3) == .success, "first writer did not finish")
    }

    static func main() {
        do {
            try testStaleRecovery()
            try testActiveAndUntrackedSockets()
            try testUnexpectedAndReplacedPaths()
            try testConcurrentServeLock()
            print("PASS: stale recovery, active/untracked refusal, unexpected/replaced path, concurrent lock")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
