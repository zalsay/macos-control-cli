import Foundation
import Darwin

public struct AutomationSnapshotCleanup: Equatable, Sendable {
    public let removedFiles: Int
    public let retainedFiles: Int
    public let directoryRemoved: Bool
    public var cleaned: Bool { retainedFiles == 0 && directoryRemoved }
    public init(removedFiles: Int, retainedFiles: Int, directoryRemoved: Bool) { self.removedFiles = removedFiles; self.retainedFiles = retainedFiles; self.directoryRemoved = directoryRemoved }
}

/// Private per-instance artifacts. PNG validation is deliberately limited to the
/// signature and IHDR dimensions; callers must provide a trusted native encoder.
/// Path checks detect substitutions at check time, not a hostile same-UID race
/// after a URL is returned or between POSIX identity check and unlinkat.
public final class AutomationSnapshotStore: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "AutomationSnapshotStore(redacted)" }
    public var debugDescription: String { description }
    public static let lifetimeSeconds = 600.0
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ st: stat) { device = st.st_dev; inode = st.st_ino }
    }
    private struct Component {
        let fd: Int32; let parent: Int32?; let name: String; let identity: Identity
        let uid: uid_t; let gid: gid_t; let permissions: mode_t
        init(fd: Int32, parent: Int32?, name: String, stat: stat) {
            self.fd = fd; self.parent = parent; self.name = name; self.identity = Identity(stat)
            self.uid = stat.st_uid; self.gid = stat.st_gid; self.permissions = stat.st_mode & 0o7777
        }
        func matches(_ stat: stat) -> Bool {
            Identity(stat) == identity && stat.st_uid == uid && stat.st_gid == gid && (stat.st_mode & 0o7777) == permissions
        }
    }
    private struct Record { let name: String; let fd: Int32; let identity: Identity }
    private let lock = NSLock()
    private var chain: [Component] = []
    private var records: [Record] = []
    // A created name whose descriptor identity could not be established must not
    // be unlinked, but still consumes the bounded artifact budget.
    private var untrackedCreated = 0
    private let baseDirectory: URL
    private let workspaceRoot: URL?
    private let clock: @Sendable () -> Double
    private let writer: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    private var deadline: Double = 0
    private var lastTime: Double = 0
    private var successes = 0
    private var closedResult: AutomationSnapshotCleanup?
    private var directoryName = ""

    public convenience init(baseDirectory: URL, clock: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) throws {
        try self.init(baseDirectory: baseDirectory, clock: clock, writer: { Darwin.write($0, $1, $2) })
    }
    public convenience init(workspaceRoot: URL, clock: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) throws {
        try Self.validateWorkspaceURL(workspaceRoot)
        let base = workspaceRoot.appendingPathComponent("automation-artifacts", isDirectory: true)
        try self.init(baseDirectory: base, workspaceRoot: workspaceRoot, clock: clock, writer: { Darwin.write($0, $1, $2) })
    }
    // Test-only injection point for a partial write; not a wire or path API.
    internal convenience init(baseDirectory: URL, clock: @escaping @Sendable () -> Double, writer: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int) throws {
        try self.init(baseDirectory: baseDirectory, workspaceRoot: nil, clock: clock, writer: writer)
    }
    private init(baseDirectory: URL, workspaceRoot: URL?, clock: @escaping @Sendable () -> Double, writer: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int) throws {
        self.baseDirectory = baseDirectory; self.workspaceRoot = workspaceRoot; self.clock = clock; self.writer = writer
        let now = clock()
        guard now.isFinite, (now + Self.lifetimeSeconds).isFinite, baseDirectory.isFileURL, baseDirectory.path.hasPrefix("/"),
              let components = URLComponents(url: baseDirectory, resolvingAgainstBaseURL: false),
              (components.host == nil || components.host == ""), components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil else { throw AutomationError(code: .invalidRequest) }
        self.lastTime = now; self.deadline = now + Self.lifetimeSeconds
        do {
            if let workspaceRoot { try openTrustedBase(workspaceRoot, requirePrivate: false); try prepareArtifactBase() }
            else { try openTrustedBase(baseDirectory, requirePrivate: true) }
            try makeDirectory()
        } catch { for item in chain.reversed() { Darwin.close(item.fd) }; chain.removeAll(); throw AutomationError(code: .backendUnavailable) }
    }
    private static func validateWorkspaceURL(_ url: URL) throws {
        guard url.isFileURL, url.baseURL == nil, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "file", (c.host == nil || c.host == ""), c.user == nil, c.password == nil,
              c.port == nil, c.query == nil, c.fragment == nil, c.percentEncodedPath.hasPrefix("/") else { throw AutomationError(code: .invalidRequest) }
        let parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { throw AutomationError(code: .invalidRequest) }
        for raw in parts {
            guard let decoded = String(raw).removingPercentEncoding, decoded != ".", decoded != "..",
                  !decoded.utf8.contains(0), !decoded.contains("/") else { throw AutomationError(code: .invalidRequest) }
        }
    }
    deinit { _ = close() }
    private static func info(_ fd: Int32) throws -> stat {
        var st = stat(); guard fstat(fd, &st) == 0 else { throw AutomationError(code: .backendUnavailable) }; return st
    }
    private static func named(_ parent: Int32, _ name: String) throws -> stat {
        var st = stat(); guard name.withCString({ fstatat(parent, $0, &st, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw AutomationError(code: .backendUnavailable) }; return st
    }
    private static func isDirectory(_ st: stat) -> Bool { (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) }
    private static func isRegular(_ st: stat) -> Bool { (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) }
    private static func privateDirectory(_ st: stat) -> Bool { isDirectory(st) && st.st_uid == geteuid() && (st.st_mode & 0o7777) == 0o700 }
    private static func privateFile(_ st: stat) -> Bool { isRegular(st) && st.st_uid == geteuid() && (st.st_mode & 0o7777) == 0o600 && st.st_nlink == 1 }
    private static func noACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        _ = acl_free(UnsafeMutableRawPointer(acl))
        return false // Fail closed even if the filesystem returns an empty ACL object.
    }
    private static func clearACL(_ fd: Int32) throws {
        guard let acl = acl_init(1) else { throw AutomationError(code: .backendUnavailable) }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0, noACL(fd) else { throw AutomationError(code: .backendUnavailable) }
    }
    private func openTrustedBase(_ directory: URL, requirePrivate: Bool) throws {
        let raw = directory.path
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || $0.utf8.contains(0) }) else { throw AutomationError(code: .invalidRequest) }
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw AutomationError(code: .backendUnavailable) }
        let st: stat
        do { st = try Self.info(root) } catch { Darwin.close(root); throw error }
        guard Self.isDirectory(st) else { Darwin.close(root); throw AutomationError(code: .backendUnavailable) }
        chain.append(Component(fd: root, parent: nil, name: "/", stat: st))
        for name in parts {
            guard let parent = chain.last?.fd else { throw AutomationError(code: .backendUnavailable) }
            let fd = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard fd >= 0 else { throw AutomationError(code: .backendUnavailable) }
            do {
                let st = try Self.info(fd), named = try Self.named(parent, name)
                guard Self.isDirectory(st), Self.isDirectory(named), Identity(st) == Identity(named) else { throw AutomationError(code: .backendUnavailable) }
                chain.append(Component(fd: fd, parent: parent, name: name, stat: st))
            } catch { Darwin.close(fd); throw error }
        }
        guard let last = chain.last else { throw AutomationError(code: .backendUnavailable) }
        let info = try Self.info(last.fd)
        if requirePrivate {
            guard Self.privateDirectory(info) else { throw AutomationError(code: .backendUnavailable) }
        } else {
            guard Self.trustedWorkspace(info), Self.workspaceACLAllowsNoOtherWrites(last.fd) else { throw AutomationError(code: .backendUnavailable) }
        }
    }
    private static func trustedWorkspace(_ st: stat) -> Bool {
        isDirectory(st) && st.st_uid == geteuid() && (st.st_mode & 0o7022) == 0
    }
    // Conservative ACL proof: reject any allow entry with a write, delete,
    // security-change, ownership-change, or unknown permission bit.
    private static func workspaceACLAllowsNoOtherWrites(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        let safe = UInt64(ACL_READ_DATA.rawValue | ACL_EXECUTE.rawValue | ACL_READ_ATTRIBUTES.rawValue | ACL_READ_EXTATTRIBUTES.rawValue | ACL_READ_SECURITY.rawValue | ACL_SYNCHRONIZE.rawValue)
        for index in 0..<Int(ACL_MAX_ENTRIES) {
            var entry: acl_entry_t?
            errno = 0
            if acl_get_entry(acl, Int32(index), &entry) != 0 { return errno == EINVAL }
            guard let entry else { return false }
            var tag = ACL_UNDEFINED_TAG, mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &mask) == 0 else { return false }
            if tag == ACL_EXTENDED_ALLOW { if (mask & ~safe) != 0 { return false } }
            else if tag != ACL_EXTENDED_DENY { return false }
        }
        return true
    }
    private func prepareArtifactBase() throws {
        guard let workspace = chain.last, componentsValid(), Self.trustedWorkspace(try Self.info(workspace.fd)), Self.workspaceACLAllowsNoOtherWrites(workspace.fd) else { throw AutomationError(code: .backendUnavailable) }
        let name = "automation-artifacts"
        let result = name.withCString { mkdirat(workspace.fd, $0, 0o700) }
        let created = result == 0
        guard created || errno == EEXIST else { throw AutomationError(code: .backendUnavailable) }
        let fd = name.withCString { openat(workspace.fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw AutomationError(code: .backendUnavailable) }
        do {
            let opened = try Self.info(fd), named = try Self.named(workspace.fd, name)
            guard Self.isDirectory(opened), opened.st_uid == geteuid(), Identity(opened) == Identity(named), componentsValid() else { throw AutomationError(code: .backendUnavailable) }
            if created {
                guard fchmod(fd, 0o700) == 0 else { throw AutomationError(code: .backendUnavailable) }
                try Self.clearACL(fd)
            }
            let final = try Self.info(fd)
            guard Identity(final) == Identity(opened), Self.privateDirectory(final), Self.noACL(fd), componentsValid() else { throw AutomationError(code: .backendUnavailable) }
            chain.append(Component(fd: fd, parent: workspace.fd, name: name, stat: final))
        } catch { Darwin.close(fd); throw error }
    }
    private func makeDirectory() throws {
        guard let base = chain.last else { throw AutomationError(code: .backendUnavailable) }
        let name = UUID().uuidString.lowercased()
        guard name.withCString({ mkdirat(base.fd, $0, 0o700) }) == 0 else { throw AutomationError(code: .backendUnavailable) }
        let fd = name.withCString { openat(base.fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw AutomationError(code: .backendUnavailable) }
        var established: Identity?
        do {
            let st = try Self.info(fd), named = try Self.named(base.fd, name)
            guard Self.isDirectory(st), st.st_uid == geteuid(), Identity(st) == Identity(named) else { throw AutomationError(code: .backendUnavailable) }
            established = Identity(st)
            guard fchmod(fd, 0o700) == 0 else { throw AutomationError(code: .backendUnavailable) }
            try Self.clearACL(fd)
            let final = try Self.info(fd)
            guard Self.privateDirectory(final), Identity(final) == Identity(st) else { throw AutomationError(code: .backendUnavailable) }
            directoryName = name
            chain.append(Component(fd: fd, parent: base.fd, name: name, stat: final))
            guard verifyPath() else { throw AutomationError(code: .backendUnavailable) }
        } catch {
            // Remove only the empty object whose opened and named identities still match.
            if let established, let current = try? Self.named(base.fd, name), Self.isDirectory(current), Identity(current) == established {
                _ = name.withCString { unlinkat(base.fd, $0, AT_REMOVEDIR) }
            }
            if chain.last?.fd != fd { Darwin.close(fd) }
            throw error
        }
    }
    private func componentsValid() -> Bool {
        do {
            for component in chain {
                let opened = try Self.info(component.fd)
                guard Self.isDirectory(opened), component.matches(opened) else { return false }
                if let parent = component.parent {
                    let named = try Self.named(parent, component.name)
                    guard Self.isDirectory(named), component.matches(named) else { return false }
                }
            }
            return true
        } catch { return false }
    }
    private func verifyPath() -> Bool {
        guard chain.count >= 3, componentsValid() else { return false }
        do {
            let base = chain[chain.count - 2], dir = chain[chain.count - 1]
            let baseInfo = try Self.info(base.fd), dirInfo = try Self.info(dir.fd)
            guard Self.privateDirectory(baseInfo), Self.privateDirectory(dirInfo), Self.noACL(dir.fd) else { return false }
            if workspaceRoot != nil {
                guard chain.count >= 4 else { return false }
                let workspace = chain[chain.count - 3]
                guard Self.trustedWorkspace(try Self.info(workspace.fd)), Self.workspaceACLAllowsNoOtherWrites(workspace.fd), Self.noACL(base.fd) else { return false }
            }
            return true
        } catch { return false }
    }
    private func verifyFile(_ entry: Record, dir: Int32) -> Bool {
        do {
            let opened = try Self.info(entry.fd), named = try Self.named(dir, entry.name)
            return Self.privateFile(opened) && Self.privateFile(named) && Identity(opened) == entry.identity && Identity(named) == entry.identity && Self.noACL(entry.fd)
        } catch { return false }
    }
    private func validateTime() throws {
        guard closedResult == nil else { throw AutomationError(code: .sessionExpired) }
        let instant = clock()
        guard instant.isFinite, instant >= lastTime else { _ = closeLocked(); throw AutomationError(code: .invalidRequest) }
        lastTime = instant
        guard instant < deadline else { _ = closeLocked(); throw AutomationError(code: .sessionExpired) }
    }
    private func validate(_ png: Data, viewport v: AutomationViewport) throws {
        let values = [v.viewportWidthPoints, v.viewportHeightPoints, v.scaleX, v.scaleY, v.pageZoom]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }), v.pixelWidth > 0, v.pixelHeight > 0, v.pixelWidth <= AutomationLimits.screenshotMaxEdge, v.pixelHeight <= AutomationLimits.screenshotMaxEdge,
              png.count >= 33, png.count <= AutomationLimits.screenshotMaxBytes else { throw AutomationError(code: .invalidRequest) }
        let bytes = [UInt8](png.prefix(24))
        guard Array(bytes[0..<8]) == [137,80,78,71,13,10,26,10], Array(bytes[8..<16]) == [0,0,0,13,73,72,68,82] else { throw AutomationError(code: .invalidRequest) }
        func uint(_ i: Int) -> UInt32 { (UInt32(bytes[i]) << 24) | (UInt32(bytes[i+1]) << 16) | (UInt32(bytes[i+2]) << 8) | UInt32(bytes[i+3]) }
        guard UInt32(v.pixelWidth) == uint(16), UInt32(v.pixelHeight) == uint(20) else { throw AutomationError(code: .invalidRequest) }
        // Compare dimensionless relative error, not an absolute epsilon: tiny
        // scales must not acquire a disproportionately permissive tolerance.
        func agrees(_ supplied: Double, pixels: Int, points: Double) -> Bool {
            let expected = Double(pixels) / points
            guard expected.isFinite, expected > 0 else { return false }
            let relative = supplied / expected
            return relative.isFinite && abs(relative - 1) <= 1e-9
        }
        guard agrees(v.scaleX, pixels: v.pixelWidth, points: v.viewportWidthPoints),
              agrees(v.scaleY, pixels: v.pixelHeight, points: v.viewportHeightPoints) else { throw AutomationError(code: .invalidRequest) }
    }
    public func write(png: Data, viewport: AutomationViewport) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try validateTime(); try validate(png, viewport: viewport)
        guard successes < AutomationLimits.screenshotCount, records.count + untrackedCreated < AutomationLimits.screenshotCount else { throw AutomationError(code: .replayWindowFull) }
        guard verifyPath(), let dir = chain.last?.fd else { throw AutomationError(code: .backendUnavailable) }
        let name = UUID().uuidString.lowercased() + ".png"
        let fd = name.withCString { openat(dir, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw AutomationError(code: .backendUnavailable) }
        untrackedCreated += 1
        var tracked = false
        do {
            let st = try Self.info(fd), named = try Self.named(dir, name)
            guard Self.isRegular(st), st.st_uid == geteuid(), st.st_nlink == 1, Identity(st) == Identity(named) else { throw AutomationError(code: .backendUnavailable) }
            let entry = Record(name: name, fd: fd, identity: Identity(st)); records.append(entry); untrackedCreated -= 1; tracked = true
            guard fchmod(fd, 0o600) == 0 else { throw AutomationError(code: .backendUnavailable) }
            try Self.clearACL(fd)
            guard verifyPath(), verifyFile(entry, dir: dir) else { throw AutomationError(code: .backendUnavailable) }
            try png.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { throw AutomationError(code: .invalidRequest) }
                var offset = 0, interruptions = 0
                while offset < raw.count {
                    // A single kernel write cannot be preempted here; the caller
                    // must keep storage I/O off the main actor.
                    try validateTime()
                    let n = writer(fd, base.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR {
                        interruptions += 1
                        guard interruptions <= 64 else { throw AutomationError(code: .backendUnavailable) }
                        continue
                    }
                    guard n > 0 && n <= raw.count - offset else { throw AutomationError(code: .backendUnavailable) }
                    interruptions = 0
                    offset += n
                }
            }
            // A large or blocked write must not return a path after the fixed TTL.
            try validateTime()
            guard verifyPath(), verifyFile(entry, dir: dir) else { throw AutomationError(code: .backendUnavailable) }
            successes += 1
            return baseDirectory.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(name, isDirectory: false)
        } catch {
            if tracked, let index = records.firstIndex(where: { $0.fd == fd }), verifyPath(), verifyFile(records[index], dir: dir), name.withCString({ unlinkat(dir, $0, 0) }) == 0 {
                records.remove(at: index); Darwin.close(fd)
            } else if !tracked { Darwin.close(fd) }
            if let safe = error as? AutomationError, safe.code == .sessionExpired || safe.code == .invalidRequest { throw safe }
            throw AutomationError(code: .backendUnavailable)
        }
    }
    /// Expiry is enforced on calls; the owner must call tick when idle.
    public func tick() throws -> AutomationSnapshotCleanup? {
        lock.lock(); defer { lock.unlock() }
        if let result = closedResult { return result }
        let instant = clock()
        guard instant.isFinite, instant >= lastTime else { _ = closeLocked(); throw AutomationError(code: .invalidRequest) }
        lastTime = instant
        if instant >= deadline { return closeLocked() }
        return nil
    }
    @discardableResult public func close() -> AutomationSnapshotCleanup {
        lock.lock(); defer { lock.unlock() }; return closeLocked()
    }
    private func closeLocked() -> AutomationSnapshotCleanup {
        if let result = closedResult { return result }
        var removed = 0, retained = untrackedCreated, removedDirectory = false
        untrackedCreated = 0
        let safe = verifyPath()
        if let dir = chain.last?.fd {
            for entry in records {
                if safe && verifyFile(entry, dir: dir) && entry.name.withCString({ unlinkat(dir, $0, 0) }) == 0 { removed += 1 } else { retained += 1 }
                Darwin.close(entry.fd)
            }
            records.removeAll()
            if safe && chain.count >= 2, let own = chain.last, let parent = own.parent,
               let named = try? Self.named(parent, own.name), Identity(named) == own.identity, Self.privateDirectory(named),
               own.name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 { removedDirectory = true }
        } else { retained += records.count }
        for component in chain.reversed() { Darwin.close(component.fd) }
        chain.removeAll()
        let result = AutomationSnapshotCleanup(removedFiles: removed, retainedFiles: retained, directoryRemoved: removedDirectory)
        closedResult = result
        return result
    }
}
