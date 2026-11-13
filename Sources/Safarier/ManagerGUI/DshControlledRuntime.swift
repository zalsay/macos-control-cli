import Foundation
import CryptoKit
import Darwin
import Security

/// The reviewed values must be supplied by a source change covered by the
/// existing application identity. Artifact metadata is never a trust anchor.
struct DshControlledRuntime {
    struct Anchor: Sendable {
        let imageSHA256: String
        let manifestSHA256: String
        let nodeSHA256: String
        let nodeTeamID: String
    }

    enum Failure: Error {
        case unapproved
        case verificationUnavailable
        case invalidManifest
        case invalidTree
        case invalidArtifact
        case invalidMount
        case invalidNode
        case cleanupFailed
        case mountStateUncertain(String)
        case leaseClosing
        case leaseCleanupUnconfirmed
    }

    struct Manifest: Decodable {
        struct Entry: Decodable {
            let path: String
            let type: String
            let mode: Int
            let size: UInt64?
            let sha256: String?
            let target: String?
        }
        let format: Int
        let entries: [Entry]
    }

    /// The caller must confirm that the child and all relevant descendants no
    /// longer use the mount before close; a child exit callback alone is not proof.
    protocol Lease: Sendable {
        var nodeURL: URL { get }
        var entryURL: URL { get }
        func close() async throws
    }

    struct Mount: Sendable {
        let root: URL
        let device: String
        let session: URL
    }

    protocol Backend: Sendable {
        func attach(image: URL, mount: URL) throws -> Mount
        func validateNode(_ node: URL, teamID: String) throws
        func detach(_ mount: Mount) throws
    }

    actor MountedLease: Lease {
        nonisolated let nodeURL: URL
        nonisolated let entryURL: URL
        private let mount: Mount
        private let backend: any Backend
        private enum State { case open, closing, closed, failed }
        private var state: State = .open
        init(mount: Mount, backend: any Backend) {
            self.mount = mount; self.backend = backend
            nodeURL = mount.root.appendingPathComponent("node/node")
            entryURL = mount.root.appendingPathComponent("dsh/node_modules/@deepseek-ai/dsh/lib/bin.js")
        }
        func close() async throws {
            switch state {
            case .closed: return
            case .closing: throw Failure.leaseClosing
            case .failed: throw Failure.leaseCleanupUnconfirmed
            case .open: state = .closing
            }
            let backend = self.backend, mount = self.mount
            do {
                try await Task.detached { try backend.detach(mount) }.value
                state = .closed
            } catch {
                state = .failed
                throw error
            }
        }
    }

    static let reviewedAnchor: Anchor? = Anchor(
        imageSHA256: "8a4c22bb334a3c307f8494cda029b80cd6a49545789e5e6087b878eef464baeb",
        manifestSHA256: "34e57a58a7674ebe656b249ab9f3bd2ca0cef45bdb9eacbec88592a8a0ec57de",
        nodeSHA256: "27db838bb204ef7c21df2931f5656e4c8fb32e6e947f363a402b49714d32b5b1",
        nodeTeamID: "HX7739G8FX"
    )

    private let anchor: Anchor?
    private let versionsRoot: URL
    private let backend: any Backend

    init() {
        anchor = Self.reviewedAnchor
        versionsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Safarier/DSHRuntime")
        backend = SystemBackend()
    }

    init(anchor: Anchor, versionsRoot: URL, backend: any Backend) {
        self.anchor = anchor; self.versionsRoot = versionsRoot; self.backend = backend
    }

