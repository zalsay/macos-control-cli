import Foundation
import Darwin
@testable import SafarierCore

public enum ArtifactBaseCases {
    struct Failure: Error { let label: String }
    final class Stores: @unchecked Sendable {
        private let lock = NSLock(); private var values: [AutomationSnapshotStore] = []
        func append(_ store: AutomationSnapshotStore) { lock.lock(); values.append(store); lock.unlock() }
        var snapshot: [AutomationSnapshotStore] { lock.lock(); defer { lock.unlock() }; return values }
    }
    static func hasACL(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return false }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }
    static func addACL(_ path: String, _ rule: String) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod"); p.arguments = ["+a", rule, path]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw Failure(label: "ACL fixture") }
    }
    public static func run(root: URL) throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws { count += 1; if !value() { throw Failure(label: label) } }
        let workspace = root.appendingPathComponent("workspace")
        guard mkdir(workspace.path, 0o755) == 0, chmod(workspace.path, 0o755) == 0 else { throw Failure(label: "workspace fixture") }
        let base = workspace.appendingPathComponent("automation-artifacts")
        let store = try AutomationSnapshotStore(workspaceRoot: workspace)
        var info = stat()
        try check(lstat(base.path, &info) == 0 && (info.st_mode & 0o777) == 0o700 && info.st_uid == geteuid(), "created base is private")
        let second = try AutomationSnapshotStore(workspaceRoot: workspace)
        let png = Data([137,80,78,71,13,10,26,10, 0,0,0,13,73,72,68,82, 0,0,0,1,0,0,0,1, 8,6,0,0,0, 0,0,0,0])
        let view = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let firstFile = try store.write(png: png, viewport: view), secondFile = try second.write(png: png, viewport: view)
        try check(firstFile.deletingLastPathComponent() != secondFile.deletingLastPathComponent(), "separate instance directories")
        try check(store.close().cleaned && access(secondFile.path, F_OK) == 0, "one close preserves other instance")
        try check(second.close().cleaned, "second instance cleanup")
        try check(lstat(base.path, &info) == 0, "base persists")
        let existingStat = info
        let existing = try AutomationSnapshotStore(workspaceRoot: workspace)
        try check(existing.close().cleaned && lstat(base.path, &info) == 0 && info.st_ino == existingStat.st_ino && info.st_mode == existingStat.st_mode, "existing private base reused unchanged")
        _ = rmdir(base.path); _ = rmdir(workspace.path)
        func makeWorkspace(_ name: String, mode: mode_t = 0o755) throws -> URL {
            let u = root.appendingPathComponent(name)
            guard mkdir(u.path, mode) == 0, chmod(u.path, mode) == 0 else { throw Failure(label: "workspace mkdir") }
            return u
        }
        let sentinelData = Data("fixture-only".utf8)
        let symlinkRoot = try makeWorkspace("symlink")
        let foreign = root.appendingPathComponent("foreign")
        guard mkdir(foreign.path, 0o700) == 0 else { throw Failure(label: "foreign mkdir") }
        let foreignSentinel = foreign.appendingPathComponent("sentinel"); try sentinelData.write(to: foreignSentinel)
        let alias = symlinkRoot.appendingPathComponent("automation-artifacts")
        guard symlink(foreign.path, alias.path) == 0 else { throw Failure(label: "base symlink") }
        try check((try? AutomationSnapshotStore(workspaceRoot: symlinkRoot)) == nil && (try? Data(contentsOf: foreignSentinel)) == sentinelData, "existing symlink rejected without touching target")
        var linkInfo = stat(); try check(lstat(alias.path, &linkInfo) == 0 && (linkInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK), "existing symlink preserved")
        _ = unlink(alias.path); _ = rmdir(symlinkRoot.path); _ = unlink(foreignSentinel.path); _ = rmdir(foreign.path)
        let fileRoot = try makeWorkspace("file")
        let badFile = fileRoot.appendingPathComponent("automation-artifacts"); try sentinelData.write(to: badFile)
        var fileBefore = stat(), fileAfter = stat(); _ = lstat(badFile.path, &fileBefore)
        try check((try? AutomationSnapshotStore(workspaceRoot: fileRoot)) == nil && (try? Data(contentsOf: badFile)) == sentinelData, "existing file rejected")
        try check(lstat(badFile.path, &fileAfter) == 0 && fileAfter.st_ino == fileBefore.st_ino && fileAfter.st_mode == fileBefore.st_mode, "existing file unchanged")
        _ = unlink(badFile.path); _ = rmdir(fileRoot.path)
        let modeRoot = try makeWorkspace("mode")
        let badMode = modeRoot.appendingPathComponent("automation-artifacts")
        guard mkdir(badMode.path, 0o755) == 0, chmod(badMode.path, 0o755) == 0 else { throw Failure(label: "bad mode fixture") }
        let modeSentinel = badMode.appendingPathComponent("sentinel"); try sentinelData.write(to: modeSentinel)
        var modeBefore = stat(), modeAfter = stat(); _ = lstat(badMode.path, &modeBefore)
        try check((try? AutomationSnapshotStore(workspaceRoot: modeRoot)) == nil && (try? Data(contentsOf: modeSentinel)) == sentinelData, "existing bad mode rejected")
        try check(lstat(badMode.path, &modeAfter) == 0 && modeAfter.st_mode == modeBefore.st_mode && modeAfter.st_ino == modeBefore.st_ino, "bad mode base never chmod")
        _ = unlink(modeSentinel.path); _ = rmdir(badMode.path); _ = rmdir(modeRoot.path)
        let aclRoot = try makeWorkspace("acl")
        let aclBase = aclRoot.appendingPathComponent("automation-artifacts")
        guard mkdir(aclBase.path, 0o700) == 0 else { throw Failure(label: "ACL base mkdir") }
        let aclSentinel = aclBase.appendingPathComponent("sentinel"); try sentinelData.write(to: aclSentinel)
        try addACL(aclBase.path, "everyone allow read")
        var aclBefore = stat(), aclAfter = stat(); _ = lstat(aclBase.path, &aclBefore)
        try check(hasACL(aclBase.path) && (try? AutomationSnapshotStore(workspaceRoot: aclRoot)) == nil && (try? Data(contentsOf: aclSentinel)) == sentinelData, "existing ACL base rejected")
        try check(hasACL(aclBase.path) && lstat(aclBase.path, &aclAfter) == 0 && aclAfter.st_ino == aclBefore.st_ino && aclAfter.st_mode == aclBefore.st_mode, "existing ACL and metadata preserved")
        _ = unlink(aclSentinel.path); _ = rmdir(aclBase.path); _ = rmdir(aclRoot.path)
        let writableRoot = try makeWorkspace("writable", mode: 0o775)
        let writableSentinel = writableRoot.appendingPathComponent("sentinel"); try sentinelData.write(to: writableSentinel)
        try check((try? AutomationSnapshotStore(workspaceRoot: writableRoot)) == nil && (try? Data(contentsOf: writableSentinel)) == sentinelData, "group-writable workspace rejected")
        _ = unlink(writableSentinel.path); _ = rmdir(writableRoot.path)
        let allowRoot = try makeWorkspace("inherit")
        try addACL(allowRoot.path, "everyone allow read,file_inherit,directory_inherit")
        let inheritBase = allowRoot.appendingPathComponent("automation-artifacts")
        let inherited = try AutomationSnapshotStore(workspaceRoot: allowRoot)
        try check(hasACL(allowRoot.path) && !hasACL(inheritBase.path), "new base strips inherited ACL only")
        try check(inherited.close().cleaned && hasACL(allowRoot.path), "workspace ACL unchanged")
        _ = rmdir(inheritBase.path); _ = rmdir(allowRoot.path)
        let grantRoot = try makeWorkspace("grant")
        try addACL(grantRoot.path, "everyone allow add_file")
        try check(hasACL(grantRoot.path) && (try? AutomationSnapshotStore(workspaceRoot: grantRoot)) == nil && hasACL(grantRoot.path), "workspace write-grant ACL rejected unchanged")
        _ = rmdir(grantRoot.path)
        let concurrentRoot = try makeWorkspace("concurrent")
        let stores = Stores()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in if let s = try? AutomationSnapshotStore(workspaceRoot: concurrentRoot) { stores.append(s) } }
        let instances = stores.snapshot
        try check(instances.count == 8, "simultaneous stores initialized")
        var paths: [URL] = []
        for instance in instances { paths.append(try instance.write(png: png, viewport: view)) }
        try check(Set(paths.map { $0.deletingLastPathComponent().lastPathComponent }).count == instances.count, "concurrent own UUID directories")
        if let first = instances.first { _ = first.close() }
        try check(paths.dropFirst().allSatisfy { access($0.path, F_OK) == 0 }, "concurrent close cannot touch siblings")
        for instance in instances.dropFirst() { _ = instance.close() }
        let concurrentBase = concurrentRoot.appendingPathComponent("automation-artifacts")
        try check(access(concurrentBase.path, F_OK) == 0, "concurrent base persists")
        _ = rmdir(concurrentBase.path); _ = rmdir(concurrentRoot.path)
        let renamedRoot = try makeWorkspace("renamed-root"), movedRoot = root.appendingPathComponent("moved-root")
        let beforeRename = try AutomationSnapshotStore(workspaceRoot: renamedRoot)
        let savedFile = try beforeRename.write(png: png, viewport: view)
        guard rename(renamedRoot.path, movedRoot.path) == 0, mkdir(renamedRoot.path, 0o755) == 0 else { throw Failure(label: "root substitution fixture") }
        let rootMarker = renamedRoot.appendingPathComponent("sentinel"); try sentinelData.write(to: rootMarker)
        try check((try? beforeRename.write(png: png, viewport: view)) == nil && beforeRename.close().retainedFiles == 1 && (try? Data(contentsOf: rootMarker)) == sentinelData, "root replacement preserves foreign sentinel")
        let movedBase = movedRoot.appendingPathComponent("automation-artifacts"), movedOwned = movedBase.appendingPathComponent(savedFile.deletingLastPathComponent().lastPathComponent)
        _ = unlink(movedOwned.appendingPathComponent(savedFile.lastPathComponent).path); _ = rmdir(movedOwned.path); _ = rmdir(movedBase.path); _ = rmdir(movedRoot.path); _ = unlink(rootMarker.path); _ = rmdir(renamedRoot.path)
        let replacedRoot = try makeWorkspace("replaced-base"), replacedStore = try AutomationSnapshotStore(workspaceRoot: replacedRoot)
        let replacedFile = try replacedStore.write(png: png, viewport: view), replacedBase = replacedRoot.appendingPathComponent("automation-artifacts"), savedBase = replacedRoot.appendingPathComponent("saved-base")
        guard rename(replacedBase.path, savedBase.path) == 0, mkdir(replacedBase.path, 0o700) == 0 else { throw Failure(label: "base substitution fixture") }
        let replacementSentinel = replacedBase.appendingPathComponent("sentinel"); try sentinelData.write(to: replacementSentinel)
        try check((try? replacedStore.write(png: png, viewport: view)) == nil && replacedStore.close().retainedFiles == 1 && (try? Data(contentsOf: replacementSentinel)) == sentinelData, "base replacement preserves foreign sentinel")
        let savedOwned = savedBase.appendingPathComponent(replacedFile.deletingLastPathComponent().lastPathComponent)
        _ = unlink(savedOwned.appendingPathComponent(replacedFile.lastPathComponent).path); _ = rmdir(savedOwned.path); _ = rmdir(savedBase.path); _ = unlink(replacementSentinel.path); _ = rmdir(replacedBase.path); _ = rmdir(replacedRoot.path)
        let changedRoot = try makeWorkspace("changed-acl"), changedStore = try AutomationSnapshotStore(workspaceRoot: changedRoot)
        let changedFile = try changedStore.write(png: png, viewport: view)
        try addACL(changedRoot.path, "everyone allow add_file")
        try check((try? changedStore.write(png: png, viewport: view)) == nil && changedStore.close().retainedFiles == 1 && hasACL(changedRoot.path), "new workspace write ACL closes path use")
        _ = unlink(changedFile.path); _ = rmdir(changedFile.deletingLastPathComponent().path); _ = rmdir(changedRoot.appendingPathComponent("automation-artifacts").path); _ = rmdir(changedRoot.path)
        let rootTarget = try makeWorkspace("root-target"), rootAlias = root.appendingPathComponent("root-alias")
        guard symlink(rootTarget.path, rootAlias.path) == 0 else { throw Failure(label: "root symlink") }
        try check((try? AutomationSnapshotStore(workspaceRoot: rootAlias)) == nil && access(rootTarget.appendingPathComponent("automation-artifacts").path, F_OK) != 0, "workspace symlink rejected")
        _ = unlink(rootAlias.path); _ = rmdir(rootTarget.path)
        let parentTarget = try makeWorkspace("parent-target"), nested = parentTarget.appendingPathComponent("nested")
        guard mkdir(nested.path, 0o755) == 0 else { throw Failure(label: "parent symlink nested") }
        let parentAlias = root.appendingPathComponent("parent-alias")
        guard symlink(parentTarget.path, parentAlias.path) == 0 else { throw Failure(label: "parent symlink") }
        try check((try? AutomationSnapshotStore(workspaceRoot: parentAlias.appendingPathComponent("nested"))) == nil && access(nested.appendingPathComponent("automation-artifacts").path, F_OK) != 0, "ancestor symlink rejected")
        func descriptorCount() -> Int { (0..<1024).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
        let descriptorBefore = descriptorCount()
        for _ in 0..<20 { _ = try? AutomationSnapshotStore(workspaceRoot: parentAlias.appendingPathComponent("nested")) }
        try check(descriptorCount() == descriptorBefore, "failed path validation closes descriptors")
        _ = unlink(parentAlias.path); _ = rmdir(nested.path); _ = rmdir(parentTarget.path)
        let normalPath = root.absoluteString
        let badURLs = [URL(string: normalPath + "../escaped")!, URL(string: normalPath + "./escaped")!, URL(string: normalPath + "%2e%2e/escaped")!, URL(string: normalPath + "%00/escaped")!, URL(string: normalPath + "%2fescaped")!, URL(string: normalPath + "?x=1")!, URL(string: normalPath + "#x")!, URL(string: "file://example.invalid/tmp/x")!, URL(string: "file://synthetic@example.invalid:123/tmp/x")!, URL(string: "https://example.invalid/path")!]
        for u in badURLs { try check((try? AutomationSnapshotStore(workspaceRoot: u)) == nil, "raw unsafe URL rejected") }
        let invalidClockRoot = try makeWorkspace("invalid-clock")
        try check((try? AutomationSnapshotStore(workspaceRoot: invalidClockRoot, clock: { .nan })) == nil && access(invalidClockRoot.appendingPathComponent("automation-artifacts").path, F_OK) != 0, "invalid clock before base creation")
        _ = rmdir(invalidClockRoot.path)
        return count
    }
}
