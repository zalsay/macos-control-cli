import XCTest
import Darwin
import SafarierCore
@testable import SafarierNetwork

final class NodeSpeedTesterTests: XCTestCase {
    private func makeLoopbackListener() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var opt: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // Auto allocate port

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getRes = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard getRes == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let port = Int(UInt16(bigEndian: addr.sin_port))
        return (fd, port)
    }

    func testLocalListeningSocketSucceeds() throws {
        let listener = try makeLoopbackListener()
        defer { close(listener.fd) }

        let result = NodeSpeedTester.testLatency(host: "127.0.0.1", port: listener.port, timeoutMs: 1000)
        guard case .success(let ms) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertGreaterThan(ms, 0)
        XCTAssertLessThan(ms, 500)
    }

    func testConnectionRefusedReturnsFailure() {
        let result = NodeSpeedTester.testLatency(host: "127.0.0.1", port: 59998, timeoutMs: 300)
        guard case .failure(let reason) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testTimeoutReturnsTimeout() {
        // TEST-NET-2 IP (RFC 5737): packets are discarded by routers
        let result = NodeSpeedTester.testLatency(host: "198.51.100.1", port: 12345, timeoutMs: 150)
        XCTAssertEqual(result, .timeout)
    }

    func testBatchTestingConcurrency() async throws {
        let listener = try makeLoopbackListener()
        defer { close(listener.fd) }

        let node1 = SubscriptionNode(name: "Loopback", type: .vless, server: "127.0.0.1", serverPort: listener.port)
        let node2 = SubscriptionNode(name: "Refused", type: .trojan, server: "127.0.0.1", serverPort: 59997)
        let node3 = SubscriptionNode(name: "InvalidHost", type: .shadowsocks, server: "invalid.local.nonexistent.test", serverPort: 443)

        final class Counter: @unchecked Sendable {
            var value = 0
            let lock = NSLock()
            func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
        }
        let counter = Counter()
        let results = await NodeSpeedTester.testBatch(nodes: [node1, node2, node3], maxConcurrent: 2, timeoutMs: 500) { _, _ in
            counter.increment()
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(counter.value, 3)

        guard let res1 = results[node1.id], case .success = res1 else {
            return XCTFail("Node 1 expected success")
        }
        guard let res2 = results[node2.id], case .failure = res2 else {
            return XCTFail("Node 2 expected failure")
        }
        guard let res3 = results[node3.id], case .failure = res3 else {
            return XCTFail("Node 3 expected failure")
        }
    }
}
