import Foundation
import Darwin
import SafarierCore

public enum NodeSpeedResult: Equatable, Sendable {
    case success(latencyMs: Int)
    case timeout
    case failure(String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var latencyMs: Int? {
        if case .success(let ms) = self { return ms }
        return nil
    }

    public var displayText: String {
        switch self {
        case .success(let ms):
            return "\(ms) ms"
        case .timeout:
            return "超时"
        case .failure(let reason):
            return reason.isEmpty ? "失败" : reason
        }
    }
}

public enum NodeSpeedTester: Sendable {
    /// 测试单个主机和端口的 TCP 握手连接延迟（毫秒）。
    public static func testLatency(
        host: String,
        port: Int,
        timeoutMs: Int32 = 2500
    ) -> NodeSpeedResult {
        guard !host.isEmpty, (1...65535).contains(port) else {
            return .failure("无效主机或端口")
        }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let gaError = getaddrinfo(host, "\(port)", &hints, &res)
        guard gaError == 0, let info = res else {
            return .failure("域名解析失败")
        }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else {
            return .failure("创建套接字失败")
        }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let t0 = ProcessInfo.processInfo.systemUptime
        let connectRes = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if connectRes == 0 {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            return .success(latencyMs: max(1, elapsed))
        }

        if errno != EINPROGRESS {
            return .failure(String(cString: strerror(errno)))
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRes = poll(&pfd, 1, timeoutMs)
        if pollRes == 0 {
            return .timeout
        }
        guard pollRes > 0 else {
            return .failure(String(cString: strerror(errno)))
        }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0 {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            return .success(latencyMs: max(1, elapsed))
        }
        return .failure(String(cString: strerror(err)))
    }

    /// 异步测试指定节点的网络延迟。
    public static func test(
        node: SubscriptionNode,
        timeoutMs: Int32 = 2500
    ) async -> NodeSpeedResult {
        await Task.detached(priority: .userInitiated) {
            testLatency(host: node.server, port: node.serverPort, timeoutMs: timeoutMs)
        }.value
    }

    /// 批量并发测试一组节点，通过滑动窗口控制最大并发数。
    public static func testBatch(
        nodes: [SubscriptionNode],
        maxConcurrent: Int = 10,
        timeoutMs: Int32 = 2500,
        onProgress: (@Sendable (UUID, NodeSpeedResult) -> Void)? = nil
    ) async -> [UUID: NodeSpeedResult] {
        guard !nodes.isEmpty else { return [:] }

        return await withTaskGroup(of: (UUID, NodeSpeedResult).self) { group in
            var iterator = nodes.makeIterator()
            var results: [UUID: NodeSpeedResult] = [:]
            results.reserveCapacity(nodes.count)

            let concurrentLimit = max(1, min(maxConcurrent, nodes.count))
            for _ in 0..<concurrentLimit {
                if let next = iterator.next() {
                    group.addTask {
                        let res = await test(node: next, timeoutMs: timeoutMs)
                        return (next.id, res)
                    }
                }
            }

            for await (nodeID, res) in group {
                results[nodeID] = res
                onProgress?(nodeID, res)

                if let next = iterator.next() {
                    group.addTask {
                        let res = await test(node: next, timeoutMs: timeoutMs)
                        return (next.id, res)
                    }
                }
            }

            return results
        }
    }
}
