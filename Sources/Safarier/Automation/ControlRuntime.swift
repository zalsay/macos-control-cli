import Darwin
import Dispatch
import Foundation
import CryptoKit
import SafarierControlSupport
import SafarierCore

/// Private socket transport. The peer proof is from the connected kernel socket,
/// and never grants authority to signal or select a process.
// The pinned directory descriptor and its identity never change after init;
// operations use independent local buffers and verify the path on each use.
final class ControlRuntime: @unchecked Sendable {
    enum Failure: Error { case unsafe, disconnected, protocolError, indeterminate, cleanupUnconfirmed }
    private let path: String
    private let directory: Int32
    private let device: dev_t
    private let inode: ino_t
    private static let socketName = "control.sock"

    init(path: String, create: Bool) throws {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.utf8.contains(0) else { throw Failure.unsafe }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.unsafe }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unsafe }
        var selected: Int32 = -1
        var selectedStat = stat()
        do {
            for (index, component) in parts.enumerated() {
                var parentStat = stat()
                guard fstat(parent, &parentStat) == 0, Self.safeAncestor(parentStat) else { throw Failure.unsafe }
                if index == parts.count - 1 && create {
                    if mkdirat(parent, component, 0o700) != 0 && errno != EEXIST { throw Failure.unsafe }
                }
                var before = stat(), held = stat(), after = stat()
                guard fstatat(parent, component, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      (before.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafe }
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unsafe }
                guard fstat(next, &held) == 0, fstatat(parent, component, &after, AT_SYMLINK_NOFOLLOW) == 0,
                      Self.same(before, held), Self.same(held, after), Self.safeAncestor(held) else {
                    close(next); throw Failure.unsafe
                }
                close(parent); parent = next
                if index == parts.count - 1 {
                    guard held.st_uid == geteuid(), held.st_mode & 0o7777 == 0o700 else { throw Failure.unsafe }
                    selected = next
                    selectedStat = held
                }
            }
        } catch {
            if parent >= 0 { close(parent) }
            throw error
        }
        guard selected >= 0 else { throw Failure.unsafe }
        self.path = path; self.directory = selected
        self.device = selectedStat.st_dev; self.inode = selectedStat.st_ino
    }
    deinit { close(directory) }

    private static func safeAncestor(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR && (value.st_uid == 0 || value.st_uid == geteuid()) && (value.st_mode & 0o022) == 0
    }
    private static func same(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid }
    private func validateRoot() throws {
        var held = stat(), current = stat()
        guard fstat(directory, &held) == 0, lstat(path, &current) == 0, Self.same(held, current),
              held.st_dev == device, held.st_ino == inode, held.st_uid == geteuid(),
              (held.st_mode & S_IFMT) == S_IFDIR, held.st_mode & 0o7777 == 0o700 else { throw Failure.unsafe }
        // Reopen every ancestor without following symlinks, then compare root identity.
        let fresh = try ControlRuntime(path: path, create: false)
        guard fresh.device == device, fresh.inode == inode else { throw Failure.unsafe }
    }
    private func socketPath() throws -> String {
        let full = path + "/" + Self.socketName
        guard full.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw Failure.unsafe }
        return full
    }
    private func address() throws -> sockaddr_un {
        let full = try socketPath()
        var result = sockaddr_un(); result.sun_family = sa_family_t(AF_UNIX)
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(full.utf8) + [0]
        withUnsafeMutableBytes(of: &result.sun_path) { raw in raw.copyBytes(from: bytes) }
        return result
    }
    private func socketStat() throws -> stat {
        var value = stat()
        guard fstatat(directory, Self.socketName, &value, AT_SYMLINK_NOFOLLOW) == 0,
              (value.st_mode & S_IFMT) == S_IFSOCK, value.st_uid == geteuid(), value.st_mode & 0o7777 == 0o600 else { throw Failure.unsafe }
        return value
    }
    private func newSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unsafe }
        do { try Self.configureAccepted(fd) } catch { close(fd); throw error }
        return fd
    }
    static func configureAccepted(_ fd: Int32) throws {
        var enabled: Int32 = 1
        let existing = fcntl(fd, F_GETFD)
        guard existing >= 0, fcntl(fd, F_SETFD, existing | FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { throw Failure.unsafe }
    }
    func listenSocket() throws -> (Int32, stat) {
        try validateRoot()
        var existing = stat()
        guard fstatat(directory, Self.socketName, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw Failure.unsafe }
        let fd = try newSocket()
        var didBind = false
        var createdPin: stat?
        do {
            var addr = try address()
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0 else { throw Failure.unsafe }
            didBind = true
            // Only the socket just created under our pinned private directory may be changed.
            var created = stat()
            guard fstatat(directory, Self.socketName, &created, AT_SYMLINK_NOFOLLOW) == 0,
                  (created.st_mode & S_IFMT) == S_IFSOCK, created.st_uid == geteuid() else { throw Failure.unsafe }
            createdPin = created
            if created.st_mode & 0o7777 != 0o600 {
                guard fchmodat(directory, Self.socketName, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unsafe }
            }
            let pinned = try socketStat()
            guard created.st_dev == pinned.st_dev, created.st_ino == pinned.st_ino else { throw Failure.unsafe }
            try validateRoot()
            guard listen(fd, 8) == 0 else { throw Failure.unsafe }
            return (fd, pinned)
        } catch {
            close(fd)
            if didBind {
                guard let createdPin, removeCreatedSocketIfOwned(createdPin) else { throw Failure.cleanupUnconfirmed }
            }
            throw error
        }
    }
    func connectSocket() throws -> (Int32, stat) {
        try validateRoot()
        let before = try socketStat(); let fd = try newSocket()
        do {
            var addr = try address()
            let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard connected == 0 else { throw Failure.disconnected }
            try validateRoot(); let after = try socketStat()
            guard Self.same(before, after) else { throw Failure.unsafe }
            return (fd, before)
        } catch { close(fd); throw error }
    }
    func validateSocket(_ pinned: stat) throws {
        try validateRoot(); let now = try socketStat()
        guard Self.same(now, pinned) else { throw Failure.unsafe }
    }
    func removeOwnedSocket(_ pinned: stat) throws {
        try validateSocket(pinned)
        guard unlinkat(directory, Self.socketName, 0) == 0 else { throw Failure.unsafe }
    }
    /// Used only for rollback of a just-created socket, including before its
    /// final chmod. Never unlink if root, type, owner or inode cannot be proved.
    func removeCreatedSocketIfOwned(_ created: stat) -> Bool {
        guard (try? validateRoot()) != nil else { return false }
        var now = stat()
        guard fstatat(directory, Self.socketName, &now, AT_SYMLINK_NOFOLLOW) == 0,
              (created.st_mode & S_IFMT) == S_IFSOCK, (now.st_mode & S_IFMT) == S_IFSOCK,
              created.st_uid == geteuid(), now.st_uid == geteuid(),
              created.st_dev == now.st_dev, created.st_ino == now.st_ino else { return false }
        return unlinkat(directory, Self.socketName, 0) == 0
    }

    static func peer(_ fd: Int32) throws -> CSControlPeer {
        var proof = CSControlPeer()
        guard cs_control_verify_peer(fd, &proof) == 1 else { throw Failure.unsafe }
        return proof
    }
    static func samePeer(_ a: CSControlPeer, _ b: CSControlPeer) -> Bool {
        var x = a, y = b; return cs_control_peer_equal(&x, &y) == 1
    }
    static func nativePoint(x: Double, y: Double, viewport: AutomationViewport) -> ViewportPoint? {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0,
              x < Double(viewport.pixelWidth), y < Double(viewport.pixelHeight),
              viewport.scaleX.isFinite, viewport.scaleY.isFinite,
              viewport.scaleX > 0, viewport.scaleY > 0 else { return nil }
        let point = ViewportPoint(x: x / viewport.scaleX, y: y / viewport.scaleY)
        return viewport.contains(point) ? point : nil
    }
    static func setTimeout(_ fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout.size(ofValue: timeout))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else { throw Failure.unsafe }
    }
    private static func frameDeadline(seconds: Int) throws -> UInt64 {
        guard seconds > 0, seconds <= Int(AutomationLimits.generationSeconds) else { throw Failure.unsafe }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(UInt64(seconds) * 1_000_000_000)
        guard !overflow else { throw Failure.unsafe }
        return deadline
    }
    private static func transfer(_ fd: Int32, bytes: UnsafeMutableRawBufferPointer, writing: Bool, deadline: UInt64) throws {
        var offset = 0
        while offset < bytes.count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw Failure.disconnected }
            let remaining = deadline - now
            let microseconds = (remaining + 999) / 1_000
            var timeout = timeval(tv_sec: Int(microseconds / 1_000_000), tv_usec: Int32(microseconds % 1_000_000))
            let option = writing ? SO_SNDTIMEO : SO_RCVTIMEO
            guard setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else { throw Failure.unsafe }
            let n = writing ? Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0) : Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0, DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.disconnected }
            offset += n
        }
    }
    static func sendFrame(_ fd: Int32, _ payload: Data, timeoutSeconds: Int = Int(AutomationLimits.actionSeconds)) throws {
        var bytes = [UInt8](try ControlProtocol.frame(payload))
        let deadline = try frameDeadline(seconds: timeoutSeconds)
        try bytes.withUnsafeMutableBytes { try transfer(fd, bytes: $0, writing: true, deadline: deadline) }
    }
    static func receiveFrame(_ fd: Int32, timeoutSeconds: Int = Int(AutomationLimits.actionSeconds)) throws -> Data {
        let deadline = try frameDeadline(seconds: timeoutSeconds)
        var header = [UInt8](repeating: 0, count: 4)
        try header.withUnsafeMutableBytes { try transfer(fd, bytes: $0, writing: false, deadline: deadline) }
        let n = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
        guard n > 0, n <= AutomationLimits.frameBytes else { throw Failure.protocolError }
        var payload = [UInt8](repeating: 0, count: Int(n))
        try payload.withUnsafeMutableBytes { try transfer(fd, bytes: $0, writing: false, deadline: deadline) }
        return Data(payload)
    }

    /// The hello contains only fresh opaque nonces; no command crosses the
    /// socket until both ends have authenticated their actual kernel peer.
    /// This binds a handshake to the selected application path; it is not a
    /// boot nonce, process identity, signature proof, or routing authority.
    static func applicationInstance(_ path: String) -> UUID {
        let canonical = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let bytes = Array(SHA256.hash(data: Data(canonical.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func clientExchange(_ fd: Int32, request: ControlRequest, instance: UUID,
                               validatePath: () throws -> Void, validateReply: (Data) throws -> Void) throws -> Data {
        try setTimeout(fd, seconds: Int(AutomationLimits.actionSeconds))
        let hello = try ControlProtocol.encodeHello(ControlHello(nonce: UUID(), instance: instance))
        try sendFrame(fd, hello)
        let acknowledgement = try receiveFrame(fd)
        guard try ControlProtocol.decodeHello(acknowledgement) == ControlProtocol.decodeHello(hello) else { throw Failure.protocolError }
        let originalPeer = try peer(fd)
        try validatePath()
        let command = try ControlProtocol.encodeRequest(request)
        do {
            try sendFrame(fd, command)
            let reply = try receiveFrame(fd, timeoutSeconds: Int(AutomationLimits.generationSeconds))
            guard samePeer(originalPeer, try peer(fd)) else { throw Failure.unsafe }
            try validatePath()
            try validateReply(reply)
            try sendFrame(fd, hello)
            let finalAcknowledgement = try receiveFrame(fd)
            guard try ControlProtocol.decodeHello(finalAcknowledgement) == ControlProtocol.decodeHello(hello) else { throw Failure.protocolError }
            guard samePeer(originalPeer, try peer(fd)) else { throw Failure.unsafe }
            try validatePath()
            // Keep the client alive until the server has sent its final ACK.
            try sendFrame(fd, hello)
            return reply
        } catch { throw Failure.indeterminate }
    }

    static func serverReceive(_ fd: Int32, instance: UUID) throws -> (ControlRequest, CSControlPeer, Data) {
        try setTimeout(fd, seconds: Int(AutomationLimits.actionSeconds))
        let hello = try receiveFrame(fd)
        guard try ControlProtocol.decodeHello(hello).instance == instance else { throw Failure.protocolError }
        let originalPeer = try peer(fd)
        try sendFrame(fd, hello)
        let request = try ControlProtocol.decodeRequest(receiveFrame(fd))
        guard samePeer(originalPeer, try peer(fd)) else { throw Failure.unsafe }
        return (request, originalPeer, hello)
    }

    static func serverReply(_ fd: Int32, reply: Data, peer originalPeer: CSControlPeer, hello: Data) throws {
        guard samePeer(originalPeer, try peer(fd)) else { throw Failure.unsafe }
        try sendFrame(fd, reply)
        try setTimeout(fd, seconds: Int(AutomationLimits.actionSeconds))
        let acknowledgement = try receiveFrame(fd)
        guard try ControlProtocol.decodeHello(acknowledgement) == ControlProtocol.decodeHello(hello),
              samePeer(originalPeer, try peer(fd)) else { throw Failure.unsafe }
        try sendFrame(fd, hello)
        let release = try receiveFrame(fd)
        guard try ControlProtocol.decodeHello(release) == ControlProtocol.decodeHello(hello) else { throw Failure.protocolError }
    }
}
