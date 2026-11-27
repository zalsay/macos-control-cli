#if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
import XCTest
import Darwin
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

    func testStartAndRestartUseFixedPort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-port-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("entry.sh")
        let report = root.appendingPathComponent("arguments")
        try "printf '%s\\n' \"$*\" >> '\(report.path)'\necho \"dsh web: http://127.0.0.1:$4/?token=test\"\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        let lease = Lease(script)
        let service = DshService(controlledProvider: { lease }, homeURL: root)
        defer { service.stop() }
        for launch in 1...2 {
            if launch == 1 { service.start() } else { service.restart() }
            for _ in 0..<300 {
                if case .running = service.status { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard case .running(let url) = service.status else { return XCTFail("child did not start: \(service.status)") }
            XCTAssertEqual(url.host, "127.0.0.1")
            XCTAssertEqual(url.port, 61919)
            XCTAssertEqual(try String(contentsOf: report, encoding: .utf8).split(separator: "\n").map(String.init),
                           Array(repeating: "web --no-open --port 61919", count: launch))
        }
    }

    func testLANStartupWritesPrivateReceiptAndEmbedsOnlyTheLocalBootstrapURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-lan-service-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dshHome = root.appendingPathComponent("Library/Application Support/Safarier/dsh", isDirectory: true)
        try FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
        let config = dshHome.appendingPathComponent(DshLANConfiguration.fileName)
        try Data(#"{"version":1,"enabled":true,"bindAddress":"10.0.0.108"}"#.utf8).write(to: config)
        XCTAssertEqual(chmod(config.path, 0o600), 0)

        let script = root.appendingPathComponent("entry.sh")
        let arguments = root.appendingPathComponent("arguments")
        let token = "only-in-native-receipt-test"
        let advertised = "https://i.meetlife.com.cn:3000/dsh-mac/?token=\(token)"
        try "printf '%s\\n' \"$*\" > '\(arguments.path)'\necho 'dsh web: \(advertised)'\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)

        let service = DshService(
            controlledProvider: { Lease(script) },
            homeURL: root,
            availableIPv4Addresses: { ["10.0.0.108"] },
            portOccupied: { _ in false }
        )
        defer { service.stop() }
        service.start()
        for _ in 0..<300 {
            if case .running = service.status { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .running(let localURL) = service.status else { return XCTFail("LAN child did not start: \(service.status)") }
        XCTAssertEqual(localURL.host, "10.0.0.108")
        XCTAssertEqual(localURL.port, 61919)
        XCTAssertEqual(localURL.path, "/")
        XCTAssertEqual(URLComponents(url: localURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, token)
        XCTAssertFalse(service.logs.joined().contains(token), "the startup credential must not enter logs")

        let receiptURL = dshHome.appendingPathComponent(DshNativeLaunchReceipt.fileName)
        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: receiptData) as? [String: Any])
        XCTAssertEqual(receipt["version"] as? Int, 1)
        XCTAssertEqual(receipt["service"] as? String, "dsh")
        XCTAssertEqual(receipt["bindAddress"] as? String, "10.0.0.108")
        XCTAssertEqual(receipt["port"] as? Int, 61919)
        XCTAssertEqual(receipt["publicURL"] as? String, DshLANConfiguration.publicURL)
        XCTAssertEqual(receipt["token"] as? String, token)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8).trimmingCharacters(in: .newlines),
                       "web --no-open --port 61919 --host 10.0.0.108 --public-url \(DshLANConfiguration.publicURL) --trusted-host \(DshLANConfiguration.trustedHost)")

        service.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path), "stop must remove the native token handoff")
    }

    func testPortWaitPreservesExistingReceiptAndStartsOnceWhenFree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("Library/Application Support/Safarier/dsh")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = home.appendingPathComponent(DshNativeLaunchReceipt.fileName)
        let previous = Data("another listener".utf8)
        try previous.write(to: receipt)
        let script = root.appendingPathComponent("entry.sh")
        try "echo 'dsh web: http://127.0.0.1:61919/?token=fixture'\nexec /bin/sleep 60\n"
            .write(to: script, atomically: true, encoding: .utf8)
        var acquired = 0, busy = true
        let service = DshService(controlledProvider: { acquired += 1; return Lease(script) },
                                 homeURL: root, portOccupied: { _ in busy })
        defer { service.stop() }
        service.start()
        XCTAssertEqual(service.status, .starting)
        XCTAssertEqual(acquired, 0)
        XCTAssertEqual(try Data(contentsOf: receipt), previous)
        service.stop()
        XCTAssertEqual(try Data(contentsOf: receipt), previous)
        service.start()
        busy = false
        for _ in 0..<100 {
            if case .running = service.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .running = service.status else { return XCTFail("did not resume after port release") }
        XCTAssertEqual(acquired, 1)
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
