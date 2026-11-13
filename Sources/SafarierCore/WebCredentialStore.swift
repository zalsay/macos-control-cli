import Foundation
import Darwin

/// 网站登录凭据：域名、用户名、密码。
public struct WebCredential: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 归属域名（小写，如 "github.com" 或 "example.com:8080"）
    public var domain: String
    /// 用户名 / 账号 / 邮箱
    public var username: String
    /// 密码原文
    public var password: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        domain: String,
        username: String,
        password: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        self.id = id
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        try validate()
    }

    public func validate() throws {
        guard !domain.isEmpty, domain.count <= 256 else { throw WebCredentialStore.Error.invalidCredential }
        guard !username.isEmpty, username.count <= 256 else { throw WebCredentialStore.Error.invalidCredential }
        guard !password.isEmpty, password.count <= 4096 else { throw WebCredentialStore.Error.invalidCredential }
    }
}

/// 环境隔离的网站密码与表单存储：
/// - Persistent 环境：存储在 workspace/credentials/<profileID>.json 中，配锁与 0o700/0o600 严格权限。
/// - Ephemeral 环境：仅保存在内存中，窗口或会话关闭即随之销毁，绝不落盘。
public final class WebCredentialStore: @unchecked Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        public let revision: UUID
        public let items: [WebCredential]
        public let neverSaveDomains: [String]

        public init(revision: UUID = UUID(), items: [WebCredential] = [], neverSaveDomains: [String] = []) {
            self.revision = revision
            self.items = items
            self.neverSaveDomains = neverSaveDomains
        }
    }

    private struct Document: Codable {
        let version: Int
        let snapshot: Snapshot
    }

    public enum Error: Swift.Error, LocalizedError {
        case invalidCredential
        case profileMissing
        case conflict
        case unsafeStorage
        case unsupportedVersion
        case io

        public var errorDescription: String? {
            switch self {
            case .invalidCredential: return "用户名、密码或域名格式无效。"
            case .profileMissing: return "指定的环境不存在。"
            case .conflict: return "凭据已在其他进程更改，请刷新后重试。"
            case .unsafeStorage: return "凭据存储目录或权限不安全。"
            case .unsupportedVersion: return "不支持的凭据数据版本。"
            case .io: return "读写凭据存储文件失败。"
            }
        }
    }

    private static let emptyRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private let workspace: SafarierWorkspace?
    private let profileID: UUID
    private let isEphemeral: Bool

    // 内存存储（用于 Ephemeral 模式或测试）
    private var memorySnapshot = Snapshot(revision: emptyRevision, items: [], neverSaveDomains: [])
    private let memoryLock = NSLock()

    private var directory: URL? {
        workspace?.root.appendingPathComponent("credentials", isDirectory: true)
    }

    private var dataURL: URL? {
        directory?.appendingPathComponent(profileID.uuidString + ".json")
    }

    private var lockURL: URL? {
        directory?.appendingPathComponent(profileID.uuidString + ".lock")
    }

    public init(workspace: SafarierWorkspace?, profileID: UUID, isEphemeral: Bool = false) {
        self.workspace = workspace
        self.profileID = profileID
        self.isEphemeral = isEphemeral
    }

    // MARK: - 文件锁保护

    private func locked<T>(_ body: () throws -> T) throws -> T {
        if isEphemeral || workspace == nil {
            memoryLock.lock()
            defer { memoryLock.unlock() }
            return try body()
        }

        guard let directory, let lockURL else { throw Error.unsafeStorage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var d = stat()
        guard lstat(directory.path, &d) == 0, (d.st_mode & S_IFMT) == S_IFDIR, d.st_uid == geteuid(), (d.st_mode & 0o077) == 0 else {
            throw Error.unsafeStorage
        }

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

    private func syncDirectory() throws {
        guard let directory else { return }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.io }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Error.io }
    }

    // MARK: - 读写数据

    private func readUnlocked() throws -> Snapshot {
        if isEphemeral || workspace == nil {
            return memorySnapshot
        }

        guard let dataURL else { return Snapshot(revision: Self.emptyRevision, items: [], neverSaveDomains: []) }
        let fd = open(dataURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT {
                return Snapshot(revision: Self.emptyRevision, items: [], neverSaveDomains: [])
            }
            throw Error.io
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1, (st.st_mode & 0o077) == 0 else {
            throw Error.unsafeStorage
        }
        let data = try file.readToEnd() ?? Data()
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw Error.unsupportedVersion }
        for item in document.snapshot.items { try item.validate() }
        return document.snapshot
    }

    public func load() throws -> Snapshot {
        try locked { try readUnlocked() }
    }

    public func all() -> [WebCredential] {
        (try? load().items) ?? []
    }

    public func credentials(for domain: String) -> [WebCredential] {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = self.all()
        return all.filter { cred in
            cred.domain == clean || clean.hasSuffix("." + cred.domain) || cred.domain.hasSuffix("." + clean)
        }
    }

    public func isNeverSave(for domain: String) -> Bool {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let snapshot = try? load() else { return false }
        return snapshot.neverSaveDomains.contains(clean)
    }

    public func setNeverSave(for domain: String) throws {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        try locked {
            let current = try readUnlocked()
            var domains = current.neverSaveDomains
            if !domains.contains(clean) {
                domains.append(clean)
            }
            _ = try writeUnlocked(items: current.items, neverSaveDomains: domains, expectedRevision: current.revision)
        }
    }

    public func save(credential: WebCredential) throws -> WebCredential {
        try credential.validate()
        return try locked {
            let current = try readUnlocked()
            var items = current.items

            if let idx = items.firstIndex(where: { $0.id == credential.id || ($0.domain == credential.domain && $0.username == credential.username) }) {
                items[idx] = credential
            } else {
                items.append(credential)
            }

            _ = try writeUnlocked(items: items, neverSaveDomains: current.neverSaveDomains, expectedRevision: current.revision)
            return credential
        }
    }

    @discardableResult
    public func save(domain: String, username: String, password: String) throws -> WebCredential {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        return try locked {
            let current = try readUnlocked()
            var items = current.items

            let now = Date()
            let cred: WebCredential
            if let idx = items.firstIndex(where: { $0.domain == cleanDomain && $0.username == cleanUser }) {
                var existing = items[idx]
                existing.password = password
                existing.updatedAt = now
                try existing.validate()
                items[idx] = existing
                cred = existing
            } else {
                let new = try WebCredential(
                    domain: cleanDomain,
                    username: cleanUser,
                    password: password,
                    createdAt: now,
                    updatedAt: now
                )
                items.append(new)
                cred = new
            }

            _ = try writeUnlocked(items: items, neverSaveDomains: current.neverSaveDomains, expectedRevision: current.revision)
            return cred
        }
    }

    public func remove(id: UUID) throws {
        try locked {
            let current = try readUnlocked()
            var items = current.items
            items.removeAll(where: { $0.id == id })
            _ = try writeUnlocked(items: items, neverSaveDomains: current.neverSaveDomains, expectedRevision: current.revision)
        }
    }

    public func delete(id: UUID) throws {
        try remove(id: id)
    }

    public func clear() throws {
        try locked {
            let current = try readUnlocked()
            _ = try writeUnlocked(items: [], neverSaveDomains: current.neverSaveDomains, expectedRevision: current.revision)
        }
    }

    private func writeUnlocked(items: [WebCredential], neverSaveDomains: [String], expectedRevision: UUID) throws -> Snapshot {
        for item in items { try item.validate() }
        let newRevision = UUID()
        let snapshot = Snapshot(revision: newRevision, items: items, neverSaveDomains: neverSaveDomains)

        if isEphemeral || workspace == nil {
            memorySnapshot = snapshot
            return snapshot
        }

        guard let directory, let dataURL else { throw Error.unsafeStorage }
        let current = try readUnlocked()
        guard current.revision == expectedRevision else { throw Error.conflict }

        let data = try JSONEncoder().encode(Document(version: 1, snapshot: snapshot))
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
        return snapshot
    }
}
