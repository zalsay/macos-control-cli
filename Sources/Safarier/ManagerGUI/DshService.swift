import AppKit
import Foundation
import Combine
import WebKit
import Darwin

struct DshLANConfiguration: Equatable {
    static let fileName = "lan-listener.json"
    static let trustedHost = "i.meetlife.com.cn:3000"
    static let publicURL = "https://i.meetlife.com.cn:3000/dsh-mac/"
    static let port = 61919

    let bindAddress: String

    /// Probe only for an address collision. Let the actual server report all
    /// other bind errors; never connect to or assume ownership of the listener.
    static func portOccupied(_ host: String) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) != 0 && errno == EADDRINUSE
            }
        }
    }

    static func load(from url: URL, localIPv4Addresses: Set<String>) -> Self? {
        guard let data = readUserOwned0600File(at: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              Set(fields.keys) == Set(["version", "enabled", "bindAddress"]),
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == 1, version.doubleValue == 1,
              let enabled = fields["enabled"] as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue,
              let address = fields["bindAddress"] as? String,
              isPrivateIPv4(address), localIPv4Addresses.contains(address) else { return nil }
        return Self(bindAddress: address)
    }

    static func arguments(for configuration: Self?) -> [String] {
        var arguments = ["web", "--no-open", "--port", String(port)]
        guard let configuration else { return arguments }
        arguments += ["--host", configuration.bindAddress,
                      "--public-url", publicURL,
                      "--trusted-host", trustedHost]
        return arguments
    }

    static func localIPv4Addresses() -> Set<String> {
        var addresses = Set<String>()
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return addresses }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            if let address = current.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.insert(String(cString: buffer))
                }
            }
            cursor = current.pointee.ifa_next
        }
        return addresses
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, octets.map(String.init).joined(separator: ".") == address else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private static func readUserOwned0600File(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_uid == geteuid(),
              (attributes.st_mode & 0o777) == 0o600 else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 16_384 { return nil }
        }
    }
}

struct DshNativeLaunchReceipt: Encodable {
    let version = 1
    let service = "dsh"
    let bindAddress: String
    let port = DshLANConfiguration.port
    let publicURL = DshLANConfiguration.publicURL
    let token: String

    static let fileName = "native-launch.json"

