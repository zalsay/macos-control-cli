import Foundation
import Darwin

/// 通用的本地 JSON 元数据存储：带版本号，原子写入，文件不存在时视为空列表。
/// 只用于非敏感元数据（Profile、ProxySettings 引用信息），绝不用于保存密码。
public final class JSONDocumentStore<Record: Codable & Sendable>: @unchecked Sendable {
    public struct Document: Codable {
        public var version: Int
        public var records: [Record]
    }

    public static var currentVersion: Int { 1 }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try Self.decode(data)
    }

    public func save(_ records: [Record]) throws {
        let data = try Self.encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public static func encode(_ records: [Record]) throws -> Data {
        let encoder = JSONEncoder()
        // 用默认的参考日秒数（Double）：能精确往返。ISO 8601 会丢掉秒以下精度，读回的记录就不再相等。
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(version: currentVersion, records: records))
    }

    public static func decode(_ data: Data) throws -> [Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let document = try decoder.decode(Document.self, from: data)
        guard document.version <= currentVersion else {
            throw StoreError.unsupportedVersion(document.version)
        }
        return document.records
    }

    public enum StoreError: Error, Equatable {
        case unsupportedVersion(Int)
    }
}

public extension FileManager {
    /// `~/Library/Application Support/Safarier/`；设置了 `SAFARIER_HOME` 时改用该目录（测试、冒烟用）。
    static func safarierSupportDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SAFARIER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        return try prepareInternalTestWorkspace(in: base)
        #else
        return base.appendingPathComponent("Safarier", isDirectory: true)
        #endif
    }

    static func prepareInternalTestWorkspace(in base: URL) throws -> URL {
        func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let parent = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        func directory(_ name: String, parent: Int32) throws -> Int32 {
            if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw failure() }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure() }
            var info = stat()
            guard fstat(fd, &info) == 0 else { let error = failure(); close(fd); throw error }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
                  (info.st_mode & 0o7777) == 0o700 else {
                close(fd)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
            return fd
        }
        var old = stat()
        if fstatat(parent, "Safarier Test", &old, AT_SYMLINK_NOFOLLOW) == 0 {
            throw WorkspaceMigrationError.legacyPresent
        }
        guard errno == ENOENT else { throw failure() }
        let root = try directory("Safarier AI", parent: parent)
        defer { close(root) }
        let locks = try directory("locks", parent: root)
        close(locks)
        return base.appendingPathComponent("Safarier AI", isDirectory: true)
    }

    static func migrateInternalTestWorkspace(in base: URL, confirmed: Bool) throws {
        guard confirmed else { throw WorkspaceMigrationError.confirmationRequired }
        let parent = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw WorkspaceMigrationError.system(errno) }
        defer { close(parent) }
        var target = stat()
        guard fstatat(parent, "Safarier AI", &target, AT_SYMLINK_NOFOLLOW) != 0 else { throw WorkspaceMigrationError.targetExists }
        guard errno == ENOENT else { throw WorkspaceMigrationError.system(errno) }
        let root = openat(parent, "Safarier Test", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw WorkspaceMigrationError.system(errno) }
        defer { close(root) }
        func validate(_ fd: Int32) throws -> stat {
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw WorkspaceMigrationError.system(errno) }
            guard (value.st_mode & S_IFMT) == S_IFDIR, value.st_uid == geteuid(), (value.st_mode & 0o7777) == 0o700 else { throw WorkspaceMigrationError.unsafeDirectory }
            return value
        }
        let original = try validate(root)
        let locks = openat(root, "locks", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard locks >= 0 else { throw WorkspaceMigrationError.system(errno) }
        defer { close(locks) }
        let originalLocks = try validate(locks)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Safarier Test/locks").path)
        var held: [Int32] = []
        defer { for fd in held { flock(fd, LOCK_UN); close(fd) } }
        for name in names {
            let fd = openat(locks, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw WorkspaceMigrationError.system(errno) }
            var info = stat(), named = stat()
            guard fstat(fd, &info) == 0, fstatat(locks, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  info.st_dev == named.st_dev, info.st_ino == named.st_ino else { close(fd); throw WorkspaceMigrationError.unsafeDirectory }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw WorkspaceMigrationError.lockHeld }
            held.append(fd)
        }
        var namedRoot = stat(), namedLocks = stat()
        guard fstatat(parent, "Safarier Test", &namedRoot, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(root, "locks", &namedLocks, AT_SYMLINK_NOFOLLOW) == 0,
              namedRoot.st_dev == original.st_dev, namedRoot.st_ino == original.st_ino,
              namedLocks.st_dev == originalLocks.st_dev, namedLocks.st_ino == originalLocks.st_ino else { throw WorkspaceMigrationError.unsafeDirectory }
        guard renameatx_np(parent, "Safarier Test", parent, "Safarier AI", UInt32(RENAME_EXCL)) == 0 else { throw WorkspaceMigrationError.system(errno) }
    }

    static func migrateDefaultInternalTestWorkspace(confirmed: Bool) throws {
        if let override = ProcessInfo.processInfo.environment["SAFARIER_HOME"], !override.isEmpty {
            throw WorkspaceMigrationError.overrideSet
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        try migrateInternalTestWorkspace(in: base, confirmed: confirmed)
    }
}

public enum WorkspaceMigrationError: Error, CustomStringConvertible {
    case legacyPresent, confirmationRequired, targetExists, unsafeDirectory, lockHeld, overrideSet, system(Int32)
    public var description: String {
        switch self {
        case .legacyPresent: return "发现旧工作区 Safarier Test；请先退出所有旧版 Manager、Runner、CLI，并确保以后不再打开旧版，再按文档运行 workspace migrate。若新旧目录共存，请先人工处理；不会自动合并。"
        case .confirmationRequired: return "需要明确确认旧版进程均已退出且以后不再打开旧版。"
        case .targetExists: return "Safarier AI 目标已存在；不会覆盖或合并。"
        case .unsafeDirectory: return "旧工作区或锁目录不安全或已变化；未迁移。"
        case .lockHeld: return "旧工作区存在被持有的锁；未迁移。"
        case .overrideSet: return "设置了 SAFARIER_HOME；请取消覆盖后再执行默认工作区迁移。"
        case .system(let code): return "工作区迁移失败（系统错误 \(code)：\(String(cString: strerror(code)))）。"
        }
    }
}
