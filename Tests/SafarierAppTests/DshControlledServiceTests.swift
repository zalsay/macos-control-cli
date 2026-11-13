#if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
import XCTest
@testable import Safarier

@MainActor
final class DshControlledServiceTests: XCTestCase {
    actor Lease: DshControlledRuntime.Lease {
        nonisolated let nodeURL = URL(fileURLWithPath: "/bin/sh")
        nonisolated let entryURL: URL
        var closes = 0
        let closeFails: Bool
        init(_ entryURL: URL, closeFails: Bool = false) { self.entryURL = entryURL; self.closeFails = closeFails }
        func close() async throws { closes += 1; if closeFails { throw DshControlledRuntime.Failure.cleanupFailed } }
    }

    func testCancelledAcquireClosesReturnedLeaseWithoutLaunching() async throws {
        let lease = Lease(URL(fileURLWithPath: "/nonexistent"))
        let gate = Gate()
        let service = DshService(controlledProvider: { await gate.wait(); return lease }, homeURL: FileManager.default.temporaryDirectory)
        service.start()
        await gate.entered()
        service.stop()
        await gate.release()
        for _ in 0..<100 where await lease.closes == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        let count = await lease.closes
        XCTAssertEqual(count, 1)
        XCTAssertEqual(service.status, .stopped)
    }

    func testUnapprovedRuntimeReportsFailureWithoutFallback() async throws {
        let service = DshService(controlledProvider: { throw DshControlledRuntime.Failure.unapproved }, homeURL: FileManager.default.temporaryDirectory)
        service.start()
        for _ in 0..<100 {
            if case .failed = service.status { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .failed(let message) = service.status else { return XCTFail("expected explicit failure") }
        XCTAssertTrue(message.contains("未批准"))
        XCTAssertNil(service.locateBinary())
    }

    func testStopAndRestartReuseLeaseWithoutDetaching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-service-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let done = root.appendingPathComponent("done")
        let script = root.appendingPathComponent("entry.sh")
        try "trap '' TERM\necho 'dsh web: http://127.0.0.1:12345/?token=test'\nwhile [ ! -f '\(done.path)' ]; do /bin/sleep 0.05; done\n".write(to: script, atomically: true, encoding: .utf8)
        let lease = Lease(script)
        let service = DshService(controlledProvider: { lease }, homeURL: root)
        service.start()
        for _ in 0..<300 {
            if case .running = service.status { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .running = service.status else { return XCTFail("test child did not start: \(service.status)") }
        service.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeExit = await lease.closes
        XCTAssertEqual(beforeExit, 0)
        try Data().write(to: done)
        for _ in 0..<300 {
            if service.logs.contains(where: { $0.contains("挂载已保留") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(service.logs.contains(where: { $0.contains("挂载已保留") }))
        try FileManager.default.removeItem(at: done)
        service.start()
        for _ in 0..<300 {
            if case .running = service.status { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .running = service.status else { return XCTFail("lease reuse failed: \(service.status)") }
        service.stop()
        try Data().write(to: done)
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterExit = await lease.closes
        XCTAssertEqual(afterExit, 0)
    }

    func testControlledEnvironmentAndExplicitEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-env-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("entry.sh")
        let report = root.appendingPathComponent("env.txt")
        try "printf '%s|%s|%s|%s|%s|%s|%s' \"$NODE_OPTIONS\" \"$NODE_PATH\" \"$NODE_BINARY\" \"$DYLD_INSERT_LIBRARIES\" \"$HTTP_PROXY\" \"$CUSTOM_VALUE\" \"$DSH_AGENTS_HOME\" > '\(report.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        let lease = Lease(script)
        let service = DshService(controlledProvider: { lease }, homeURL: root, environment: { ["NODE_OPTIONS": "bad", "NODE_PATH": "bad", "NODE_BINARY": "bad", "DYLD_INSERT_LIBRARIES": "bad", "HTTP_PROXY": "bad", "CUSTOM_VALUE": "kept", "PATH": "/usr/bin:/bin"] })
        service.start()
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: report.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let value = try String(contentsOf: report, encoding: .utf8)
        XCTAssertEqual(value, "|||||kept|" + root.appendingPathComponent("Library/Application Support/Safarier/dsh/agents").path)
        for _ in 0..<300 {
            if service.logs.contains(where: { $0.contains("挂载已保留") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let count = await lease.closes
        XCTAssertEqual(count, 0)
    }

    func testRestartWaitsForOldChildAndIgnoresItsOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-restart-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("entry.sh")
        let count = root.appendingPathComponent("count")
        let gate1 = root.appendingPathComponent("gate1")
        let gate2 = root.appendingPathComponent("gate2")
        try "echo x >> '\(count.path)'\nn=$(/usr/bin/wc -l < '\(count.path)' | /usr/bin/tr -d ' ')\ntrap 'echo OLD_GENERATION' TERM\necho dsh web: http://127.0.0.1:$((12000 + n))/?token=test\nwhile [ ! -f '\(root.path)/gate'$n ]; do /bin/sleep 0.05; done\n".write(to: script, atomically: true, encoding: .utf8)
        let lease = Lease(script)
        let service = DshService(controlledProvider: { lease }, homeURL: root)
        service.start()
        for _ in 0..<300 { if case .running = service.status { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .running = service.status else { return XCTFail("first child did not start") }
        service.restart()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertFalse(service.logs.joined().contains("OLD_GENERATION"))
        try Data().write(to: gate1)
        for _ in 0..<300 { if case .running(let url) = service.status, url.port == 12002 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .running(let url) = service.status else { return XCTFail("restart did not launch") }
        XCTAssertEqual(url.port, 12002)
        XCTAssertFalse(service.logs.joined().contains("OLD_GENERATION"))
        service.stop()
        try Data().write(to: gate2)
        for _ in 0..<300 { if service.logs.contains(where: { $0.contains("挂载已保留") }) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let closes = await lease.closes
        XCTAssertEqual(closes, 0)
    }

    func testCancelledAcquireDetachFailureRemainsVisible() async throws {
        let lease = Lease(URL(fileURLWithPath: "/nonexistent"), closeFails: true)
        let gate = Gate()
        let service = DshService(controlledProvider: { await gate.wait(); return lease }, homeURL: FileManager.default.temporaryDirectory)
        service.start()
        await gate.entered()
        service.stop()
        await gate.release()
        for _ in 0..<100 { if case .failed = service.status { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .failed(let message) = service.status else { return XCTFail("cleanup failure must remain visible") }
        XCTAssertTrue(message.contains("卸载失败"))
        service.stop()
        guard case .failed = service.status else { return XCTFail("stop must not report successful cleanup") }
    }

    actor Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var didEnter = false
        func wait() async { didEnter = true; await withCheckedContinuation { continuation = $0 } }
        func entered() async { while !didEnter { await Task.yield() } }
        func release() { continuation?.resume(); continuation = nil }
    }
}

#endif
