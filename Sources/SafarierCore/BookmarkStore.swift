import Foundation
import Darwin

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    public init(id: UUID = UUID(), title: String, url: URL) throws {
        self.id = id; self.title = title; self.url = url
        try validate()
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 512, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { throw BookmarkStore.Error.invalidBookmark }
    }
}

/// Per-profile bookmarks are user configuration, including for ephemeral profiles.
public final class BookmarkStore {
    public struct Snapshot: Codable, Equatable, Sendable {
        public let revision: UUID
        public let items: [Bookmark]
    }
    private struct Document: Codable { let version: Int; let snapshot: Snapshot }
    public enum Error: Swift.Error, LocalizedError {
        case invalidBookmark, profileMissing, conflict, unsafeStorage, unsupportedVersion, io, profileDeletedCleanupFailed, deletionInterrupted
        public var errorDescription: String? {
            switch self {
            case .profileDeletedCleanupFailed: return "环境已删除，但收藏数据清理失败；请检查工作区后重试清理。"
            case .profileMissing: return "环境不存在或已删除。"
            case .deletionInterrupted: return "收藏删除可能中断，已阻止写入；请检查环境删除状态。"
            case .conflict: return "收藏已在其他进程更改，请刷新后重试。"
            case .invalidBookmark: return "标题或网址无效，仅支持不含用户凭据的 HTTP(S) 网址。"
            default: return "收藏数据无法安全读写。"
            }
        }
    }
    private static let emptyRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private let workspace: SafarierWorkspace
    private let profileID: UUID
    private var directory: URL { workspace.root.appendingPathComponent("bookmarks", isDirectory: true) }
    private var dataURL: URL { directory.appendingPathComponent(profileID.uuidString + ".json") }
    private var lockURL: URL { directory.appendingPathComponent(profileID.uuidString + ".lock") }
    private var tombstoneURL: URL { directory.appendingPathComponent(profileID.uuidString + ".deleted") }
    public init(workspace: SafarierWorkspace, profileID: UUID) { self.workspace = workspace; self.profileID = profileID }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var d = stat()
        guard lstat(directory.path, &d) == 0, (d.st_mode & S_IFMT) == S_IFDIR, d.st_uid == geteuid(), (d.st_mode & 0o077) == 0 else { throw Error.unsafeStorage }
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Error.io }
        defer { close(fd) }
        func valid() -> Bool {
            var held = stat(), named = stat()
            return fstat(fd, &held) == 0 && lstat(lockURL.path, &named) == 0 &&
                (held.st_mode & S_IFMT) == S_IFREG && held.st_uid == geteuid() && held.st_nlink == 1 &&
                (held.st_mode & 0o077) == 0 && held.st_dev == named.st_dev && held.st_ino == named.st_ino
        }
        guard valid(), flock(fd, LOCK_EX) == 0 else { throw Error.unsafeStorage }
        defer { flock(fd, LOCK_UN) }
        guard valid() else { throw Error.unsafeStorage }
        return try body()
    }
    private func requireProfile() throws {
        var st = stat()
        let markerExists = lstat(tombstoneURL.path, &st) == 0
        if !markerExists && errno != ENOENT { throw Error.unsafeStorage }
        let profileExists = try workspace.profiles.record(id: profileID) != nil
        if markerExists { throw profileExists ? Error.deletionInterrupted : Error.profileMissing }
        guard profileExists else { throw Error.profileMissing }
    }
    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.io }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Error.io }
    }
    private func read() throws -> Snapshot {
        let fd = open(dataURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return Snapshot(revision: Self.emptyRevision, items: []) }; throw Error.io }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1, (st.st_mode & 0o077) == 0 else { throw Error.unsafeStorage }
        let data = try file.readToEnd() ?? Data()
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw Error.unsupportedVersion }
        for item in document.snapshot.items { try item.validate() }
        guard Set(document.snapshot.items.map(\.id)).count == document.snapshot.items.count else { throw Error.invalidBookmark }
        return document.snapshot
    }
    public func load() throws -> Snapshot { try locked { try requireProfile(); return try read() } }
    public func save(_ items: [Bookmark], expectedRevision: UUID) throws -> Snapshot {
        try locked {
            try requireProfile()
            let current = try read()
            guard current.revision == expectedRevision else { throw Error.conflict }
            for item in items { try item.validate() }
            guard Set(items.map(\.id)).count == items.count else { throw Error.invalidBookmark }
            let snapshot = Snapshot(revision: UUID(), items: items)
            let data = try JSONEncoder().encode(Document(version: 1, snapshot: snapshot))
            let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw Error.io }
            defer { close(fd); unlink(temp.path) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard n > 0 else { throw Error.io }; offset += n
                }
            }
            guard fsync(fd) == 0, rename(temp.path, dataURL.path) == 0 else { throw Error.io }
            try syncDirectory()
            return snapshot
        }
    }
    /// The profile removal and bookmark cleanup share the same transaction lock.
    /// If cleanup fails after profile deletion, the error is propagated for reporting.
    public func deleteProfile<T>(_ remove: () throws -> T) throws -> T {
        try locked {
            try requireProfile()
            let marker = open(tombstoneURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard marker >= 0 else { throw Error.io }
            let persisted = fsync(marker) == 0
            close(marker)
            guard persisted else { _ = unlink(tombstoneURL.path); throw Error.io }
            do { try syncDirectory() } catch { _ = unlink(tombstoneURL.path); throw error }
            let result: T
            do { result = try remove() }
            catch {
                if unlink(tombstoneURL.path) != 0 { throw Error.unsafeStorage }
                throw error
            }
            if unlink(dataURL.path) != 0 && errno != ENOENT { throw Error.profileDeletedCleanupFailed }
            do { try syncDirectory() } catch { throw Error.profileDeletedCleanupFailed }
            return result
        }
    }
}