    static func write(_ receipt: Self, to url: URL) throws {
        let data = try JSONEncoder().encode(receipt)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { unlink(temporary.path) }
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        shouldRemoveTemporary = false

        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    static func remove(at url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        var attributes = stat()
        let safeToRemove = fstat(descriptor, &attributes) == 0
            && (attributes.st_mode & S_IFMT) == S_IFREG
            && attributes.st_uid == geteuid()
        close(descriptor)
        if safeToRemove { _ = unlink(url.path) }
    }
}

enum DshStartupURL {
    static func advertisedURL(in text: String) -> URL? {
        guard let range = text.range(of: "https?://[^\\s\\)\\]]+", options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    static func token(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 1, items[0].name == "token",
              let token = items[0].value, !token.isEmpty,
              token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return token
    }

    static func localBootstrapURL(bindAddress: String, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        // Keep the native WebView on the bound Mac address, never the portal URL.
        components.host = bindAddress
        components.port = DshLANConfiguration.port
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    static func isExpectedPublicURL(_ url: URL) -> Bool {
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: DshLANConfiguration.publicURL),
              actual.scheme == expected.scheme, actual.host == expected.host, actual.port == expected.port,
              actual.path == expected.path, actual.user == nil, actual.password == nil, actual.fragment == nil,
              token(in: url) != nil else { return false }
        return true
    }

    static func sanitizedLog(_ text: String) -> String {
        if text.hasPrefix("dsh web: ") { return "dsh web: [startup URL redacted]" }
        return text.replacingOccurrences(
            of: "([?&]token=)[^&\\s\\)\\]]+",
            with: "$1[redacted]",
            options: .regularExpression
        )
    }
}

private enum DshOutputStream: Equatable {
    case stdout
    case stderr
}

/// DeepSeek Harness (dsh) 本地服务生命周期管控层。
/// 负责检测 dsh CLI、启动后台 Web UI 服务（固定端口 61919）、解析认证 URL 并管理进程生命周期。
@MainActor
final class DshService: ObservableObject {
    static let shared = DshService()

    enum Status: Equatable {
        case stopped
        case starting
        case running(url: URL)
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var currentURL: URL? = nil
    @Published private(set) var binaryPath: String? = nil
    @Published var logs: [String] = []
    @Published private(set) var cachedWebView: WKWebView?
    private var webNavigation: DshWebNavigation?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var terminationObserver: NSObjectProtocol?
    private let availableIPv4Addresses: () -> Set<String>
    private let portOccupied: (String) -> Bool
    private var portWait: Task<Void, Never>?
    private var activeLANConfiguration: DshLANConfiguration?
    private var launchReceiptURL: URL?
    private var pendingStdoutLine = ""
    private var pendingStderrLine = ""

    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    typealias ControlledProvider = () async throws -> any DshControlledRuntime.Lease
    private let controlledProvider: ControlledProvider
    private let controlledHome: URL
    private let controlledEnvironment: () -> [String: String]
    private var generation = 0
    private var acquisition: Task<Void, Never>?
    private var controlledProcess: Process?
    private var controlledLease: (any DshControlledRuntime.Lease)?
    private var failedLeases: [any DshControlledRuntime.Lease] = []
    private static var retainedLeases: [any DshControlledRuntime.Lease] = []
    private var launchedLease: (any DshControlledRuntime.Lease)?
    private var wantsStart = false
    private var mountUncertain = false

    init(controlledProvider: @escaping ControlledProvider = { try await DshControlledRuntime().acquire() },
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         availableIPv4Addresses: @escaping () -> Set<String> = { DshLANConfiguration.localIPv4Addresses() },
         portOccupied: @escaping (String) -> Bool = DshLANConfiguration.portOccupied) {
        self.controlledProvider = controlledProvider
        self.controlledHome = homeURL
        self.controlledEnvironment = environment
        self.portOccupied = portOccupied
        self.availableIPv4Addresses = availableIPv4Addresses
        installTerminationObserver()
    }
    #else
    private init() {
        self.portOccupied = DshLANConfiguration.portOccupied
        self.availableIPv4Addresses = { DshLANConfiguration.localIPv4Addresses() }
        installTerminationObserver()
    }
    #endif

    private func installTerminationObserver() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
                #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
                for lease in Self.retainedLeases {
                    Task { try? await lease.close() }
                }
                #endif
            }
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        // The owned process is retained by its termination callback until exit.
        #else
        process?.terminate()
        #endif
    }

    /// 探测 Safarier 内部专用的 dsh 可执行文件路径。
    /// 严禁复用系统全局或 ~/.local/bin/dsh，避免与其他会话产生端口、数据库锁和环境污染冲突。
    func locateBinary() -> String? {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        return binaryPath
        #else
        if let binaryPath, FileManager.default.isExecutableFile(atPath: binaryPath) {
            return binaryPath
        }

        // 1. App Bundle 内置 Safarier dsh 运行时
        let bundleCandidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/dsh/bin/dsh").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dsh/bin/dsh").path
        ]
        for path in bundleCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                binaryPath = path
                return path
            }
        }

        // 2. 本地开发与工作区构建产物 (.build/dsh/bin/dsh)
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(cwd)/.build/dsh/bin/dsh",
            "\(cwd)/dist/Safarier AI.app/Contents/Resources/dsh/bin/dsh",
            "\(cwd)/dist/Safarier AI.app/Contents/Helpers/dsh/bin/dsh",
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".build/dsh/bin/dsh").path
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                binaryPath = path
                return path
            }
        }

        return nil
        #endif
    }

    /// 启动 dsh web 服务；固定端口保持 Web UI 的 localStorage origin。
    func start() {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        if failedLeases.isEmpty { mountUncertain = false }
        controlledStart()
        #else
        guard status == .stopped || isFailed else { return }

        guard prepareListenerConfiguration(home: FileManager.default.homeDirectoryForCurrentUser) else { return }

        guard let executable = locateBinary() else {
            status = .failed("未检测到 Safarier 专用 DeepSeek Harness 运行时。\n请在项目根目录运行 scripts/build-dsh.sh 进行构建。")
            return
        }

        stopProcessOnly()

        status = .starting
        currentURL = nil
        logs.removeAll()
        pendingStdoutLine = ""
        pendingStderrLine = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = DshLANConfiguration.arguments(for: activeLANConfiguration)

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(extraPaths):" + (env["PATH"] ?? "")

        // 严格隔离 DSH 用户数据与数据库沙盒，避免与系统 ~/.dsh 或其他应用冲突
        let dshHome = "\(home)/Library/Application Support/Safarier/dsh"
        let dshAgents = "\(dshHome)/agents"
        try? FileManager.default.createDirectory(atPath: dshHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: dshAgents, withIntermediateDirectories: true)
        env["DSH_HOME"] = dshHome
        env["DSH_AGENTS_HOME"] = dshAgents

        // 清理不兼容或冲突的外部代理变量，保证内部独立 Web 服务与 API 通讯纯净
        env.removeValue(forKey: "all_proxy")
        env.removeValue(forKey: "ALL_PROXY")
        env.removeValue(forKey: "http_proxy")
        env.removeValue(forKey: "HTTP_PROXY")
        env.removeValue(forKey: "https_proxy")
        env.removeValue(forKey: "HTTPS_PROXY")

        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
            self?.handleOutput(text, from: .stdout)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
            self?.handleOutput(text, from: .stderr)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleTermination(proc)
            }
        }

        do {
            try proc.run()
        } catch {
            status = .failed("启动失败：\(error.localizedDescription)")
        }
        #endif
    }

    /// 停止 dsh 服务
    var fullExitProcessID: Int32? {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        let child = controlledProcess
        #else
        let child = process
        #endif
        return child?.isRunning == true ? child?.processIdentifier : nil
    }

    func stop(gracefulOnly: Bool = false) {
        portWait?.cancel()
        portWait = nil
        cachedWebView?.stopLoading()
        cachedWebView?.removeFromSuperview()
        cachedWebView = nil
        webNavigation = nil
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        wantsStart = false
        generation += 1
        acquisition?.cancel()
        if let proc = controlledProcess, proc.isRunning {
            proc.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            while proc.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !gracefulOnly && proc.isRunning {
                Darwin.kill(proc.processIdentifier, SIGKILL)
            }
        }
        #else
        stopProcessOnly()
        #endif
        if let launchReceiptURL { DshNativeLaunchReceipt.remove(at: launchReceiptURL) }
        launchReceiptURL = nil
        activeLANConfiguration = nil
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        if failedLeases.isEmpty && !mountUncertain { status = .stopped }
        #else
        status = .stopped
        #endif
        currentURL = nil
    }

    /// 重启服务
    func restart() {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        stop()
        failedLeases.removeAll()
        mountUncertain = false
        controlledStart()
        #else
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
        #endif
    }

    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    private func controlledStart() {
        guard status == .stopped || isFailed else { return }
        guard failedLeases.isEmpty && !mountUncertain else {
            status = .failed("DSH 运行时卸载失败，挂载状态未知；请检查运行日志。")
            return
        }
        wantsStart = true
        status = .starting
        currentURL = nil
        logs.removeAll()
        pendingStdoutLine = ""
        pendingStderrLine = ""
        guard controlledProcess == nil && acquisition == nil else { return }
        guard prepareListenerConfiguration(home: controlledHome) else { return }
        generation += 1
        let token = generation
        if let lease = launchedLease {
            launchControlled(lease, token: token)
            return
        }
        guard controlledLease == nil else { return }
        let provider = controlledProvider
        acquisition = Task { [self] in
            do {
                let lease = try await provider()
                if Task.isCancelled || token != generation || !wantsStart {
                    acquisition = nil
                    controlledLease = lease
                    await release(lease, token: token)
                    return
                }
                acquisition = nil
                controlledLease = lease
                launchControlled(lease, token: token)
            } catch {
                acquisition = nil
                if case DshControlledRuntime.Failure.mountStateUncertain = error {
                    mountUncertain = true
                    wantsStart = false
                    status = .failed("DSH 挂载状态未知，未确认卸载：\(error)")
                    logs.append("DSH 挂载状态未知：\(error)")
                    return
                }
                if token == generation && wantsStart {
                    acquisition = nil
                    status = .failed("受控 DSH 运行时不可用（未批准的信任锚或 sidecar 校验失败）：\(error)")
                } else if !(error is CancellationError) {
                    logs.append("DSH 运行时获取或清理失败：\(error)")
                    if case DshControlledRuntime.Failure.mountStateUncertain = error {
                        status = .failed("DSH 挂载状态未知：\(error)")
                    }
                }
                if wantsStart && token != generation && failedLeases.isEmpty {
                    if case DshControlledRuntime.Failure.mountStateUncertain = error { return }
                    status = .stopped
                    controlledStart()
                }
            }
        }
    }

    private func launchControlled(_ lease: any DshControlledRuntime.Lease, token: Int) {
        let proc = Process()
        proc.executableURL = lease.nodeURL
        proc.arguments = [lease.entryURL.path] + DshLANConfiguration.arguments(for: activeLANConfiguration)
        binaryPath = lease.nodeURL.path
        var env = controlledEnvironment()
        for key in Array(env.keys) where key == "NODE_OPTIONS" || key == "NODE_PATH" || key == "NODE_BINARY" || key.hasPrefix("DYLD_") || ["all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"].contains(key) { env.removeValue(forKey: key) }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        let home = controlledHome.appendingPathComponent("Library/Application Support/Safarier/dsh", isDirectory: true)
        let agents = home.appendingPathComponent("agents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        } catch {
            status = .failed("无法创建 DSH 用户目录：\(error.localizedDescription)")
            if launchedLease == nil { Task { await release(lease, token: token) } }
            return
        }
        env["DSH_HOME"] = home.path
        env["DSH_AGENTS_HOME"] = agents.path
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        stdoutPipe = out; stderrPipe = err
        for pipe in [out, err] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.controlledProcess === proc else { return }
                    self.handleOutput(text, from: pipe === out ? .stdout : .stderr)
                }
            }
        }
        controlledProcess = proc
        proc.terminationHandler = { [self] finished in
            DispatchQueue.main.async { [self] in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if controlledProcess === finished {
                    controlledProcess = nil
                    stdoutPipe = nil; stderrPipe = nil
                    if token == generation { handleTermination(finished) }
                }
                finished.terminationHandler = nil
                // Descendants may still use the image. Retain the verified lease
                // for the manager lifetime and reuse it for subsequent launches.
                logs.append("运行时挂载已保留，未执行卸载。")
                if wantsStart && token != generation {
                    status = .stopped
                    controlledStart()
                }
            }
        }
        do {
            try proc.run()
            if launchedLease == nil {
                launchedLease = lease
                Self.retainedLeases.append(lease)
            }
        }
        catch {
            proc.terminationHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            controlledProcess = nil
            stdoutPipe = nil; stderrPipe = nil
            status = .failed("启动失败：\(error.localizedDescription)")
            if launchedLease == nil { Task { await release(lease, token: token) } }
        }
    }

    private func release(_ lease: any DshControlledRuntime.Lease, token: Int) async {
        do { try await lease.close() }
        catch {
            failedLeases.append(lease)
            wantsStart = false
            status = .failed("DSH 运行时卸载失败，挂载状态未知：\(error)")
            logs.append("DSH 运行时卸载失败：\(error)")
            return
        }
        controlledLease = nil
        if wantsStart && token != generation && controlledProcess == nil && acquisition == nil {
            status = .stopped
            controlledStart()
        }
    }
    #endif

    private func stopProcessOnly() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func handleOutput(_ text: String, from stream: DshOutputStream) {
        var pending = stream == .stdout ? pendingStdoutLine : pendingStderrLine
        pending += text
        guard pending.utf8.count <= 16_384 else {
            pending = ""
            if stream == .stdout { pendingStdoutLine = pending } else { pendingStderrLine = pending }
            logs.append("[DSH output line omitted: oversized]")
            return
        }
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .newlines)
            pending = String(pending[pending.index(after: newline)...])
            logs.append(DshStartupURL.sanitizedLog(line))
            if stream == .stdout { processStartupLine(line) }
            if logs.count > 120 { logs.removeFirst(logs.count - 120) }
        }
        if stream == .stdout { pendingStdoutLine = pending } else { pendingStderrLine = pending }
    }

    private func processStartupLine(_ line: String) {
        guard case .starting = status,
              line.hasPrefix("dsh web: "),
              let advertisedURL = URL(string: String(line.dropFirst("dsh web: ".count))),
              let token = DshStartupURL.token(in: advertisedURL) else { return }

        if let configuration = activeLANConfiguration {
            guard DshStartupURL.isExpectedPublicURL(advertisedURL),
                  let localURL = DshStartupURL.localBootstrapURL(bindAddress: configuration.bindAddress, token: token),
                  let receiptURL = launchReceiptURL else { return }
            let receipt = DshNativeLaunchReceipt(bindAddress: configuration.bindAddress, token: token)
            do {
                try DshNativeLaunchReceipt.write(receipt, to: receiptURL)
            } catch {
                currentURL = nil
                status = .failed("无法安全写入 DSH 本机启动凭据；LAN 服务未开放。")
                process?.terminate()
                #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
                controlledProcess?.terminate()
                #endif
                return
            }
            currentURL = localURL
            status = .running(url: localURL)
        } else if ["127.0.0.1", "localhost", "::1"].contains(advertisedURL.host?.lowercased() ?? ""),
                  advertisedURL.port == DshLANConfiguration.port {
            currentURL = advertisedURL
            status = .running(url: advertisedURL)
        }
    }

    private func prepareListenerConfiguration(home: URL) -> Bool {
        let dshHome = home.appendingPathComponent("Library/Application Support/Safarier/dsh", isDirectory: true)
        let receiptURL = dshHome.appendingPathComponent(DshNativeLaunchReceipt.fileName)
        activeLANConfiguration = DshLANConfiguration.load(
            from: dshHome.appendingPathComponent(DshLANConfiguration.fileName),
            localIPv4Addresses: availableIPv4Addresses()
        )
        let host = activeLANConfiguration?.bindAddress ?? "127.0.0.1"
        if portOccupied(host) {
            status = .starting
            logs = ["\(host):\(DshLANConfiguration.port) 仍由其他进程监听。等待端口释放后自动启动；现有连接保持运行。"]
            portWait?.cancel()
            portWait = Task { [weak self] in
                repeat {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    if self.portOccupied(host) { continue }
                    self.portWait = nil
                    self.status = .stopped
                    self.start()
                    return
                } while true
            }
            return false
        }
        DshNativeLaunchReceipt.remove(at: receiptURL)
        launchReceiptURL = receiptURL
        return true
    }

    /// 获取或复用持久化的 dsh Web 视图，支持在切换 Tab 时保活会话与 DOM 状态，避免重复加载
    func getOrCreateWebView(for url: URL) -> WKWebView {
        if let existing = cachedWebView {
            existing.removeFromSuperview()
            updateWebView(existing, for: url)
            return existing
        }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 使用默认持久化 dataStore 保存登录态与工作区会话
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Safarier/1.0"
        let navigation = DshWebNavigation(serviceURL: url)
        webNavigation = navigation
        wv.uiDelegate = navigation
        wv.navigationDelegate = navigation
        wv.load(URLRequest(url: url))

        cachedWebView = wv
        return wv
    }

    func updateWebView(_ webView: WKWebView, for url: URL) {
        guard webView === cachedWebView else { return }
        webNavigation?.serviceURL = url
        if webView.url.map({ DshWebNavigation.sameOrigin($0, url) }) != true {
            webView.load(URLRequest(url: url))
        }
    }

    private func handleTermination(_ proc: Process) {
        if let launchReceiptURL { DshNativeLaunchReceipt.remove(at: launchReceiptURL) }
        launchReceiptURL = nil
        cachedWebView?.stopLoading()
        cachedWebView?.removeFromSuperview()
        cachedWebView = nil
        webNavigation = nil
        if case .starting = status {
            status = .failed("dsh 进程异常退出（代码 \(proc.terminationStatus)）。\n请查看运行日志排查原因。")
        } else if case .running = status {
            status = .stopped
            currentURL = nil
        }
    }

    func reloadWeb() {
        if let wv = cachedWebView {
            wv.reload()
        } else {
            NotificationCenter.default.post(name: .dshReloadWeb, object: nil)
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

extension Notification.Name {
    static let dshReloadWeb = Notification.Name("sh.safarier.dshReloadWeb")
}
