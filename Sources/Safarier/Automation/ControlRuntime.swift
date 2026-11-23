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
    struct SocketIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let mode: UInt32
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        fileprivate init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(truncatingIfNeeded: value.st_ino)
            owner = UInt32(truncatingIfNeeded: value.st_uid)
            mode = UInt32(truncatingIfNeeded: value.st_mode)
            birthSeconds = Int64(value.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        }

        fileprivate init(device: UInt64, inode: UInt64, owner: UInt32, mode: UInt32,
                         birthSeconds: Int64, birthNanoseconds: Int64) {
            self.device = device; self.inode = inode; self.owner = owner; self.mode = mode
            self.birthSeconds = birthSeconds; self.birthNanoseconds = birthNanoseconds
        }
    }
    enum StartupSocketState: Sendable {
        case absent
        case active
        case stale(SocketIdentity)
    }
    private enum SocketProbe {
        case absent
        case connected(SocketIdentity)
        case refused(SocketIdentity)
    }

    /// The runtime directory itself is the cross-process advisory lock. The
    /// lock stays held for the entire daemon lifetime, not only through bind.
    /// A directory is intentionally used so a crash cannot orphan a separate
    /// lock inode and cause later processes to lock different files.
    final class StartupLock: @unchecked Sendable {
        fileprivate let runtime: ObjectIdentifier
        fileprivate let fd: Int32
        private let guardLock = NSLock()
        private var held = true

        fileprivate init(runtime: ObjectIdentifier, fd: Int32) {
            self.runtime = runtime
            self.fd = fd
        }

        fileprivate var isHeld: Bool {
            guardLock.lock(); defer { guardLock.unlock() }
            return held
        }

        func release() {
            guardLock.lock()
            let shouldRelease = held
            held = false
            guardLock.unlock()
            if shouldRelease {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
        }

        deinit { release() }
    }

    private let path: String
    private let directory: Int32
    private let device: dev_t
    private let inode: ino_t
    private static let socketName = "control.sock"
    private static let ownershipName = ".control.socket-owner"
    private static let ownershipRecordLimit = 256

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
    private func identity(_ value: stat) -> SocketIdentity { SocketIdentity(value) }
    private func validateStartupLock(_ lock: StartupLock) throws {
        guard lock.runtime == ObjectIdentifier(self), lock.isHeld else { throw Failure.unsafe }
        try validateRoot()
        var held = stat(), root = stat()
        guard fstat(lock.fd, &held) == 0, fstat(directory, &root) == 0,
              Self.same(held, root), held.st_dev == device, held.st_ino == inode else { throw Failure.unsafe }
    }

    /// Try to obtain the runtime lock for a bounded time. A nil result means a
    /// participating daemon/startup still owns it; other errors fail closed.
    func acquireStartupLock(waitSeconds: Double) throws -> StartupLock? {
        guard waitSeconds.isFinite, waitSeconds >= 0, waitSeconds <= 30 else { throw Failure.unsafe }
        try validateRoot()
        let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafe }
        var held = stat(), root = stat()
        guard fstat(fd, &held) == 0, fstat(directory, &root) == 0,
              Self.same(held, root), held.st_dev == device, held.st_ino == inode else {
            close(fd); throw Failure.unsafe
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(waitSeconds))
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                let lock = StartupLock(runtime: ObjectIdentifier(self), fd: fd)
                do { try validateStartupLock(lock); return lock }
                catch { lock.release(); throw error }
            }
            let error = errno
            if error == EINTR { continue }
            guard error == EWOULDBLOCK || error == EAGAIN else { close(fd); throw Failure.unsafe }
            guard ContinuousClock.now < deadline else { close(fd); return nil }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    /// Read-only socket probe. ECONNREFUSED is deliberately only a candidate:
    /// on Darwin it can also mean that a listening socket's backlog is full.
    private func probeSocket(lockedBy lock: StartupLock?) throws -> SocketProbe {
        if let lock { try validateStartupLock(lock) } else { try validateRoot() }
        var entry = stat()
        if fstatat(directory, Self.socketName, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.unsafe }
            try validateRoot()
            return .absent
        }
        guard (entry.st_mode & S_IFMT) == S_IFSOCK, entry.st_uid == geteuid(),
              entry.st_mode & 0o7777 == 0o600 else { throw Failure.unsafe }
        let pin = try socketStat()
        guard Self.same(entry, pin) else { throw Failure.unsafe }
        let fd = try newSocket()
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.unsafe }
        var addr = try address()
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let connectError = connected == 0 ? 0 : errno
        try validateRoot()
        let after = try socketStat()
        guard Self.same(pin, after) else { throw Failure.unsafe }
        if connected == 0 { return .connected(identity(after)) }
        guard connectError == ECONNREFUSED else { throw Failure.unsafe }
        return .refused(identity(after))
    }

    /// Call only while holding the runtime lock. A refused connect is stale
    /// only when the durable owner record proves that this exact socket inode
    /// was created by a prior lock-owning daemon. Untracked/legacy sockets are
    /// never unlinked automatically.
    func startupSocketState(lockedBy lock: StartupLock) throws -> StartupSocketState {
        try validateStartupLock(lock)
        switch try probeSocket(lockedBy: lock) {
        case .absent: return .absent
        case .connected: return .active
        case .refused(let observed):
            guard try readOwnershipRecord() == observed else { throw Failure.unsafe }
            return .stale(observed)
        }
    }

    /// Used by start callers when another participant currently owns the
    /// lifetime lock. It never recovers or deletes anything.
    func endpointIsConnectable() throws -> Bool {
        switch try probeSocket(lockedBy: nil) {
        case .absent, .refused: return false
        case .connected: return true
        }
    }

    private func readOwnershipRecord() throws -> SocketIdentity? {
        try validateRoot()
        let fd = openat(directory, Self.ownershipName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT else { throw Failure.unsafe }
            return nil
        }
        defer { close(fd) }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, fstatat(directory, Self.ownershipName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(held, named), (held.st_mode & S_IFMT) == S_IFREG,
              held.st_uid == geteuid(), held.st_mode & 0o7777 == 0o600,
              held.st_nlink == 1, held.st_size > 0, held.st_size <= off_t(Self.ownershipRecordLimit) else { throw Failure.unsafe }
        var bytes = [UInt8](repeating: 0, count: Int(held.st_size) + 1)
        let count = bytes.withUnsafeMutableBytes { raw in pread(fd, raw.baseAddress!, raw.count, 0) }
        guard count == held.st_size else { throw Failure.unsafe }
        try validateRoot()
        var after = stat()
        guard fstatat(directory, Self.ownershipName, &after, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(held, after) else { throw Failure.unsafe }
        guard let text = String(bytes: bytes.prefix(Int(count)), encoding: .utf8) else { throw Failure.unsafe }
        let fields = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count == 8, fields[0] == "1", fields[7].isEmpty,
              let device = UInt64(fields[1]), let inode = UInt64(fields[2]),
              let owner = UInt32(fields[3]), let mode = UInt32(fields[4]),
              let birthSeconds = Int64(fields[5]), let birthNanoseconds = Int64(fields[6]),
              birthSeconds > 0, birthNanoseconds >= 0, birthNanoseconds < 1_000_000_000 else { throw Failure.unsafe }
        return SocketIdentity(device: device, inode: inode, owner: owner, mode: mode,
                              birthSeconds: birthSeconds, birthNanoseconds: birthNanoseconds)
    }

    private func writeOwnershipRecord(_ pin: SocketIdentity, lockedBy lock: StartupLock) throws {
        try validateStartupLock(lock)
        let fd = openat(directory, Self.ownershipName, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unsafe }
        defer { close(fd) }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, fstatat(directory, Self.ownershipName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(held, named), (held.st_mode & S_IFMT) == S_IFREG,
              held.st_uid == geteuid(), held.st_mode & 0o7777 == 0o600, held.st_nlink == 1,
              held.st_size <= off_t(Self.ownershipRecordLimit) else { throw Failure.unsafe }
        let text = "1\n\(pin.device)\n\(pin.inode)\n\(pin.owner)\n\(pin.mode)\n\(pin.birthSeconds)\n\(pin.birthNanoseconds)\n"
        let bytes = Array(text.utf8)
        guard bytes.count <= Self.ownershipRecordLimit, ftruncate(fd, 0) == 0 else { throw Failure.unsafe }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in pwrite(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset)) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw Failure.unsafe }
            offset += written
        }
        guard fsync(fd) == 0, fstat(fd, &held) == 0,
              fstatat(directory, Self.ownershipName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(held, named), held.st_size == off_t(bytes.count) else { throw Failure.unsafe }
        try validateStartupLock(lock)
    }

    func removeStaleSocket(_ expected: SocketIdentity, lockedBy lock: StartupLock) throws {
        try validateStartupLock(lock)
        guard case .stale(let observed) = try startupSocketState(lockedBy: lock), observed == expected,
              try readOwnershipRecord() == expected else { throw Failure.unsafe }
        let current = try socketStat()
        guard identity(current) == expected else { throw Failure.unsafe }
        // All Safarier writers serialize on the private runtime directory lock,
        // and the runtime is mode 0700. POSIX has no unlink-by-inode syscall, so
        // a same-UID process deliberately ignoring this protocol could still
        // race the final unlinkat; that actor is outside this lock's guarantee.
        guard unlinkat(directory, Self.socketName, 0) == 0 else { throw Failure.unsafe }
        try validateRoot()
        var after = stat()
        guard fstatat(directory, Self.socketName, &after, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw Failure.unsafe }
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
    func listenSocket(lockedBy lock: StartupLock) throws -> (Int32, stat) {
        try validateStartupLock(lock)
        switch try startupSocketState(lockedBy: lock) {
        case .absent: break
        case .active: throw Failure.unsafe
        case .stale(let expected): try removeStaleSocket(expected, lockedBy: lock)
        }
        try validateStartupLock(lock)
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
            try validateStartupLock(lock)
            try writeOwnershipRecord(identity(pinned), lockedBy: lock)
            try validateStartupLock(lock)
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
    func removeOwnedSocket(_ pinned: stat, lockedBy lock: StartupLock) throws {
        try validateStartupLock(lock)
        try validateSocket(pinned)
        guard unlinkat(directory, Self.socketName, 0) == 0 else { throw Failure.unsafe }
    }
    /// A successful stop requires disappearance from the original runtime.
    /// A replaced directory or socket is not evidence that this stop completed.
    func waitForSocketRemoval(_ pinned: stat) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            try validateRoot()
            var current = stat()
            if fstatat(directory, Self.socketName, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw Failure.cleanupUnconfirmed }
                try validateRoot()
                return
            }
            guard Self.same(pinned, current) else { throw Failure.cleanupUnconfirmed }
            Thread.sleep(forTimeInterval: 0.025)
        } while ContinuousClock.now < deadline
        throw Failure.cleanupUnconfirmed
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
                               expectedPeerPID: Int32? = nil,
                               validatePath: () throws -> Void, validateReply: (Data) throws -> Void) throws -> Data {
        try setTimeout(fd, seconds: Int(AutomationLimits.actionSeconds))
        let hello = try ControlProtocol.encodeHello(ControlHello(nonce: UUID(), instance: instance))
        try sendFrame(fd, hello)
        let acknowledgement = try receiveFrame(fd)
        guard try ControlProtocol.decodeHello(acknowledgement) == ControlProtocol.decodeHello(hello) else { throw Failure.protocolError }
        let originalPeer = try peer(fd)
        if let expectedPeerPID, originalPeer.pid != expectedPeerPID { throw Failure.unsafe }
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
