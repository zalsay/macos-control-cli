import Foundation
import Darwin
import SafarierCore

public enum SingboxProcessError: Error, Equatable {
    case alreadyRunning(UUID)
    case notRunning(UUID)
    case executableNotFound(URL)
    /// 自带的代理内核带着下载来的隔离标记，而且去不掉（见 `clearQuarantine`）。
    case quarantined(URL)
    case noFreePort
    case invalidOwnedTimeout
    case ownedConfigurationTooLarge
    case ownedPipeFailure(Int32)
    /// 代理内核在本地端口就绪前就退出了（多半是配置或节点参数有问题，原因在它的日志里）。
    case exitedEarly(status: Int32)
    case startTimeout(port: Int)
}

extension SingboxProcessError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyRunning: return "这个环境的代理内核已经在运行。"
        case .notRunning: return "这个环境的代理内核没有在运行。"
        case .executableNotFound(let url):
            // 按文件名判断是哪个内核，只为了给出正确的安装命令和环境变量名；找不到时用通用说法。
            let engine = ProxyCoreEngine.matching(executableURL: url) ?? .singbox
            return "找不到 \(engine.displayName)（\(url.path)），订阅节点要靠它连出去。Safarier.app 里自带一份；"
                + "单独用命令行版时请 brew install \(engine.displayName)，或用环境变量 \(engine.environmentVariable) 指定路径。"
        case .quarantined(let url):
            return "macOS 拦下了自带的代理内核：\(url.path) 带着下载来的隔离标记，而且所在位置是只读的"
                + "（多半是 App 还在「下载」里，被系统放到了临时位置运行）。把 Safarier.app 拖进「应用程序」，"
                + "或在终端运行 xattr -dr com.apple.quarantine /Applications/Safarier.app，再重新打开。"
        case .invalidOwnedTimeout: return "无效的 owned 超时。"
        case .ownedConfigurationTooLarge: return "配置超过 1 MiB。"
        case .ownedPipeFailure(let code): return "配置管道写入失败 (\(code))。"
        case .noFreePort: return "127.0.0.1 上没有空闲端口给代理内核。"
        case .exitedEarly(let status): return "代理内核启动后马上退出了（退出码 \(status)），多半是节点参数有问题，详情见日志。"
        case .startTimeout(let port): return "代理内核没有在规定时间内监听 127.0.0.1:\(port)。"
        }
    }
}

/// 每个 profile 一个代理内核子进程（sing-box 或 mihomo，由 `engine` 决定）：节点出站 → `127.0.0.1:<port>` 的 SOCKS5 入站，交给 WebKit。
///
/// 状态目录里每个 profile 两个文件：`<id>.json`（配置，含节点凭据，权限 0600）和 `<id>.pid`。
/// 正常停止时两个都删掉；Runner 被 SIGKILL 或崩溃时会留下来，下次启动同一 profile、
/// 或图形管理器发现该 profile 没在运行时，用 `reapOrphan` 按 pid 文件清理。
public final class SingboxProcessManager: @unchecked Sendable {
    public let engine: ProxyCoreEngine
    public let executableURL: URL
    public let stateDirectory: URL
    public let portRange: ClosedRange<Int>
    public let logLevel: String
    /// sing-box 的 stdout/stderr 写到这里；nil 时丢弃。
    public let logHandle: FileHandle?

    private var processes: [UUID: Process] = [:]
    private var ports: [UUID: Int] = [:]
    private let lock = NSLock()
    private var legacyStarting: Set<UUID> = []
    private final class OwnedSlot {
        var process: OwnedRunnerProcess?
        var identity: OwnedIdentity?
        var stopRequested = false
        var closeDeadline: UInt64?
        var closeTask: Task<ProcessExit?, Never>?
        var closeFinished = false
        var closeResult: ProcessExit?
    }
    private var owned: [UUID: OwnedSlot] = [:]
    private var ownedReceipts: [(OwnedIdentity, ProcessExit)] = []
    // Test-only synchronization seam; public initialization never supplies a hook.
    internal var ownedBeforeSpawn: (@Sendable () -> Void)?
    internal var ownedAfterSpawn: (@Sendable () -> Void)?
    internal var ownedBeforeCloseObserve: (@Sendable () -> Void)?
    internal var ownedBeforeCloseTaskObserve: (@Sendable () -> Void)?
    internal var ownedDidCloseTaskObserve: (@Sendable (ProcessExit?) -> Void)?

