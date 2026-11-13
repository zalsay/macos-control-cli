import XCTest
import CryptoKit
import Darwin
@testable import Safarier

final class DshControlledRuntimeTests: XCTestCase {
    final class BlockingDetach: DshControlledRuntime.Backend, @unchecked Sendable {
        let entered: XCTestExpectation
        let resume = DispatchSemaphore(value: 0)
        let lock = NSLock()
        private var calls = 0
        let fails: Bool
        init(entered: XCTestExpectation, fails: Bool = false) { self.entered = entered; self.fails = fails }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func attach(image: URL, mount: URL) throws -> DshControlledRuntime.Mount { throw DshControlledRuntime.Failure.invalidMount }
        func validateNode(_ node: URL, teamID: String) throws {}
        func detach(_ mount: DshControlledRuntime.Mount) throws {
            lock.lock(); calls += 1; lock.unlock()
            entered.fulfill()
            _ = resume.wait(timeout: .now() + 5)
            if fails { throw DshControlledRuntime.Failure.cleanupFailed }
        }
    }
    func testConcurrentCloseDoesNotDetachTwice() async throws {
        let entered = expectation(description: "detach entered")
        let backend = BlockingDetach(entered: entered)
        let mount = DshControlledRuntime.Mount(root: URL(fileURLWithPath: "/test"), device: "test", session: URL(fileURLWithPath: "/test"))
        let lease = DshControlledRuntime.MountedLease(mount: mount, backend: backend)
        let first = Task { try await lease.close() }
        await fulfillment(of: [entered], timeout: 2)
        do { try await lease.close(); XCTFail("concurrent close must be rejected") } catch {}
        backend.resume.signal()
        try await first.value
        try await lease.close()
        XCTAssertEqual(backend.count, 1)
    }
    func testFailedCloseCannotBeRetried() async throws {
        let entered = expectation(description: "detach entered")
        let backend = BlockingDetach(entered: entered, fails: true)
        let mount = DshControlledRuntime.Mount(root: URL(fileURLWithPath: "/test"), device: "test", session: URL(fileURLWithPath: "/test"))
        let lease = DshControlledRuntime.MountedLease(mount: mount, backend: backend)
        let first = Task { try await lease.close() }
        await fulfillment(of: [entered], timeout: 2)
        backend.resume.signal()
        do { try await first.value; XCTFail("expected failure") } catch {}
        do { try await lease.close(); XCTFail("failed detach must not be retried") } catch {}
        XCTAssertEqual(backend.count, 1)
    }
    func testRealImageMountAndRootMode() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-hdiutil-test-" + UUID().uuidString)
        let source = base.appendingPathComponent("source"), session = base.appendingPathComponent("session"), mount = session.appendingPathComponent("mount"), image = base.appendingPathComponent("test.dmg")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("fixture".utf8).write(to: source.appendingPathComponent("file"))
        let create = Process(); create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-quiet", "-srcfolder", source.path, "-fs", "HFSX", "-format", "UDZO", "-volname", "SafarierTest", image.path]
        create.standardOutput = FileHandle.nullDevice; create.standardError = FileHandle.nullDevice
        try create.run(); create.waitUntilExit(); XCTAssertEqual(create.terminationStatus, 0)
        guard create.terminationStatus == 0 else { return }
        let backend = DshControlledRuntime.SystemBackend()
        let attached = try backend.attach(image: image, mount: mount)
        var didDetach = false
        defer {
            if !didDetach { try? backend.detach(attached) }
            if didDetach { try? FileManager.default.removeItem(at: base) }
        }
        XCTAssertNotNil(attached.device.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression))
        var fs = statfs(); XCTAssertEqual(statfs(attached.root.path, &fs), 0)
        XCTAssertNotEqual(fs.f_flags & UInt32(MNT_RDONLY), 0)
        var before = stat(), mounted = stat()
        XCTAssertEqual(lstat(source.path, &before), 0); XCTAssertEqual(lstat(attached.root.path, &mounted), 0)
        XCTAssertEqual(before.st_mode & 0o7777, mounted.st_mode & 0o7777, "mounted root differs from source manifest mode")
        try backend.detach(attached); didDetach = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }
    func testRealAttachFailurePreservesSession() throws {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-hdiutil-failure-" + UUID().uuidString)
        let mount = session.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: session) }
        do {
            _ = try DshControlledRuntime.SystemBackend().attach(image: session.appendingPathComponent("missing.dmg"), mount: mount)
            XCTFail("missing image should fail")
        } catch DshControlledRuntime.Failure.mountStateUncertain(let path) {
            XCTAssertEqual(path, session.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: mount.path))
        }
    }
    func testRealAttachCleansUpStaleMountAndAttaches() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-hdiutil-stale-" + UUID().uuidString)
        let source = base.appendingPathComponent("source"), image = base.appendingPathComponent("test.dmg")
        let staleSession = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-dsh-stale-" + UUID().uuidString)
        let staleMount = staleSession.appendingPathComponent("mount")
        let newSession = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-dsh-new-" + UUID().uuidString)
        let newMount = newSession.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: staleMount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: newMount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("fixture".utf8).write(to: source.appendingPathComponent("file"))
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: staleSession)
            try? FileManager.default.removeItem(at: newSession)
        }
        let create = Process(); create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-quiet", "-srcfolder", source.path, "-fs", "HFSX", "-format", "UDZO", "-volname", "SafarierTest", image.path]
        create.standardOutput = FileHandle.nullDevice; create.standardError = FileHandle.nullDevice
        try create.run(); create.waitUntilExit(); XCTAssertEqual(create.terminationStatus, 0)
        guard create.terminationStatus == 0 else { return }

        let staleAttach = Process(); staleAttach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        staleAttach.arguments = ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", staleMount.path, image.path]
        staleAttach.standardOutput = FileHandle.nullDevice; staleAttach.standardError = FileHandle.nullDevice
        try staleAttach.run(); staleAttach.waitUntilExit(); XCTAssertEqual(staleAttach.terminationStatus, 0)

        let backend = DshControlledRuntime.SystemBackend()
        let attached = try backend.attach(image: image, mount: newMount)
        defer { try? backend.detach(attached) }
        XCTAssertEqual(attached.root.resolvingSymlinksInPath(), newMount.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleSession.path))
    }
    final class FakeBackend: DshControlledRuntime.Backend, @unchecked Sendable {
        let tree: URL
        var detached = 0
        init(tree: URL) { self.tree = tree }
        func attach(image: URL, mount: URL) throws -> DshControlledRuntime.Mount {
            DshControlledRuntime.Mount(root: tree, device: "test", session: mount.deletingLastPathComponent())
        }
        func validateNode(_ node: URL, teamID: String) throws {}
        func detach(_ mount: DshControlledRuntime.Mount) throws { detached += 1; try FileManager.default.removeItem(at: mount.session) }
    }
    func testReviewedAnchorAndMissingSidecarFailClosed() async throws {
        let anchor = try XCTUnwrap(DshControlledRuntime.reviewedAnchor)
        XCTAssertEqual(anchor.imageSHA256, "8a4c22bb334a3c307f8494cda029b80cd6a49545789e5e6087b878eef464baeb")
        XCTAssertEqual(anchor.manifestSHA256, "34e57a58a7674ebe656b249ab9f3bd2ca0cef45bdb9eacbec88592a8a0ec57de")
        XCTAssertEqual(anchor.nodeSHA256, "27db838bb204ef7c21df2931f5656e4c8fb32e6e947f363a402b49714d32b5b1")
        XCTAssertEqual(anchor.nodeTeamID, "HX7739G8FX")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend(tree: root)
        do {
            _ = try await DshControlledRuntime(anchor: anchor, versionsRoot: root, backend: backend).acquire()
            XCTFail("missing sidecar must fail closed")
        } catch { XCTAssertTrue(error is DshControlledRuntime.Failure) }
        XCTAssertEqual(backend.detached, 0)
    }

    func testManifestRejectsDuplicateAndEscapingPaths() throws {
        let duplicate = #"{"format":1,"entries":[{"path":".","type":"directory","mode":448},{"path":".","type":"directory","mode":448}]}"#
        let escape = #"{"format":1,"entries":[{"path":"../node","type":"file","mode":493,"size":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#
        XCTAssertThrowsError(try DshControlledRuntime.parseManifest(Data(duplicate.utf8)))
        XCTAssertThrowsError(try DshControlledRuntime.parseManifest(Data(escape.utf8)))
    }

    func testTreeRejectsChangedFileModeLinkAndExtraEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("hello".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "file")
        let digest = SHA256.hash(data: Data("hello".utf8)).map { String(format: "%02x", $0) }.joined()
        let raw = """
        {"format":1,"entries":[{"path":".","type":"directory","mode":448},{"path":"file","type":"file","mode":384,"size":5,"sha256":"\(digest)"},{"path":"link","type":"symlink","mode":493,"target":"file"}]}
        """
        let manifest = try DshControlledRuntime.parseManifest(Data(raw.utf8))
        try DshControlledRuntime.verifyTree(root, manifest: manifest)
        try Data("other".utf8).write(to: file)
        XCTAssertThrowsError(try DshControlledRuntime.verifyTree(root, manifest: manifest))
        try Data("hello".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try DshControlledRuntime.verifyTree(root, manifest: manifest))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "../escape")
        XCTAssertThrowsError(try DshControlledRuntime.verifyTree(root, manifest: manifest))
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "file")
        try Data().write(to: root.appendingPathComponent("extra"))
        XCTAssertThrowsError(try DshControlledRuntime.verifyTree(root, manifest: manifest))
    }

    func testSymlinkCannotLeaveTreeAndReenter() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("root"), outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("x".utf8).write(to: root.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("file").path)
        try FileManager.default.createSymbolicLink(atPath: outside.appendingPathComponent("back").path, withDestinationPath: "../root")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "../outside/back/file")
        let hash = SHA256.hash(data: Data("x".utf8)).map { String(format: "%02x", $0) }.joined()
        let raw = """
        {"format":1,"entries":[{"path":".","type":"directory","mode":448},{"path":"file","type":"file","mode":384,"size":1,"sha256":"\(hash)"},{"path":"link","type":"symlink","mode":493,"target":"../outside/back/file"}]}
        """
        XCTAssertThrowsError(try DshControlledRuntime.verifyTree(root, manifest: DshControlledRuntime.parseManifest(Data(raw.utf8))))
    }

    func testAcquireChecksHashesAndKeepsLeaseUntilClose() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tree = base.appendingPathComponent("tree"), versions = base.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("node"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("dsh/node_modules/@deepseek-ai/dsh/lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: versions.path)
        defer { try? FileManager.default.removeItem(at: base) }
        func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let node = Data("node".utf8), entry = Data("entry".utf8), image = Data("image".utf8)
        try node.write(to: tree.appendingPathComponent("node/node")); try entry.write(to: tree.appendingPathComponent("dsh/node_modules/@deepseek-ai/dsh/lib/bin.js"))
        var entries: [[String: Any]] = []
        func add(_ path: String, _ type: String, _ data: Data? = nil) throws {
            let url = path == "." ? tree : tree.appendingPathComponent(path)
            try FileManager.default.setAttributes([.posixPermissions: type == "directory" ? 0o700 : 0o600], ofItemAtPath: url.path)
            var item: [String: Any] = ["path": path, "type": type, "mode": type == "directory" ? 448 : 384]
            if let data { item["size"] = data.count; item["sha256"] = hash(data) }
            entries.append(item)
        }
        for path in [".", "node", "dsh", "dsh/node_modules", "dsh/node_modules/@deepseek-ai", "dsh/node_modules/@deepseek-ai/dsh", "dsh/node_modules/@deepseek-ai/dsh/lib"] { try add(path, "directory") }
        try add("node/node", "file", node); try add("dsh/node_modules/@deepseek-ai/dsh/lib/bin.js", "file", entry)
        let manifest = try JSONSerialization.data(withJSONObject: ["format": 1, "entries": entries])
        let version = versions.appendingPathComponent(hash(image)); try FileManager.default.createDirectory(at: version, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: version.path)
        try image.write(to: version.appendingPathComponent("runtime.dmg")); try manifest.write(to: version.appendingPathComponent("manifest.json"))
        let backend = FakeBackend(tree: tree)
        let anchor = DshControlledRuntime.Anchor(imageSHA256: hash(image), manifestSHA256: hash(manifest), nodeSHA256: hash(node), nodeTeamID: "test")
        let runtime = DshControlledRuntime(anchor: anchor, versionsRoot: versions, backend: backend)
        let lease = try await runtime.acquire()
        XCTAssertEqual(lease.nodeURL, tree.appendingPathComponent("node/node"))
        XCTAssertEqual(backend.detached, 0)
        try await lease.close(); XCTAssertEqual(backend.detached, 1)
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: versions.path)
        let aliased = DshControlledRuntime(anchor: anchor, versionsRoot: alias, backend: backend)
        do { _ = try await aliased.acquire(); XCTFail("symlinked versions root") } catch {}
        XCTAssertEqual(backend.detached, 1)
        try Data("corrupt".utf8).write(to: tree.appendingPathComponent("node/node"))
        do { _ = try await runtime.acquire(); XCTFail("tree mismatch") } catch {}
        XCTAssertEqual(backend.detached, 2)
        try Data("changed".utf8).write(to: version.appendingPathComponent("runtime.dmg"))
        do { _ = try await runtime.acquire(); XCTFail("image mismatch") } catch {}
        XCTAssertEqual(backend.detached, 2)
    }
}
