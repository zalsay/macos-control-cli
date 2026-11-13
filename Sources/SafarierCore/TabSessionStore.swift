import Foundation
import Darwin

public struct SavedTab: Codable, Equatable, Sendable {
    public var url: URL?
    public var title: String?

    public init(url: URL?, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

public struct SavedSessionWindow: Codable, Equatable, Sendable {
    public var tabs: [SavedTab]
    public var selectedTabIndex: Int

    public init(tabs: [SavedTab], selectedTabIndex: Int = 0) {
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
    }
}

public struct SavedSession: Codable, Equatable, Sendable {
    public var windows: [SavedSessionWindow]
    public var updatedAt: Date

    public init(windows: [SavedSessionWindow], updatedAt: Date = Date()) {
        self.windows = windows
        self.updatedAt = updatedAt
    }
}

public final class TabSessionStore {
    private struct Document: Codable {
        let version: Int
        let session: SavedSession
    }

    public enum Error: Swift.Error, LocalizedError {
        case io
        case unsafeStorage
        case unsupportedVersion

        public var errorDescription: String? {
            switch self {
            case .io: return "会话数据读写失败。"
            case .unsafeStorage: return "会话存储目录或文件安全校验失败。"
            case .unsupportedVersion: return "不支持的会话数据格式版本。"
            }
        }
    }

    public let directory: URL
    public let dataURL: URL
    public let lockURL: URL

    public init(workspace: SafarierWorkspace, profileID: UUID) {
        self.directory = workspace.sessionsDirectory
        self.dataURL = directory.appendingPathComponent("\(profileID.uuidString).json")
        self.lockURL = directory.appendingPathComponent("\(profileID.uuidString).lock")
    }

    public init(sessionsDirectory: URL, profileID: UUID) {
        self.directory = sessionsDirectory
        self.dataURL = directory.appendingPathComponent("\(profileID.uuidString).json")
        self.lockURL = directory.appendingPathComponent("\(profileID.uuidString).lock")
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(directory.path, 0o700)
        var d = stat()
        guard lstat(directory.path, &d) == 0, (d.st_mode & S_IFMT) == S_IFDIR, d.st_uid == geteuid(), (d.st_mode & 0o077) == 0 else {
            throw Error.unsafeStorage
        }
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Error.io }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)

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

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.io }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Error.io }
    }

    public func load() throws -> SavedSession? {
        try locked {
            let fd = open(dataURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if fd < 0 {
                if errno == ENOENT { return nil }
                throw Error.io
            }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1, (st.st_mode & 0o077) == 0 else {
                throw Error.unsafeStorage
            }
            let data = try file.readToEnd() ?? Data()
            guard !data.isEmpty else { return nil }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw Error.unsupportedVersion }
            return document.session
        }
    }

    public func save(_ session: SavedSession) throws {
        try locked {
            let data = try JSONEncoder().encode(Document(version: 1, session: session))
            let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw Error.io }
            defer { close(fd); unlink(temp.path) }

            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard n > 0 else { throw Error.io }
                    offset += n
                }
            }
            guard fsync(fd) == 0, rename(temp.path, dataURL.path) == 0 else { throw Error.io }
            try syncDirectory()
        }
    }

    public func clear() throws {
        try locked {
            if unlink(dataURL.path) != 0 && errno != ENOENT {
                throw Error.io
            }
            try syncDirectory()
        }
    }
}