    public struct OwnedIdentity: Equatable, Sendable, CustomStringConvertible {
        public let profileID: UUID
        public let ownershipID: UUID
        public let pid: Int32
        public let proxy: ProxySettings
        public init(profileID: UUID, ownershipID: UUID, pid: Int32, proxy: ProxySettings) {
            self.profileID = profileID; self.ownershipID = ownershipID; self.pid = pid; self.proxy = proxy
        }
        public var description: String { "OwnedIdentity(redacted)" }
    }


    public init(
        engine: ProxyCoreEngine = .singbox,
        executableURL: URL? = nil,
        stateDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Safarier/sing-box", isDirectory: true),
        portRange: ClosedRange<Int> = 20_001...39_999,
        logLevel: String = "warn",
        logHandle: FileHandle? = nil
    ) {
        self.engine = engine
        self.executableURL = executableURL ?? engine.defaultExecutableURL
        self.stateDirectory = stateDirectory
        self.portRange = portRange
        self.logLevel = logLevel
        self.logHandle = logHandle
    }

    /// sing-box 的默认位置（见 `ProxyCoreEngine.defaultExecutableURL`）。
    public static var defaultExecutableURL: URL { ProxyCoreEngine.singbox.defaultExecutableURL }

    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutable: URL? = nil
    ) -> URL? {
        ProxyCoreEngine.singbox.locateExecutable(environment: environment, bundledExecutable: bundledExecutable)
    }

    /// `Contents/Helpers/sing-box`（scripts/build-app.sh 放进去的）；不是从 .app 里运行时为 nil。
    public static func bundledExecutableURL(mainExecutable: URL = RunnerLauncher.currentExecutableURL()) -> URL? {
        ProxyCoreEngine.singbox.bundledExecutableURL(mainExecutable: mainExecutable)
    }

    // MARK: - 隔离标记

    static let quarantineAttribute = "com.apple.quarantine"

    /// 从浏览器下载的压缩包解出来的文件都带隔离标记。用户在「仍要打开」里放行的是 Safarier.app，
    /// 里面的 sing-box 不跟着放行，直接拉起会卡在 Gatekeeper 的确认框上，最后被拒绝。
    /// 它在 App 签名的封装里，所以只对自带的这一份去掉标记；别处的 sing-box 不动。
    static func clearQuarantine(of executable: URL, bundled: URL? = bundledExecutableURL()) throws {
        guard let bundled,
              executable.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path,
              isQuarantined(executable) else { return }
        removexattr(executable.path, quarantineAttribute, 0)
        if isQuarantined(executable) { throw SingboxProcessError.quarantined(executable) }
    }

    /// 有隔离标记，而且用户没放行过（标志字段带 0x40 表示已放行）。
    static func isQuarantined(_ url: URL) -> Bool {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = getxattr(url.path, quarantineAttribute, &buffer, buffer.count - 1, 0, 0)
        guard length > 0 else { return false }
        let flags = String(cString: buffer).split(separator: ";").first.flatMap { UInt32($0, radix: 16) } ?? 0
        return flags & 0x40 == 0
    }

    // MARK: - 端口

    /// 按 profile id 选一个固定的起点，跳过已经被占用的端口（实际试绑 127.0.0.1）。
    public func port(for profileID: UUID) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if let port = ports[profileID] { return port }
        let available = portRange.count
        let hex = profileID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let seed = Int(hex, radix: 16) ?? 0
        let used = Set(ports.values)
        for offset in 0..<available {
            let candidate = portRange.lowerBound + ((seed + offset) % available)
            if !used.contains(candidate), Self.isPortAvailable(candidate) {
                ports[profileID] = candidate
                return candidate
            }
        }
        throw SingboxProcessError.noFreePort
    }

    public static func isPortAvailable(_ port: Int, host: String = SingboxConfigBuilder.defaultInboundAddress) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = Self.socketAddress(host: host, port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private static func isAcceptingConnections(_ port: Int, host: String = SingboxConfigBuilder.defaultInboundAddress) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = Self.socketAddress(host: host, port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private static func socketAddress(host: String, port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &address.sin_addr)
        return address
    }

    // MARK: - 文件

    public func configurationFileURL(for profileID: UUID) -> URL {
        Self.configurationFileURL(for: profileID, in: stateDirectory)
    }

    public func pidFileURL(for profileID: UUID) -> URL {
        Self.pidFileURL(for: profileID, in: stateDirectory)
    }

    static func configurationFileURL(for profileID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(profileID.uuidString).json")
    }

    static func pidFileURL(for profileID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(profileID.uuidString).pid")
    }

    public func configuration(for profileID: UUID, node: SubscriptionNode) throws -> SingboxConfiguration {
        try SingboxConfigBuilder.makeConfiguration(inboundPort: port(for: profileID), node: node, logLevel: logLevel)
    }

    /// 当前内核的配置文件内容（sing-box 的 JSON 或 mihomo 的配置）。
    private func configurationData(node: SubscriptionNode, port: Int) throws -> Data {
        switch engine {
        case .singbox:
            return try SingboxConfigBuilder.makeConfiguration(inboundPort: port, node: node, logLevel: logLevel).encoded()
        case .mihomo:
            return try MihomoConfigBuilder.build(inboundPort: port, node: node)
        }
    }

    /// 启动参数。`configurationPath` 是配置文件路径；owned 路径传 `standardInputPath`，配置从管道读。
    private func runArguments(configurationPath: String) -> [String] {
        switch engine {
        case .singbox: return ["run", "-c", configurationPath]
        case .mihomo: return ["-d", stateDirectory.path, "-f", configurationPath]
        }
    }

    /// owned 路径里配置从标准输入读：sing-box 用它自己的 `stdin`，mihomo 要用 `/dev/stdin`。
    private var standardInputPath: String {
        switch engine {
        case .singbox: return "stdin"
        case .mihomo: return "/dev/stdin"
        }
    }

    // MARK: - 生命周期

    /// 写配置、起 sing-box，立即返回 pid；要等本地端口可用请接着调 `waitUntilReady`。
    @discardableResult
    public func start(profileID: UUID, node: SubscriptionNode) throws -> Int32 {
        lock.lock()
        pruneObservedOwnedLocked()
        if owned[profileID] != nil || legacyStarting.contains(profileID) || processes[profileID]?.isRunning == true {
            lock.unlock()
            throw SingboxProcessError.alreadyRunning(profileID)
        }
        legacyStarting.insert(profileID)
        lock.unlock()
        defer { lock.lock(); legacyStarting.remove(profileID); lock.unlock() }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SingboxProcessError.executableNotFound(executableURL)
        }
        try Self.clearQuarantine(of: executableURL, bundled: engine.bundledExecutableURL())
        // 同一个 profile 上次没清理掉的内核（Runner 崩溃、被 SIGKILL）先结束，让出端口。
        Self.reapOrphan(profileID: profileID, in: stateDirectory)

        let data = try configurationData(node: node, port: port(for: profileID))
        let configURL = configurationFileURL(for: profileID)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try Self.writePrivate(data, to: configURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = runArguments(configurationPath: configURL.path)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: configURL)
            throw error
        }
        try? Self.writePrivate(Data("\(process.processIdentifier)\n".utf8), to: pidFileURL(for: profileID))
        lock.lock()
        processes[profileID] = process
        lock.unlock()
        return process.processIdentifier
    }

    /// 等到本地 SOCKS5 端口能连上，返回端口。sing-box 先退出就抛 `exitedEarly`。
    @discardableResult
    public func waitUntilReady(profileID: UUID, timeout: TimeInterval = 10) throws -> Int {
        lock.lock()
        let process = processes[profileID]
        let port = ports[profileID]
        lock.unlock()
        guard let process, let port else { throw SingboxProcessError.notRunning(profileID) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard process.isRunning else {
                process.waitUntilExit()
                throw SingboxProcessError.exitedEarly(status: process.terminationStatus)
            }
            if Self.isAcceptingConnections(port) { return port }
            usleep(50_000)
        }
        throw SingboxProcessError.startTimeout(port: port)
    }

    /// SIGTERM，最多等 2 秒再 SIGKILL；删掉配置和 pid 文件。
    public func stop(profileID: UUID) throws {
        lock.lock()
        if owned[profileID] != nil || legacyStarting.contains(profileID) { lock.unlock(); throw SingboxProcessError.notRunning(profileID) }
        let process = processes.removeValue(forKey: profileID)
        ports.removeValue(forKey: profileID)
        lock.unlock()
        defer { removeStateFiles(for: profileID) }
        guard let process else { throw SingboxProcessError.notRunning(profileID) }
        Self.terminate(pid: process.processIdentifier, isRunning: { process.isRunning })
    }

    public func stopAll() {
        lock.lock()
        let ids = Array(processes.keys)
        lock.unlock()
        for id in ids { try? stop(profileID: id) }
    }

    public func isRunning(profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return processes[profileID]?.isRunning == true
    }

    public func processIdentifier(for profileID: UUID) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let process = processes[profileID], process.isRunning else { return nil }
        return process.processIdentifier
    }


    // Owned children are never recovered by PID: only an observed exit frees a slot.
    private func pruneObservedOwnedLocked() {
        for (id, slot) in owned {
            guard let identity = slot.identity, let exit = slot.process?.observedExit else { continue }
            ownedReceipts.append((identity, exit))
            if ownedReceipts.count > 256 { ownedReceipts.removeFirst() }
            owned.removeValue(forKey: id); ports.removeValue(forKey: id)
        }
    }
    public var pendingOwnedCount: Int {
        lock.lock(); defer { lock.unlock() }
        pruneObservedOwnedLocked()
        return owned.count
    }
    private static func ownedDeadline(_ seconds: Double) throws -> UInt64 {
        guard seconds.isFinite, seconds > 0, seconds < 1_000_000 else { throw SingboxProcessError.invalidOwnedTimeout }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(UInt64(seconds * 1_000_000_000))
        guard !overflow else { throw SingboxProcessError.invalidOwnedTimeout }
        return deadline
    }
    private func reserveOwned(_ id: UUID) throws -> OwnedSlot {
        lock.lock(); defer { lock.unlock() }
        pruneObservedOwnedLocked()
        guard owned[id] == nil, !legacyStarting.contains(id), processes[id]?.isRunning != true else { throw SingboxProcessError.alreadyRunning(id) }
        let slot = OwnedSlot(); owned[id] = slot; return slot
    }
    private func releaseUnspawned(_ id: UUID, _ slot: OwnedSlot) {
        lock.lock(); defer { lock.unlock() }
        if owned[id] === slot, slot.process == nil { owned.removeValue(forKey: id); ports.removeValue(forKey: id) }
    }
    private func beginCloseLocked(_ slot: OwnedSlot) {
        slot.stopRequested = true
        if slot.closeDeadline == nil { slot.closeDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000 }
        guard slot.closeTask == nil, let process = slot.process, let deadline = slot.closeDeadline else { return }
        _ = process.requestTermination()
        let beforeObserve = ownedBeforeCloseTaskObserve, didObserve = ownedDidCloseTaskObserve
        slot.closeTask = Task.detached { [weak self] in
            beforeObserve?()
            let now = DispatchTime.now().uptimeNanoseconds
            let candidate: ProcessExit?
            if now >= deadline { candidate = nil }
            else if let exit = process.observedExit { candidate = exit }
            else { candidate = try? await process.waitForExit(timeoutSeconds: Double(deadline - now) / 1_000_000_000) }
            let result = DispatchTime.now().uptimeNanoseconds < deadline ? candidate : nil
            self?.recordCloseResult(slot, result: result)
            didObserve?(result)
            return result
        }
    }
    private func recordCloseResult(_ slot: OwnedSlot, result: ProcessExit?) {
        lock.lock(); defer { lock.unlock() }
        slot.closeResult = result; slot.closeFinished = true
    }
    private func registerOwned(slot: OwnedSlot, process: OwnedRunnerProcess, identity: OwnedIdentity) {
        lock.lock(); defer { lock.unlock() }
        slot.process = process; slot.identity = identity
        if slot.stopRequested { beginCloseLocked(slot) }
    }
    private func checkOwnedStart(_ slot: OwnedSlot, deadline: UInt64, port: Int = 0) throws {
        try Task.checkCancellation()
        lock.lock(); let stopped = slot.stopRequested; lock.unlock()
        if stopped { throw CancellationError() }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw SingboxProcessError.startTimeout(port: port) }
    }
    private func markOwnedClose(_ slot: OwnedSlot) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        beginCloseLocked(slot)
        return slot.closeDeadline!
    }
    private func markAllOwnedClose() -> [OwnedSlot] {
        lock.lock(); defer { lock.unlock() }
        let slots = Array(owned.values)
        for slot in slots { beginCloseLocked(slot) }
        return slots
    }
    private func closeSnapshot(_ slot: OwnedSlot) -> (OwnedRunnerProcess?, UInt64?, Bool, Bool, ProcessExit?) {
        lock.lock(); defer { lock.unlock() }
        return (slot.process, slot.closeDeadline, owned.values.contains { $0 === slot }, slot.closeFinished, slot.closeResult)
    }
    // Identity validation and the first TERM/deadline are one atomic operation.
    private func requestOwnedClose(_ identity: OwnedIdentity) throws -> (OwnedSlot?, ProcessExit?) {
        lock.lock(); defer { lock.unlock() }
        if let receipt = ownedReceipts.last(where: { $0.0 == identity }) { return (nil, receipt.1) }
        guard let slot = owned[identity.profileID], slot.identity == identity else { throw SingboxProcessError.notRunning(identity.profileID) }
        beginCloseLocked(slot)
        return (slot, nil)
    }
    public func requestStopOwned(_ identity: OwnedIdentity) throws {
        _ = try requestOwnedClose(identity)
    }
    private func pruneObservedOwned() { lock.lock(); defer { lock.unlock() }; pruneObservedOwnedLocked() }
    private func waitForClose(_ slot: OwnedSlot, deadline: UInt64) async -> ProcessExit? {
        ownedBeforeCloseObserve?()
        while true {
            if Task.isCancelled { return nil }
            let (process, closeDeadline, registered, finished, result) = closeSnapshot(slot)
            let effectiveDeadline = min(deadline, closeDeadline ?? deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= effectiveDeadline { return nil }
            if let exit = process?.observedExit ?? result {
                guard DispatchTime.now().uptimeNanoseconds < effectiveDeadline else { return nil }
                pruneObservedOwned()
                return DispatchTime.now().uptimeNanoseconds < effectiveDeadline ? exit : nil
            }
            if !registered || finished { return nil }
            try? await Task.sleep(nanoseconds: min(10_000_000, effectiveDeadline - now))
        }
    }
    private static func writeOwned(_ data: Data, fd: Int32, deadline: UInt64, check: () throws -> Void) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw SingboxProcessError.ownedPipeFailure(errno) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try check()
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw SingboxProcessError.startTimeout(port: 0) }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ms = Int32(min(50, max(1, (deadline - now) / 1_000_000)))
                let result = poll(&p, 1, ms)
                if result < 0 { if errno == EINTR { continue }; throw SingboxProcessError.ownedPipeFailure(errno) }
                try check()
                if result == 0 { continue }
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw SingboxProcessError.ownedPipeFailure(errno) }
                if n == 0 { throw SingboxProcessError.ownedPipeFailure(EIO) }
                offset += n
                try check()
            }
        }
    }
    public func startOwned(profileID: UUID, node: SubscriptionNode, timeoutSeconds: Double = 10) async throws -> OwnedIdentity {
        let deadline = try Self.ownedDeadline(timeoutSeconds)
        let slot = try reserveOwned(profileID)
        var child: OwnedRunnerProcess?
        do {
            try checkOwnedStart(slot, deadline: deadline)
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw SingboxProcessError.executableNotFound(executableURL) }
            let quarantineResult = getxattr(executableURL.path, Self.quarantineAttribute, nil, 0, 0, 0)
            if quarantineResult >= 0 || errno != ENOATTR { throw SingboxProcessError.quarantined(executableURL) }
            try checkOwnedStart(slot, deadline: deadline)
            let port = try port(for: profileID)
            let data = try configurationData(node: node, port: port)
            guard data.count <= 1_048_576 else { throw SingboxProcessError.ownedConfigurationTooLarge }
            try checkOwnedStart(slot, deadline: deadline, port: port)
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw SingboxProcessError.ownedPipeFailure(errno) }
            let readHandle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            defer { try? readHandle.close(); close(fds[1]) }
            guard fcntl(fds[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(fds[1], F_SETFD, FD_CLOEXEC) == 0 else { throw SingboxProcessError.ownedPipeFailure(errno) }
            // mihomo 需要一个可写的 `-d` 目录（缓存等）；配置本身仍然只走管道，不落盘。
            if engine == .mihomo {
                try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            }
            ownedBeforeSpawn?()
            try checkOwnedStart(slot, deadline: deadline, port: port)
            let process = try FoundationProcessSpawner().spawnOwned(executableURL: executableURL, arguments: runArguments(configurationPath: standardInputPath), environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], standardInput: readHandle, standardOutput: .nullDevice, standardError: .nullDevice)
            child = process
            ownedAfterSpawn?()
            let identity = OwnedIdentity(profileID: profileID, ownershipID: process.ownershipID, pid: process.pid, proxy: ProxySettings(name: engine.displayName, kind: .socks5, host: "127.0.0.1", port: port))
            registerOwned(slot: slot, process: process, identity: identity)
            try checkOwnedStart(slot, deadline: deadline, port: port)
            try readHandle.close()
            try Self.writeOwned(data, fd: fds[1], deadline: deadline) { try self.checkOwnedStart(slot, deadline: deadline, port: port) }
            close(fds[1]); fds[1] = -1
            while true {
                try checkOwnedStart(slot, deadline: deadline, port: port)
                if let exit = process.observedExit { throw SingboxProcessError.exitedEarly(status: exit.status) }
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw SingboxProcessError.startTimeout(port: port) }
                if process.isRunning && process.ownsListeningLoopbackTCPPort(port) && process.isRunning {
                    try checkOwnedStart(slot, deadline: deadline, port: port)
                    return identity
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            if child != nil {
                let closeDeadline = markOwnedClose(slot)
                _ = await Task.detached { await self.waitForClose(slot, deadline: closeDeadline) }.value
            } else { releaseUnspawned(profileID, slot) }
            throw error
        }
    }
    public func stopOwned(_ identity: OwnedIdentity, timeoutSeconds: Double = 2) async throws -> ProcessExit? {
        let deadline = try Self.ownedDeadline(timeoutSeconds)
        let (slot, receipt) = try requestOwnedClose(identity)
        guard let slot else { return receipt }
        return await waitForClose(slot, deadline: deadline)
    }
    public func stopAllOwned(timeoutSeconds: Double = 2) async {
        guard let deadline = try? Self.ownedDeadline(timeoutSeconds) else { return }
        let slots = markAllOwnedClose()
        await withTaskGroup(of: Void.self) { group in
            for slot in slots { group.addTask { _ = await self.waitForClose(slot, deadline: deadline) } }
        }
    }

    /// 按 pid 文件结束遗留的代理内核（sing-box 或 mihomo）。只有该 profile 没有 Runner 在跑时才能调用（Runner 拿着 profile 锁时调用是安全的，
    /// 因为那时遗留进程一定不是它自己的）。pid 对应的进程不是代理内核（pid 被复用）时不动它。返回是否结束了进程。
    @discardableResult
    public static func reapOrphan(profileID: UUID, in directory: URL) -> Bool {
        let pidURL = pidFileURL(for: profileID, in: directory)
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8) else { return false }
        defer {
            try? FileManager.default.removeItem(at: pidURL)
            try? FileManager.default.removeItem(at: configurationFileURL(for: profileID, in: directory))
        }
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0, isProxyCore(pid) else { return false }
        terminate(pid: pid, isRunning: { kill(pid, 0) == 0 && isProxyCore(pid) })
        return true
    }

    private static func isProxyCore(_ pid: Int32) -> Bool {
        guard let name = executableName(of: pid) else { return false }
        return ProxyCoreEngine.knownExecutableNames.contains(name)
    }

    /// 图形管理器定时调用：有遗留 pid 文件、且拿得到 profile 锁（没有 Runner 在跑）时才清理。
    /// 拿锁这一步排除了"Runner 刚起来、新 sing-box 刚写 pid 文件"的竞争。
    @discardableResult
    public static func reapOrphanIfIdle(profileID: UUID, workspace: SafarierWorkspace) -> Bool {
        let directory = workspace.singboxDirectory
        guard FileManager.default.fileExists(atPath: pidFileURL(for: profileID, in: directory).path),
              let lock = try? ProfileLock.acquire(profileID: profileID, in: workspace.locksDirectory) else { return false }
        defer { lock.release() }
        return reapOrphan(profileID: profileID, in: directory)
    }

    private static func terminate(pid: Int32, isRunning: () -> Bool) {
        guard isRunning() else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while isRunning(), Date() < deadline { usleep(20_000) }
        if isRunning() { kill(pid, SIGKILL) }
    }

    private static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    private func removeStateFiles(for profileID: UUID) {
        try? FileManager.default.removeItem(at: configurationFileURL(for: profileID))
        try? FileManager.default.removeItem(at: pidFileURL(for: profileID))
    }

    /// 配置里有节点密码，只给自己读写。
    private static func writePrivate(_ data: Data, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    deinit {
        for slot in owned.values { _ = slot.process?.requestTermination() }
        if !processes.isEmpty { stopAll() }
    }
}