    func acquire() async throws -> any Lease {
        try Task.checkCancellation()
        guard let anchor else { throw Failure.unapproved }
        let root = versionsRoot, backend = self.backend
        let task = Task.detached { () throws -> any Lease in
            try Self.acquireSync(anchor: anchor, root: root, backend: backend)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func acquireSync(anchor: Anchor, root: URL, backend: any Backend) throws -> any Lease {
        func validHash(_ hash: String) -> Bool {
            hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && hash.contains { $0 != "0" }
        }
        guard validHash(anchor.imageSHA256), validHash(anchor.manifestSHA256), validHash(anchor.nodeSHA256),
              !anchor.nodeTeamID.isEmpty, root.isFileURL else { throw Failure.invalidArtifact }
        let rootPath = root.standardizedFileURL.path
        guard rootPath.hasPrefix("/"), rootPath == root.path else { throw Failure.invalidArtifact }
        var ancestor = ""
        for component in rootPath.split(separator: "/") {
            ancestor += "/" + component
            var st = stat()
            guard lstat(ancestor, &st) == 0 else { throw Failure.invalidArtifact }
            if ancestor == "/var" || ancestor == "/tmp" {
                guard (st.st_mode & S_IFMT) == S_IFLNK, st.st_uid == 0,
                      try FileManager.default.destinationOfSymbolicLink(atPath: ancestor) == "private" + ancestor else { throw Failure.invalidArtifact }
            } else {
                guard (st.st_mode & S_IFMT) == S_IFDIR, (st.st_uid == 0 || st.st_uid == geteuid()),
                      st.st_mode & 0o022 == 0 || (st.st_uid == 0 && st.st_mode & S_ISVTX != 0) else { throw Failure.invalidArtifact }
            }
        }
        let version = root.appendingPathComponent(anchor.imageSHA256, isDirectory: true)
        for directory in [root, version] {
            var st = stat()
            guard lstat(directory.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                  st.st_uid == geteuid(), st.st_mode & 0o7777 == 0o700 else { throw Failure.invalidArtifact }
        }
        let image = version.appendingPathComponent("runtime.dmg"), manifestURL = version.appendingPathComponent("manifest.json")
        let manifestData = try checkedData(manifestURL, maximum: 64 * 1024 * 1024)
        guard digest(manifestData) == anchor.manifestSHA256 else { throw Failure.invalidArtifact }
        let manifest = try parseManifest(manifestData)
        guard try hashFile(image) == anchor.imageSHA256 else { throw Failure.invalidArtifact }
        try Task.checkCancellation()
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-dsh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let mountPoint = session.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var mounted: Mount?
        do {
            let mount = try backend.attach(image: image, mount: mountPoint); mounted = mount
            try Task.checkCancellation()
            try verifyTree(mount.root, manifest: manifest)
            let node = mount.root.appendingPathComponent("node/node")
            guard manifest.entries.contains(where: { $0.path == "node/node" && $0.type == "file" && $0.sha256 == anchor.nodeSHA256 }),
                  manifest.entries.contains(where: { $0.path == "dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" && $0.type == "file" }),
                  try hashFile(node, owned: false) == anchor.nodeSHA256 else { throw Failure.invalidNode }
            try backend.validateNode(node, teamID: anchor.nodeTeamID)
            try Task.checkCancellation()
            return MountedLease(mount: mount, backend: backend)
        } catch {
            if let mounted {
                do { try backend.detach(mounted) }
                catch { throw Failure.mountStateUncertain(mounted.session.path) }
            }
            // An attach error can be ambiguous; preserve the session for diagnosis.
            throw error
        }
    }

    struct SystemBackend: Backend {
        private func run(_ arguments: [String]) throws -> Data {
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-hdiutil-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.invalidMount }
            defer { try? FileManager.default.removeItem(at: outputURL) }
            let outputFile = try FileHandle(forWritingTo: outputURL)
            defer { try? outputFile.close() }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = outputFile; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while process.isRunning {
                if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                    process.terminate()
                    let stopDeadline = ProcessInfo.processInfo.systemUptime + 5
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
                    if !process.isRunning { process.waitUntilExit() }
                    throw Failure.invalidMount
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.invalidMount }
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 8 * 1024 * 1024 else { throw Failure.invalidMount }
            return try Data(contentsOf: outputURL)
        }

        private func terminateProcesses(on mountPoint: String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/fuser")
            proc.arguments = [mountPoint]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { return }
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return }
            let pids = text.split(whereSeparator: { $0.isWhitespace }).compactMap { pid_t($0) }
            for pid in pids where pid > 0 && pid != getpid() {
                Darwin.kill(pid, SIGKILL)
            }
            if !pids.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        private func detachStaleMounts(for image: URL) {
            guard let infoData = try? run(["info", "-plist"]),
                  let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
                  let images = info["images"] as? [[String: Any]] else { return }
            let resolvedImage = image.resolvingSymlinksInPath()
            for item in images {
                guard let path = item["image-path"] as? String,
                      URL(fileURLWithPath: path).resolvingSymlinksInPath() == resolvedImage,
                      let entities = item["system-entities"] as? [[String: Any]] else { continue }
                let roots = entities.compactMap { $0["dev-entry"] as? String }.filter { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
                let allDevs = entities.compactMap { $0["dev-entry"] as? String }
                let mountPoints = entities.compactMap { $0["mount-point"] as? String }
                for dev in (roots + allDevs) {
                    if (try? run(["detach", dev])) == nil {
                        _ = try? run(["detach", dev, "-force"])
                    }
                }
                for point in mountPoints {
                    terminateProcesses(on: point)
                    if (try? run(["detach", point])) == nil {
                        _ = try? run(["detach", point, "-force"])
                    }
                    let pointURL = URL(fileURLWithPath: point)
                    let sessionDir = pointURL.deletingLastPathComponent()
                    if sessionDir.lastPathComponent.hasPrefix("safarier-dsh-") {
                        try? FileManager.default.removeItem(at: sessionDir)
                    }
                }
            }
        }

        func attach(image: URL, mount: URL) throws -> Mount {
            detachStaleMounts(for: image)
            let output: Data
            do { output = try run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist", image.path]) }
            catch { throw Failure.mountStateUncertain(mount.deletingLastPathComponent().path) }
            guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]] else { throw Failure.mountStateUncertain(mount.deletingLastPathComponent().path) }
            let roots = entities.compactMap { $0["dev-entry"] as? String }.filter { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
            let points = entities.compactMap { $0["mount-point"] as? String }
            guard roots.count == 1, points.count == 1,
                  URL(fileURLWithPath: points[0]).resolvingSymlinksInPath() == mount.resolvingSymlinksInPath() else { throw Failure.mountStateUncertain(mount.deletingLastPathComponent().path) }
            let result = Mount(root: mount, device: roots[0], session: mount.deletingLastPathComponent())
            do {
                var fs = statfs()
                guard statfs(mount.path, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 else { throw Failure.invalidMount }
                let infoData = try run(["info", "-plist"])
                guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
                      let images = info["images"] as? [[String: Any]],
                      images.contains(where: { item in
                          guard let path = item["image-path"] as? String,
                                URL(fileURLWithPath: path).resolvingSymlinksInPath() == image.resolvingSymlinksInPath(),
                                let entries = item["system-entities"] as? [[String: Any]] else { return false }
                          return entries.contains { ($0["dev-entry"] as? String) == result.device }
                      }) else { throw Failure.invalidMount }
                return result
            } catch {
                do { try detach(result) }
                catch { throw Failure.mountStateUncertain(result.session.path) }
                throw error
            }
        }

        func validateNode(_ node: URL, teamID: String) throws {
            guard teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { throw Failure.invalidNode }
            var code: SecStaticCode?, requirement: SecRequirement?
            let text = "anchor apple generic and identifier \"node\" and certificate leaf[subject.OU] = \"\(teamID)\""
            guard SecStaticCodeCreateWithPath(node as CFURL, [], &code) == errSecSuccess,
                  SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let code, let requirement,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else { throw Failure.invalidNode }
        }

        func detach(_ mount: Mount) throws {
            do {
                _ = try run(["detach", mount.device])
            } catch {
                do {
                    _ = try run(["detach", mount.root.path])
                } catch {
                    if (try? run(["detach", mount.device, "-force"])) == nil &&
                       (try? run(["detach", mount.root.path, "-force"])) == nil {
                        throw Failure.cleanupFailed
                    }
                }
            }
            do { try FileManager.default.removeItem(at: mount.session) }
            catch { throw Failure.cleanupFailed }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkedData(_ url: URL, maximum: Int) throws -> Data {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0, st.st_size <= maximum else { throw Failure.invalidArtifact }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximum, try hashFile(url) == digest(data) else { throw Failure.invalidArtifact }
        return data
    }

    private static func hashFile(_ url: URL, owned: Bool = true) throws -> String {
        var before = stat(), opened = stat(), after = stat(), pathAfter = stat()
        guard lstat(url.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
              !owned || (before.st_uid == geteuid() && before.st_mode & 0o7022 == 0) else { throw Failure.invalidArtifact }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidArtifact }; defer { close(fd) }
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        guard fstat(fd, &opened) == 0, same(before, opened) else { throw Failure.invalidArtifact }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count); guard count >= 0 else { throw Failure.invalidArtifact }
            if count == 0 { break }; hash.update(data: Data(buffer.prefix(count)))
        }
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0, same(before, after), same(before, pathAfter) else { throw Failure.invalidArtifact }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func parseManifest(_ data: Data) throws -> Manifest {
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw Failure.invalidManifest }
        guard manifest.format == 1, !manifest.entries.isEmpty else { throw Failure.invalidManifest }
        var seen = Set<String>()
        for entry in manifest.entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\0"),
                  entry.path == "." || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  seen.insert(entry.path).inserted,
                  ["directory", "file", "symlink"].contains(entry.type),
                  entry.mode >= 0, entry.mode <= 0o7777 else { throw Failure.invalidManifest }
            switch entry.type {
            case "file":
                guard entry.size != nil, let hash = entry.sha256,
                      hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      entry.target == nil, entry.mode & 0o7022 == 0 else { throw Failure.invalidManifest }
            case "directory":
                guard entry.size == nil, entry.sha256 == nil, entry.target == nil,
                      entry.mode & 0o7022 == 0 else { throw Failure.invalidManifest }
            case "symlink":
                guard entry.size == nil, entry.sha256 == nil, let target = entry.target,
                      !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { throw Failure.invalidManifest }
            default: throw Failure.invalidManifest
            }
        }
        guard manifest.entries.contains(where: { $0.path == "." && $0.type == "directory" }) else { throw Failure.invalidManifest }
        return manifest
    }

    static func verifyTree(_ root: URL, manifest: Manifest) throws {
        let expected = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
        let fm = FileManager.default
        var found = Set<String>()
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
            a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        func validateLink(_ relative: String, target: String) throws {
            var parts = Array(relative.split(separator: "/").dropLast()).map(String.init)
            var pending = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var links = 0
            while !pending.isEmpty {
                try Task.checkCancellation()
                let part = pending.removeFirst()
                if part.isEmpty || part == "." { continue }
                if part == ".." {
                    guard !parts.isEmpty else { throw Failure.invalidTree }
                    parts.removeLast(); continue
                }
                let candidate = parts.reduce(root) { $0.appendingPathComponent($1) }.appendingPathComponent(part)
                var before = stat(), after = stat()
                guard lstat(candidate.path, &before) == 0 else { throw Failure.invalidTree }
                if (before.st_mode & S_IFMT) == S_IFLNK {
                    links += 1
                    guard links <= 40 else { throw Failure.invalidTree }
                    let dest = try fm.destinationOfSymbolicLink(atPath: candidate.path)
                    guard !dest.isEmpty, !dest.hasPrefix("/"), lstat(candidate.path, &after) == 0,
                          same(before, after) else { throw Failure.invalidTree }
                    pending = dest.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending
                } else {
                    if !pending.isEmpty && (before.st_mode & S_IFMT) != S_IFDIR { throw Failure.invalidTree }
                    parts.append(part)
                }
            }
        }
        func check(_ url: URL, _ relative: String) throws {
            try Task.checkCancellation()
            guard let entry = expected[relative], found.insert(relative).inserted else { throw Failure.invalidTree }
            var st = stat()
            guard lstat(url.path, &st) == 0, Int(st.st_mode & 0o7777) == entry.mode else { throw Failure.invalidTree }
            switch entry.type {
            case "directory":
                guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.invalidTree }
                for name in try fm.contentsOfDirectory(atPath: url.path) {
                    let child = relative == "." ? name : relative + "/" + name
                    try check(url.appendingPathComponent(name), child)
                }
                var after = stat()
                guard lstat(url.path, &after) == 0, same(st, after) else { throw Failure.invalidTree }
            case "file":
                guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
                      st.st_size >= 0, UInt64(st.st_size) == entry.size else { throw Failure.invalidTree }
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Failure.invalidTree }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else { throw Failure.invalidTree }
                var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                while true {
                    try Task.checkCancellation()
                    let count = read(fd, &buffer, buffer.count)
                    guard count >= 0 else { throw Failure.invalidTree }
                    if count == 0 { break }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                var afterFD = stat(), afterPath = stat()
                guard digest == entry.sha256, fstat(fd, &afterFD) == 0, lstat(url.path, &afterPath) == 0,
                      same(st, opened), same(st, afterFD), same(st, afterPath) else { throw Failure.invalidTree }
            case "symlink":
                guard (st.st_mode & S_IFMT) == S_IFLNK,
                      try fm.destinationOfSymbolicLink(atPath: url.path) == entry.target else { throw Failure.invalidTree }
                try validateLink(relative, target: entry.target!)
                var after = stat()
                guard lstat(url.path, &after) == 0, same(st, after),
                      try fm.destinationOfSymbolicLink(atPath: url.path) == entry.target else { throw Failure.invalidTree }
            default: throw Failure.invalidTree
            }
        }
        try check(root, ".")
        guard found.count == expected.count else { throw Failure.invalidTree }
    }
}
