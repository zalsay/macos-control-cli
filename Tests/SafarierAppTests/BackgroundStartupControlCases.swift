import Foundation
import Darwin
import SafarierCore

#if canImport(Safarier)
@testable import Safarier
#endif

enum BackgroundStartupControlCases {
    struct Failure: Error { let label: String }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            checks += 1
            if !condition { throw Failure(label: label) }
        }
        func pair() throws -> (FileHandle, FileHandle) {
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw Failure(label: "socketpair") }
            return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true), FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
        }
        do {
            let input = FileHandle.nullDevice
            do {
                let watch = try BackgroundStartupControlWatch(input: input, onDisconnect: {})
                _ = await watch.stop()
                throw Failure(label: "null device accepted")
            } catch AutomationChannel.ChannelError.invalidSocket {
                try check(true, "null device rejected")
            }
        }
        do {
            let (input, peer) = try pair(); defer { try? input.close(); try? peer.close() }
            let data = Data("hello".utf8)
            try peer.write(contentsOf: data)
            let counter = Counter()
            let watch = try BackgroundStartupControlWatch(input: input, onDisconnect: { counter.increment() })
            try await Task.sleep(nanoseconds: 60_000_000)
            let disconnected = await watch.stop()
            try check(!disconnected && counter.get() == 0, "live stop")
            try check(try input.read(upToCount: 5) == data, "queued hello preserved")
            try peer.write(contentsOf: data)
            try check(try input.read(upToCount: 5) == data, "stop does not shutdown socket")
            try peer.close()
            try await Task.sleep(nanoseconds: 60_000_000)
            try check(counter.get() == 0, "no callback after stop")
        }
        do {
            let (input, peer) = try pair(); defer { try? input.close(); try? peer.close() }
            let counter = Counter()
            let preparation = Task { try await Task.sleep(nanoseconds: 3_000_000_000) }
            let watch = try BackgroundStartupControlWatch(input: input, onDisconnect: { counter.increment(); preparation.cancel() })
            try peer.close()
            do { try await preparation.value; throw Failure(label: "EOF did not cancel") }
            catch is CancellationError { }
            try check(await watch.stop(), "EOF reported")
            try check(counter.get() == 1, "EOF callback once")
        }
        do {
            let (input, peer) = try pair(); defer { try? input.close(); try? peer.close() }
            let data = Data("hello".utf8)
            try peer.write(contentsOf: data)
            let counter = Counter()
            let watch = try BackgroundStartupControlWatch(input: input, onDisconnect: { counter.increment() })
            try peer.close()
            try await watch.waitUntilReady()
            for _ in 0..<100 where counter.get() == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            try check(counter.get() == 1, "disconnected with queued hello")
            async let first = watch.stop()
            async let second = watch.stop()
            let (a, b) = await (first, second)
            try check(a && b && counter.get() == 1, "EOF with queued hello and concurrent stop")
            try check(try input.read(upToCount: 5) == data, "EOF watch leaves queued hello")
        }
        for _ in 0..<30 {
            let (input, peer) = try pair(); defer { try? input.close(); try? peer.close() }
            let counter = Counter()
            let watch = try BackgroundStartupControlWatch(input: input, onDisconnect: { counter.increment() })
            async let first = watch.stop()
            async let second = watch.stop()
            let (a, b) = await (first, second)
            try check(!a && !b, "concurrent stop race live")
            try peer.close()
            try await Task.sleep(nanoseconds: 1_000_000)
            try check(counter.get() == 0, "stop race no late callback")
        }
        return checks
    }
}
