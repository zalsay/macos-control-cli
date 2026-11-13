import Foundation
import Darwin
@testable import SafarierCore

public enum OwnedChildLifecycleCases {
    struct Failure: Error { let message: String }
    final class Results: @unchecked Sendable {
        let lock = NSLock(); var values: [Bool] = []
        func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    }
    public static func run(helper: URL) async throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            count += 1; if !value() { throw Failure(message: message) }
        }
        func start(_ args: [String]) throws -> (OwnedRunnerProcess, Pipe, Pipe, Pipe, Int) {
            let input = Pipe(), output = Pipe(), error = Pipe()
            let owner = try FoundationProcessSpawner().spawnOwned(executableURL: helper, arguments: args, environment: [:], standardInput: input.fileHandleForReading, standardOutput: output.fileHandleForWriting, standardError: error.fileHandleForWriting)
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close(); try error.fileHandleForWriting.close()
            var data = Data()
            while true { let b = output.fileHandleForReading.readData(ofLength: 1); guard !b.isEmpty else { throw Failure(message: "fixture failed to start") }; if b[0] == 10 { break }; data.append(b) }
            guard let port = Int(String(decoding: data, as: UTF8.self)) else { throw Failure(message: "invalid port") }
            return (owner, input, output, error, port)
        }
        var socket = socket_fdinfo()
        socket.psi.soi_family = AF_INET
        socket.psi.soi_type = SOCK_STREAM
        socket.psi.soi_protocol = IPPROTO_TCP
        socket.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_LISTEN
        socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
        socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = in_addr_t(0x7f000001).bigEndian
        socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(12345).bigEndian)
        try check(!OwnedRunnerProcess.matchesLoopbackListener(socket, port: 12345), "unknown socket kind")
        socket.psi.soi_kind = Int32(SOCKINFO_TCP)
        try check(OwnedRunnerProcess.matchesLoopbackListener(socket, port: 12345), "TCP socket data")
        socket.psi.soi_protocol = IPPROTO_UDP
        try check(!OwnedRunnerProcess.matchesLoopbackListener(socket, port: 12345), "non TCP protocol")
        socket.psi.soi_protocol = IPPROTO_TCP
        try check(!OwnedRunnerProcess.matchesLoopbackListener(socket, port: -1), "invalid matching port")
        let stride = MemoryLayout<proc_fdinfo>.stride
        try check(OwnedRunnerProcess.validFDListByteCount(1024 * stride, bufferSize: 1025 * stride), "1024 descriptors accepted")
        try check(!OwnedRunnerProcess.validFDListByteCount(1025 * stride, bufferSize: 1025 * stride), "full buffer rejected")
        try check(!OwnedRunnerProcess.validFDListByteCount(stride + 1, bufferSize: 1025 * stride), "partial descriptor rejected")
        try check(!OwnedRunnerProcess.validFDListByteCount(0, bufferSize: 1025 * stride), "query failure rejected")
        let (owner, input, _, errors, port) = try start(["ignore"])
        defer { try? input.fileHandleForWriting.close() }
        let (foreign, foreignInput, _, _, foreignPort) = try start([])
        defer { try? foreignInput.fileHandleForWriting.close() }
        let (wild, wildInput, _, _, wildPort) = try start(["wildcard"])
        defer { try? wildInput.fileHandleForWriting.close() }
        try check(owner.isRunning, "running")
        try check(owner.ownsListeningLoopbackTCPPort(port), "owned loopback")
        try check(!owner.ownsListeningLoopbackTCPPort(foreignPort), "foreign listener")
        try check(!wild.ownsListeningLoopbackTCPPort(wildPort), "wildcard")
        for invalid in [0, -1, 65536, Int.max] { try check(!owner.ownsListeningLoopbackTCPPort(invalid), "invalid port") }
        try check(String(decoding: errors.fileHandleForReading.readData(ofLength: 15), as: UTF8.self) == "fixture-stderr\n", "stderr override")
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in results.add(owner.requestTermination()) }
        try check(results.values.filter { $0 }.count == 1, "concurrent termination exactly once")
        try check(!owner.requestTermination(), "repeated termination")
        try check(owner.isRunning, "ignored termination still running")
        try input.fileHandleForWriting.close()
        let exit = try await owner.waitForExit(timeoutSeconds: 3)
        try check(exit != nil, "EOF exit")
        try check(!owner.isRunning && !owner.ownsListeningLoopbackTCPPort(port) && !owner.requestTermination(), "exited")
        try check(foreign.ownsListeningLoopbackTCPPort(foreignPort), "foreign owner identifies its own listener")
        try check(foreign.requestTermination(), "normal TERM requested")
        let foreignExit = try await foreign.waitForExit(timeoutSeconds: 3)
        try check(foreignExit?.uncaughtSignal == true && foreignExit?.status == SIGTERM, "normal TERM exits child")
        try foreignInput.fileHandleForWriting.close(); try wildInput.fileHandleForWriting.close()
        let wildExit = try await wild.waitForExit(timeoutSeconds: 3)
        try check(wildExit != nil, "wildcard fixture exits")
        return count
    }
}
