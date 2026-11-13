import Foundation
import Darwin

public enum OwnedRunnerProcessError: Error, Equatable, Sendable { case invalidTimeout }

/// A handle for the exact Foundation Process spawned by this launcher, not a PID lookup.
/// Observed exit says nothing about page destruction or cleanup success.
public final class OwnedRunnerProcess: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: ProcessExit?
        var observed: ProcessExit? { lock.lock(); defer { lock.unlock() }; return exit }
        func record(_ value: ProcessExit) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard exit == nil else { return false }
            exit = value; return true
        }
    }
    public let pid: Int32
    public let ownershipID: UUID
    private let process: Process
    private let state: State
    private let terminationLock = NSLock()
    private var terminationRequested = false
    internal init(process: Process, state: State) {
        self.process = process; self.state = state
        self.pid = process.processIdentifier; self.ownershipID = UUID()
    }
    public var observedExit: ProcessExit? { state.observed }
    public var isRunning: Bool { state.observed == nil && process.isRunning }

    /// Returns whether a termination request was issued, not whether the child exited.
    public func requestTermination() -> Bool {
        terminationLock.lock(); defer { terminationLock.unlock() }
        guard !terminationRequested, isRunning else { return false }
        terminationRequested = true
        process.terminate()
        return true
    }

    /// Inspect only descriptors of this retained child; never infer ownership from connectivity.
    public func ownsListeningLoopbackTCPPort(_ port: Int) -> Bool {
        guard (1...65535).contains(port), isRunning else { return false }
        // One extra slot detects a full/truncated result; reject more than 1024.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 1025)
        let size = MemoryLayout<proc_fdinfo>.stride * fds.count
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(size)) }
        guard Self.validFDListByteCount(Int(bytes), bufferSize: size) else { return false }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var found = false
        for entry in fds.prefix(count) where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let result = proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard result == MemoryLayout<socket_fdinfo>.size else { return false }
            if Self.matchesLoopbackListener(info, port: port) { found = true }
        }
        return found && isRunning
    }
    // Pure validators keep malformed kernel results conservative and independently testable.
    internal static func validFDListByteCount(_ bytes: Int, bufferSize: Int) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        return bytes > 0 && bytes < bufferSize && bytes % stride == 0 && bytes / stride <= 1024
    }

    internal static func matchesLoopbackListener(_ info: socket_fdinfo, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let socket = info.psi
        guard socket.soi_kind == Int32(SOCKINFO_TCP), socket.soi_family == AF_INET,
              socket.soi_type == SOCK_STREAM, socket.soi_protocol == IPPROTO_TCP else { return false }
        let tcp = socket.soi_proto.pri_tcp
        let ip = tcp.tcpsi_ini
        return tcp.tcpsi_state == TSI_S_LISTEN && ip.insi_vflag == INI_IPV4 &&
            ip.insi_laddr.ina_46.i46a_addr4.s_addr == in_addr_t(0x7f000001).bigEndian &&
            UInt16(truncatingIfNeeded: ip.insi_lport).bigEndian == UInt16(port)
    }
    public var description: String { "OwnedRunnerProcess(redacted)" }
    public var debugDescription: String { description }
    public func waitForExit(timeoutSeconds: Double) async throws -> ProcessExit? {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds < Double(UInt64.max / 1_000_000_000) - 1 else { throw OwnedRunnerProcessError.invalidTimeout }
        let start = DispatchTime.now().uptimeNanoseconds
        let nanos = UInt64(timeoutSeconds * 1_000_000_000)
        let (deadline, overflow) = start.addingReportingOverflow(nanos)
        guard !overflow else { throw OwnedRunnerProcessError.invalidTimeout }
        while true {
            try Task.checkCancellation()
            if let exit = state.observed { return exit }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return nil }
            try await Task.sleep(nanoseconds: min(5_000_000, deadline - now))
        }
    }
}
