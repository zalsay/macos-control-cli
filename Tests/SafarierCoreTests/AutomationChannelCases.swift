import Foundation
import Darwin
import SafarierCore

public enum AutomationChannelCases {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failure(message: "write fixture: \(errno)") }
            offset += n
        }
    }
    static func expectError(_ body: () async throws -> Void, _ label: String) async throws {
        do { try await body() } catch { return }; throw Failure(message: label)
    }
    public static func run() async throws -> Int {
        var count = 0
        do {
            let p = try AutomationChannel.makePair(); let c = try AutomationChannel(adopting: p.child)
            let data = Data("roundtrip".utf8); try await p.parent.send(data)
            try check(try await c.receive() == data, "roundtrip"); count += 1
            p.parent.close(); try check(try await c.receive() == nil, "boundary EOF"); count += 1
            c.close(); c.close(); count += 1
            try await expectError({ try await c.send(data) }, "send after close"); count += 1
        }
        do {
            let p = try AutomationChannel.makePair(); defer { p.parent.close(); try? p.child.close() }
            for bytes: [UInt8] in [[0], [0,0], [3], [97], [98,99]] { try writeAll(p.child.fileDescriptor, bytes) }
            try check(try await p.parent.receive() == Data("abc".utf8), "fragmented frame"); count += 1
        }
        do {
            let p = try AutomationChannel.makePair(); let c = try AutomationChannel(adopting: p.child)
            defer { p.parent.close(); c.close() }
            let data = Data(repeating: 42, count: 65536)
            async let sent: Void = p.parent.send(data)
            try check(try await c.receive() == data, "maximum frame"); try await sent; count += 1
            try await expectError({ try await p.parent.send(Data()) }, "empty send"); count += 1
            try await expectError({ try await p.parent.send(Data(repeating: 0, count: 65537)) }, "oversize send"); count += 1
        }
        for header: [UInt8] in [[0,0,0,0], [0,1,0,1]] {
            let p = try AutomationChannel.makePair(); defer { p.parent.close(); try? p.child.close() }
            try writeAll(p.child.fileDescriptor, header)
            try await expectError({ _ = try await p.parent.receive() }, "invalid length"); count += 1
            try await expectError({ _ = try await p.parent.receive() }, "invalid length closes"); count += 1
        }
        for bytes: [UInt8] in [[0,0], [0,0,0,3,97]] {
            let p = try AutomationChannel.makePair(); defer { p.parent.close() }
            try writeAll(p.child.fileDescriptor, bytes); try p.child.close()
            try await expectError({ _ = try await p.parent.receive() }, "truncated frame"); count += 1
            try await expectError({ _ = try await p.parent.receive() }, "truncation closes"); count += 1
        }
        do {
            let p = try AutomationChannel.makePair(); let c = try AutomationChannel(adopting: p.child)
            defer { p.parent.close(); c.close() }
            let sender = Task { try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<40 { group.addTask { try await p.parent.send(Data(repeating: UInt8(i), count: 2048)) } }
                try await group.waitForAll()
            } }
            var values = Set<UInt8>()
            for _ in 0..<40 { let frame = try await c.receive()!; try check(frame.count == 2048 && frame.allSatisfy { $0 == frame[0] }, "interleaved frame"); values.insert(frame[0]) }
            try await sender.value; try check(values.count == 40, "concurrent sends"); count += 1
        }
        for cancel in [false, true] {
            var fds: [Int32] = [-1, -1]
            try check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair fixture")
            let probe = dup(fds[0]); try check(probe >= 0, "probe dup")
            let owner = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            let peer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
            defer { Darwin.close(probe); try? peer.close() }
            let channel = try AutomationChannel(adopting: owner)
            defer { channel.close() }
            // Wait until the partial header has actually been consumed, proving
            // receive is in progress rather than merely queued when interrupted.
            try writeAll(peer.fileDescriptor, [0, 0])
            let task = Task { try await channel.receive() }
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            var consumed = false
            repeat {
                var byte: UInt8 = 0
                let available = recv(probe, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if available < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { consumed = true; break }
                try check(available > 0, "peek partial header")
                try await Task.sleep(nanoseconds: 1_000_000)
            } while DispatchTime.now().uptimeNanoseconds < deadline
            if !consumed { channel.close(); task.cancel(); _ = try? await task.value; throw Failure(message: "receive did not consume partial header") }
            if cancel { task.cancel() } else { channel.close() }
            _ = try? await task.value; count += 1
        }
        do {
            let p = try AutomationChannel.makePair(); try p.child.close()
            try await expectError({ try await p.parent.send(Data([1])) }, "peer closed / SIGPIPE"); p.parent.close(); count += 1
        }
        do {
            var pipes: [Int32] = [0, 0]; try check(pipe(&pipes) == 0, "pipe"); defer { Darwin.close(pipes[1]) }
            let h = FileHandle(fileDescriptor: pipes[0], closeOnDealloc: true)
            do { _ = try AutomationChannel(adopting: h); throw Failure(message: "pipe accepted") } catch is Failure { throw Failure(message: "pipe accepted") } catch {} ; try h.close(); count += 1
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
            do { _ = try AutomationChannel(adopting: file); throw Failure(message: "file accepted") } catch is Failure { throw Failure(message: "file accepted") } catch {} ; try file.close(); count += 1
            let tcp = socket(AF_INET, SOCK_STREAM, 0); try check(tcp >= 0, "tcp fixture")
            let th = FileHandle(fileDescriptor: tcp, closeOnDealloc: true)
            do { _ = try AutomationChannel(adopting: th); throw Failure(message: "TCP accepted") } catch is Failure { throw Failure(message: "TCP accepted") } catch {}; try th.close(); count += 1
        }
        do {
            // Repeated failed adoption must not leak an internally duplicated descriptor.
            let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
            defer { try? h.close() }
            func descriptors() -> Set<Int32> {
                Set((0..<1024).compactMap { fcntl(Int32($0), F_GETFD) >= 0 ? Int32($0) : nil })
            }
            let before = descriptors()
            for _ in 0..<200 { do { _ = try AutomationChannel(adopting: h); throw Failure(message: "invalid adoption succeeded") } catch is Failure { throw Failure(message: "invalid adoption succeeded") } catch {} }
            try check(descriptors() == before, "failed adoption leaked descriptor"); count += 1
        }
        do {
            let p = try AutomationChannel.makePair(); defer { p.parent.close(); try? p.child.close() }
            let childFlags = fcntl(p.child.fileDescriptor, F_GETFD)
            try check(childFlags >= 0 && childFlags & FD_CLOEXEC != 0, "child close-on-exec"); count += 1
        }
        for cancel in [false, true] {
            var fds: [Int32] = [-1, -1]
            try check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "write fixture")
            let probe = dup(fds[0]); try check(probe >= 0, "write probe dup")
            let owner = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            let peer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
            defer { Darwin.close(probe); try? peer.close() }
            let channel = try AutomationChannel(adopting: owner); defer { channel.close() }
            let writer = Task {
                for _ in 0..<1000 { try await channel.send(Data(repeating: 9, count: 65536)) }
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            var full = false
            repeat {
                var item = pollfd(fd: probe, events: Int16(POLLOUT), revents: 0)
                let result = poll(&item, 1, 0)
                try check(result >= 0, "poll writer")
                if result == 0 { full = true; break }
                try await Task.sleep(nanoseconds: 1_000_000)
            } while DispatchTime.now().uptimeNanoseconds < deadline
            if !full { channel.close(); writer.cancel(); _ = try? await writer.value; throw Failure(message: "write did not reach backpressure") }
            if cancel { writer.cancel() } else { channel.close() }
            _ = try? await writer.value; count += 1
        }
        do {
            let p = try AutomationChannel.makePair(); defer { p.parent.close(); try? p.child.close() }
            // The peer never reads. Many concurrent maximum frames must reach the
            // bounded budget; the first rejection closes the channel to wake writes.
            let rejected = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        do { try await p.parent.send(Data(repeating: 7, count: 65536)); return false }
                        catch AutomationChannel.ChannelError.sendBackpressure { p.parent.close(); return true }
                        catch { return false }
                    }
                }
                var count = 0
                for await wasRejected in group { if wasRejected { count += 1 } }
                return count
            }
            try check(rejected > 0, "bounded send backpressure"); count += 1
        }
        return count
    }
}
