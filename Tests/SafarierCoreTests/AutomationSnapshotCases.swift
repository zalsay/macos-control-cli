import Foundation
import Darwin
@testable import SafarierCore

public enum AutomationSnapshotCases {
    struct Failure: Error { let label: String }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0.0
        func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ x: Double) { lock.lock(); value = x; lock.unlock() }
    }
    final class Partial: @unchecked Sendable {
        private let lock = NSLock(); private var calls = 0
        func write(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
            lock.lock(); defer { lock.unlock() }; calls += 1
            if calls == 1 { return Darwin.write(fd, p, min(n, 4)) }
            errno = EIO; return -1
        }
    }
    final class RetainingWriter: @unchecked Sendable {
        private let lock = NSLock(); private var paths: [(String, String)] = []
        func write(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            var raw = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &raw) == 0 else { errno = EIO; return -1 }
            let original = String(cString: raw), other = original + ".link"
            guard link(original, other) == 0 else { errno = EIO; return -1 }
            paths.append((original, other))
            return Darwin.write(fd, p, n)
        }
        var recorded: [(String, String)] { lock.lock(); defer { lock.unlock() }; return paths }
    }
    final class InterruptingWriter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        let clock: Clock
        init(clock: Clock) { self.clock = clock }
        func write(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
            lock.lock(); count += 1; let current = count; lock.unlock()
            clock.set(Double(current * 100)); errno = current > 10 ? EIO : EINTR; return -1
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    final class EndlessInterrupt: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func write(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int { lock.lock(); value += 1; lock.unlock(); errno = EINTR; return -1 }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    final class ConcurrentResults: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func success() { lock.lock(); count += 1; lock.unlock() }
        var successes: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    static func hasACL(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return false }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }
    public static func run(base: URL) throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !value() { throw Failure(label: label) } }
        let clock = Clock()
        let viewport = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        // Signature + 13-byte IHDR + placeholder CRC; header-only, not a complete image.
        let png = Data([137,80,78,71,13,10,26,10, 0,0,0,13,73,72,68,82, 0,0,0,1,0,0,0,1, 8,6,0,0,0, 0,0,0,0])
        let store = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let path = try store.write(png: png, viewport: viewport)
        var file = stat(), dir = stat()
        try check(lstat(path.path, &file) == 0 && (file.st_mode & 0o777) == 0o600, "file mode")
        try check(lstat(path.deletingLastPathComponent().path, &dir) == 0 && (dir.st_mode & 0o777) == 0o700, "directory mode")
        try check((try? store.write(png: Data([0]), viewport: viewport)) == nil, "invalid png")
        let done = store.close()
        try check(done.cleaned && done.removedFiles == 1 && done.directoryRemoved, "registered cleanup")
        try check(store.close() == done, "idempotent close")
        try check((try? store.write(png: png, viewport: viewport)) == nil, "closed store")
        let expiring = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let expiringPath = try expiring.write(png: png, viewport: viewport)
        clock.set(600)
        let expired = try expiring.tick()
        try check(expired?.cleaned == true && access(expiringPath.path, F_OK) != 0, "exact ttl")
        clock.set(601)
        let invalidClock = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        clock.set(600)
        try check((try? invalidClock.tick()) == nil && invalidClock.close().cleaned, "backward clock closes")
        clock.set(700)
        let nanClock = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        clock.set(.nan)
        try check((try? nanClock.tick()) == nil && nanClock.close().cleaned, "nonfinite clock closes")
        clock.set(0)
        var anisotropicBytes = [UInt8](png)
        anisotropicBytes[19] = 200; anisotropicBytes[23] = 90
        let anisotropicPNG = Data(anisotropicBytes)
        let anisotropic = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 30, pixelWidth: 200, pixelHeight: 90, scaleX: 2, scaleY: 3, pageZoom: 1, viewVersion: 1)
        let wrongX = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 30, pixelWidth: 200, pixelHeight: 90, scaleX: 1, scaleY: 3, pageZoom: 1, viewVersion: 1)
        let wrongY = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 30, pixelWidth: 200, pixelHeight: 90, scaleX: 2, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let nearby = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 30, pixelWidth: 200, pixelHeight: 90, scaleX: 2 * (1 + 1e-10), scaleY: 3 * (1 - 1e-10), pageZoom: 1, viewVersion: 1)
        let outsideTolerance = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 30, pixelWidth: 200, pixelHeight: 90, scaleX: 2 * (1 + 1e-7), scaleY: 3, pageZoom: 1, viewVersion: 1)
        let overflowRatio = AutomationViewport(viewportWidthPoints: Double.leastNonzeroMagnitude, viewportHeightPoints: 30, pixelWidth: 200, pixelHeight: 90, scaleX: 2, scaleY: 3, pageZoom: 1, viewVersion: 1)
        let ratioStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        defer { _ = ratioStore.close() }
        try check((try? ratioStore.write(png: anisotropicPNG, viewport: wrongX)) == nil, "pixel-to-point scale X mismatch")
        try check((try? ratioStore.write(png: anisotropicPNG, viewport: wrongY)) == nil, "pixel-to-point scale Y mismatch")
        try check((try? ratioStore.write(png: anisotropicPNG, viewport: outsideTolerance)) == nil, "scale outside relative tolerance")
        try check((try? ratioStore.write(png: anisotropicPNG, viewport: overflowRatio)) == nil, "nonfinite calculated scale")
        var wrongPNG = anisotropicBytes; wrongPNG[19] = 201
        try check((try? ratioStore.write(png: Data(wrongPNG), viewport: anisotropic)) == nil, "PNG dimensions mismatch")
        try check((try? ratioStore.write(png: anisotropicPNG, viewport: anisotropic)) != nil, "anisotropic exact scale accepted")
        try check((try? ratioStore.write(png: anisotropicPNG, viewport: nearby)) != nil, "small relative rounding accepted")
        let ratioCleanup = ratioStore.close()
        try check(ratioCleanup.cleaned && ratioCleanup.removedFiles == 2, "scale rejections create no artifact")
        let limited = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        var limitPaths: [URL] = []
        for _ in 0..<AutomationLimits.screenshotCount { limitPaths.append(try limited.write(png: png, viewport: viewport)) }
        try check((try? limited.write(png: png, viewport: viewport)) == nil, "quota refuses ninth")
        try check(Set(limitPaths.map(\.lastPathComponent)).count == 8 && limited.close().removedFiles == 8, "unique names and quota cleanup")
        let invalid = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let huge = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 4097, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let zero = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 0, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let nonfinite = AutomationViewport(viewportWidthPoints: .infinity, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let mismatch = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 2, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        for value in [huge,zero,nonfinite,mismatch] { try check((try? invalid.write(png: png, viewport: value)) == nil, "invalid viewport rejected") }
        try check((try? invalid.write(png: Data(repeating: 0, count: AutomationLimits.screenshotMaxBytes + 1), viewport: viewport)) == nil, "bytes limit")
        try check(invalid.close().cleaned, "invalid data created no file")
        let longClock = Clock()
        let longStore = try AutomationSnapshotStore(baseDirectory: base, clock: { longClock.get() }, writer: { fd, ptr, count in longClock.set(600); return Darwin.write(fd, ptr, count) })
        try check((try? longStore.write(png: png, viewport: viewport)) == nil, "write crossing TTL cannot return path")
        try check(longStore.close().cleaned, "expired in-flight write cleaned")
        let interruptedClock = Clock(), interrupter = InterruptingWriter(clock: interruptedClock)
        let interruptedStore = try AutomationSnapshotStore(baseDirectory: base, clock: { interruptedClock.get() }, writer: { interrupter.write($0, $1, $2) })
        do { _ = try interruptedStore.write(png: png, viewport: viewport); throw Failure(label: "interrupted write accepted") }
        catch let error as AutomationError { try check(error.code == .sessionExpired && interrupter.calls == 6, "EINTR loop checks real TTL") }
        try check(interruptedStore.close().cleaned, "expired interrupted write cleaned")
        let endless = EndlessInterrupt(), stillClock = Clock()
        let endlessStore = try AutomationSnapshotStore(baseDirectory: base, clock: { stillClock.get() }, writer: { endless.write($0, $1, $2) })
        do { _ = try endlessStore.write(png: png, viewport: viewport); throw Failure(label: "endless EINTR accepted") }
        catch let error as AutomationError { try check(error.code == .backendUnavailable && endless.calls == 65, "EINTR bounded even when fake clock stalls") }
        try check(endlessStore.close().cleaned, "bounded EINTR cleaned")
        let retaining = RetainingWriter(), retainedStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() }, writer: { retaining.write($0, $1, $2) })
        defer {
            for (original, linkName) in retaining.recorded { _ = unlink(linkName); _ = unlink(original) }
            if let first = retaining.recorded.first { _ = rmdir(URL(fileURLWithPath: first.0).deletingLastPathComponent().path) }
        }
        for _ in 0..<AutomationLimits.screenshotCount { try check((try? retainedStore.write(png: png, viewport: viewport)) == nil, "unsafe file refused") }
        try check((try? retainedStore.write(png: png, viewport: viewport)) == nil && retaining.recorded.count == AutomationLimits.screenshotCount, "retained records bound before ninth create")
        let retainedClose = retainedStore.close()
        try check(retainedClose.retainedFiles == AutomationLimits.screenshotCount, "retained file count bounded")
        for (original, linkName) in retaining.recorded { _ = unlink(linkName); _ = unlink(original) }
        if let first = retaining.recorded.first { _ = rmdir(URL(fileURLWithPath: first.0).deletingLastPathComponent().path) }
        var urlComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        urlComponents.host = "example.invalid"
        let hostURL = urlComponents.url!
        urlComponents.user = "test"; urlComponents.port = 123
        let userPortURL = urlComponents.url!
        let queryURL = URL(string: base.absoluteString + "?query=1")!
        let fragmentURL = URL(string: base.absoluteString + "#fragment")!
        for url in [hostURL, userPortURL, queryURL, fragmentURL] {
            let candidate = try? AutomationSnapshotStore(baseDirectory: url, clock: { clock.get() })
            if let candidate { _ = candidate.close() }
            try check(candidate == nil, "ambiguous file URL rejected")
        }
        let partial = Partial(), partialStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() }, writer: { partial.write($0, $1, $2) })
        try check((try? partialStore.write(png: png, viewport: viewport)) == nil, "partial write error")
        try check(partialStore.close().cleaned, "partial write cleaned own file")
        let unknownStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let known = try unknownStore.write(png: png, viewport: viewport), unknown = known.deletingLastPathComponent().appendingPathComponent("foreign.txt")
        let unknownFD = open(unknown.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600); guard unknownFD >= 0 else { throw Failure(label: "unknown fixture") }; Darwin.close(unknownFD)
        let unknownClose = unknownStore.close()
        try check(unknownClose.removedFiles == 1 && !unknownClose.directoryRemoved && access(unknown.path, F_OK) == 0, "unknown file preserved")
        _ = unlink(unknown.path); _ = rmdir(unknown.deletingLastPathComponent().path)
        let symlinkStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let original = try symlinkStore.write(png: png, viewport: viewport), backup = original.deletingLastPathComponent().appendingPathComponent("saved.png")
        guard rename(original.path, backup.path) == 0, symlink("/dev/null", original.path) == 0 else { throw Failure(label: "file symlink fixture") }
        let substituted = symlinkStore.close()
        var linkStat = stat()
        try check(substituted.retainedFiles == 1 && lstat(original.path, &linkStat) == 0 && (linkStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK), "substituted symlink preserved")
        _ = unlink(original.path); _ = unlink(backup.path); _ = rmdir(original.deletingLastPathComponent().path)
        let inodeStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let inodePath = try inodeStore.write(png: png, viewport: viewport), inodeBackup = inodePath.deletingLastPathComponent().appendingPathComponent("original.png")
        guard rename(inodePath.path, inodeBackup.path) == 0 else { throw Failure(label: "inode rename fixture") }
        let replacementFD = open(inodePath.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600); guard replacementFD >= 0 else { throw Failure(label: "inode replacement fixture") }; Darwin.close(replacementFD)
        try check(inodeStore.close().retainedFiles == 1 && access(inodePath.path, F_OK) == 0, "inode replacement preserved")
        _ = unlink(inodePath.path); _ = unlink(inodeBackup.path); _ = rmdir(inodePath.deletingLastPathComponent().path)
        let fifoStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let fifoFile = try fifoStore.write(png: png, viewport: viewport), fifoBackup = fifoFile.deletingLastPathComponent().appendingPathComponent("saved.png")
        guard rename(fifoFile.path, fifoBackup.path) == 0, mkfifo(fifoFile.path, 0o600) == 0 else { throw Failure(label: "fifo substitution fixture") }
        var fifoStat = stat(); let fifoResult = fifoStore.close()
        try check(fifoResult.retainedFiles == 1 && lstat(fifoFile.path, &fifoStat) == 0 && (fifoStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO), "substituted FIFO preserved")
        _ = unlink(fifoFile.path); _ = unlink(fifoBackup.path); _ = rmdir(fifoFile.deletingLastPathComponent().path)
        let modeStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let modeFile = try modeStore.write(png: png, viewport: viewport)
        guard chmod(modeFile.path, 0o644) == 0 else { throw Failure(label: "file mode mutation") }
        try check(modeStore.close().retainedFiles == 1 && access(modeFile.path, F_OK) == 0, "changed file metadata preserved")
        _ = unlink(modeFile.path); _ = rmdir(modeFile.deletingLastPathComponent().path)
        let hardStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let hardPath = try hardStore.write(png: png, viewport: viewport), hardLink = hardPath.deletingLastPathComponent().appendingPathComponent("hardlink.png")
        guard link(hardPath.path, hardLink.path) == 0 else { throw Failure(label: "hardlink fixture") }
        try check(hardStore.close().retainedFiles == 1 && access(hardPath.path, F_OK) == 0 && access(hardLink.path, F_OK) == 0, "hardlinks preserved")
        _ = unlink(hardLink.path); _ = unlink(hardPath.path); _ = rmdir(hardPath.deletingLastPathComponent().path)
        let dirStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let dirPath = try dirStore.write(png: png, viewport: viewport), oldDir = dirPath.deletingLastPathComponent(), movedDir = base.appendingPathComponent("moved-" + UUID().uuidString)
        let foreignDir = base.appendingPathComponent("foreign-" + UUID().uuidString)
        guard mkdir(foreignDir.path, 0o700) == 0, rename(oldDir.path, movedDir.path) == 0, symlink(foreignDir.path, oldDir.path) == 0 else { throw Failure(label: "directory replacement fixture") }
        let sentinel = foreignDir.appendingPathComponent("sentinel")
        let sentinelFD = open(sentinel.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600); guard sentinelFD >= 0 else { throw Failure(label: "foreign fixture") }; Darwin.close(sentinelFD)
        try check((try? dirStore.write(png: png, viewport: viewport)) == nil, "renamed directory rejects write")
        try check(dirStore.close().retainedFiles == 1 && access(sentinel.path, F_OK) == 0, "replacement directory untouched")
        _ = unlink(oldDir.path); _ = unlink(movedDir.appendingPathComponent(dirPath.lastPathComponent).path); _ = rmdir(movedDir.path); _ = unlink(sentinel.path); _ = rmdir(foreignDir.path)
        let actualBase = base.appendingPathComponent("parent-" + UUID().uuidString), alias = base.appendingPathComponent("alias-" + UUID().uuidString)
        guard mkdir(actualBase.path, 0o700) == 0, symlink(actualBase.path, alias.path) == 0 else { throw Failure(label: "symlink parent fixture") }
        try check((try? AutomationSnapshotStore(baseDirectory: alias, clock: { clock.get() })) == nil, "symlink ancestor rejected")
        _ = unlink(alias.path); _ = rmdir(actualBase.path)
        let movedBase = base.appendingPathComponent("parent-" + UUID().uuidString), relocatedBase = base.appendingPathComponent("relocated-" + UUID().uuidString)
        guard mkdir(movedBase.path, 0o700) == 0 else { throw Failure(label: "base fixture") }
        let parentStore = try AutomationSnapshotStore(baseDirectory: movedBase, clock: { clock.get() }), parentFile = try parentStore.write(png: png, viewport: viewport)
        guard rename(movedBase.path, relocatedBase.path) == 0, mkdir(movedBase.path, 0o700) == 0 else { throw Failure(label: "parent rename fixture") }
        let parentSentinel = movedBase.appendingPathComponent("sentinel"), parentSentinelFD = open(parentSentinel.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard parentSentinelFD >= 0 else { throw Failure(label: "parent sentinel") }; Darwin.close(parentSentinelFD)
        try check((try? parentStore.write(png: png, viewport: viewport)) == nil && parentStore.close().retainedFiles == 1 && access(parentSentinel.path, F_OK) == 0, "parent rename rejects and preserves replacement")
        let relocatedDir = relocatedBase.appendingPathComponent(parentFile.deletingLastPathComponent().lastPathComponent)
        _ = unlink(relocatedDir.appendingPathComponent(parentFile.lastPathComponent).path); _ = rmdir(relocatedDir.path); _ = rmdir(relocatedBase.path); _ = unlink(parentSentinel.path); _ = rmdir(movedBase.path)
        let unsafeBase = base.appendingPathComponent("mode-" + UUID().uuidString)
        guard mkdir(unsafeBase.path, 0o755) == 0, chmod(unsafeBase.path, 0o755) == 0 else { throw Failure(label: "base mode fixture") }
        try check((try? AutomationSnapshotStore(baseDirectory: unsafeBase, clock: { clock.get() })) == nil, "untrusted base mode rejected")
        _ = rmdir(unsafeBase.path)
        let fifoBase = base.appendingPathComponent("fifo-" + UUID().uuidString)
        guard mkfifo(fifoBase.path, 0o600) == 0 else { throw Failure(label: "fifo fixture") }
        try check((try? AutomationSnapshotStore(baseDirectory: fifoBase, clock: { clock.get() })) == nil, "fifo base rejected")
        _ = unlink(fifoBase.path)
        let replacedStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let replacedFile = try replacedStore.write(png: png, viewport: viewport), replacedDir = replacedFile.deletingLastPathComponent(), savedDir = base.appendingPathComponent("saved-" + UUID().uuidString)
        guard rename(replacedDir.path, savedDir.path) == 0, mkdir(replacedDir.path, 0o700) == 0 else { throw Failure(label: "directory inode replacement fixture") }
        let replacementMarker = replacedDir.appendingPathComponent("sentinel"), replacementMarkerFD = open(replacementMarker.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard replacementMarkerFD >= 0 else { throw Failure(label: "directory sentinel") }; Darwin.close(replacementMarkerFD)
        try check((try? replacedStore.write(png: png, viewport: viewport)) == nil && replacedStore.close().retainedFiles == 1 && access(replacementMarker.path, F_OK) == 0, "directory inode replacement preserved")
        _ = unlink(savedDir.appendingPathComponent(replacedFile.lastPathComponent).path); _ = rmdir(savedDir.path); _ = unlink(replacementMarker.path); _ = rmdir(replacedDir.path)
        func openDescriptorCount() -> Int { (0..<1024).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
        let warm = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() }); _ = try warm.write(png: png, viewport: viewport); _ = warm.close()
        let beforeFDs = openDescriptorCount()
        let beforeSet = Set((0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 })
        let pinned = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() }); _ = try pinned.write(png: png, viewport: viewport)
        let opened = Set((0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }).subtracting(beforeSet)
        try check(!opened.isEmpty && opened.allSatisfy { (fcntl(Int32($0), F_GETFD) & FD_CLOEXEC) != 0 }, "owned descriptors close-on-exec")
        _ = pinned.close()
        for _ in 0..<20 { let sample = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() }); _ = try sample.write(png: png, viewport: viewport); _ = sample.close() }
        try check(openDescriptorCount() == beforeFDs, "owned descriptor lifetime")
        do { _ = try AutomationSnapshotStore(baseDirectory: alias, clock: { clock.get() }); throw Failure(label: "unsafe path accepted") }
        catch let error as AutomationError { try check(!String(reflecting: error).contains(base.path), "error path redacted") }
        let metadataParent = base.appendingPathComponent("metadata-parent-" + UUID().uuidString), metadataBase = metadataParent.appendingPathComponent("base")
        guard mkdir(metadataParent.path, 0o700) == 0, mkdir(metadataBase.path, 0o700) == 0 else { throw Failure(label: "metadata ancestor fixture") }
        let metadataStore = try AutomationSnapshotStore(baseDirectory: metadataBase, clock: { clock.get() }), metadataFile = try metadataStore.write(png: png, viewport: viewport)
        guard chmod(metadataParent.path, 0o755) == 0 else { throw Failure(label: "ancestor metadata mutation") }
        try check((try? metadataStore.write(png: png, viewport: viewport)) == nil, "ancestor metadata change rejected")
        _ = metadataStore.close()
        _ = chmod(metadataParent.path, 0o700); _ = unlink(metadataFile.path); _ = rmdir(metadataFile.deletingLastPathComponent().path); _ = rmdir(metadataBase.path); _ = rmdir(metadataParent.path)
        let aclBase = base.appendingPathComponent("acl-" + UUID().uuidString)
        guard mkdir(aclBase.path, 0o700) == 0 else { throw Failure(label: "ACL fixture directory") }
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["+a", "everyone allow read,file_inherit,directory_inherit", aclBase.path]; chmod.standardOutput = FileHandle.nullDevice; chmod.standardError = FileHandle.nullDevice
        try chmod.run(); chmod.waitUntilExit(); guard chmod.terminationStatus == 0 && hasACL(aclBase.path) else { throw Failure(label: "inherited ACL unavailable") }
        let aclStore = try AutomationSnapshotStore(baseDirectory: aclBase, clock: { clock.get() }), aclFile = try aclStore.write(png: png, viewport: viewport)
        try check(!hasACL(aclFile.path) && !hasACL(aclFile.deletingLastPathComponent().path) && hasACL(aclBase.path), "inherited ACL removed only on owned objects")
        try check(aclStore.close().cleaned && hasACL(aclBase.path), "ACL base remains untouched")
        _ = rmdir(aclBase.path)
        let changedACLStore = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        let changedACLFile = try changedACLStore.write(png: png, viewport: viewport)
        let aclMutate = Process(); aclMutate.executableURL = URL(fileURLWithPath: "/bin/chmod"); aclMutate.arguments = ["+a", "everyone allow read", changedACLFile.path]; aclMutate.standardOutput = FileHandle.nullDevice; aclMutate.standardError = FileHandle.nullDevice
        try aclMutate.run(); aclMutate.waitUntilExit(); guard aclMutate.terminationStatus == 0, hasACL(changedACLFile.path) else { throw Failure(label: "file ACL mutation") }
        try check(changedACLStore.close().retainedFiles == 1 && hasACL(changedACLFile.path), "changed file ACL preserved")
        _ = unlink(changedACLFile.path); _ = rmdir(changedACLFile.deletingLastPathComponent().path)
        let concurrent = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() }), results = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 24) { i in if i == 12 { _ = concurrent.close() } else if (try? concurrent.write(png: png, viewport: viewport)) != nil { results.success() } }
        let concurrentClose = concurrent.close()
        try check(results.successes <= 8 && concurrentClose.cleaned && concurrentClose.removedFiles == results.successes, "concurrent writes and close serialized")
        try check(!String(reflecting: concurrent).contains(base.path), "description redacted")
        return checks
    }
}
