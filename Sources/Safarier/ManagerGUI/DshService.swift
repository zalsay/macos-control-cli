import AppKit
import Foundation
import Combine
import WebKit

/// DeepSeek Harness (dsh) 本地服务生命周期管控层。
/// 负责检测 dsh CLI、启动后台 Web UI 服务（动态端口）、解析认证 URL 并管理进程生命周期。
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

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var terminationObserver: NSObjectProtocol?

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
         environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }) {
        self.controlledProvider = controlledProvider
        self.controlledHome = homeURL
        self.controlledEnvironment = environment
        installTerminationObserver()
    }
    #else
    private init() { installTerminationObserver() }
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

    /// 启动 dsh web 服务（使用动态端口 --port 0）
    func start() {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        if failedLeases.isEmpty { mountUncertain = false }
        controlledStart()
        #else
        guard status == .stopped || isFailed else { return }

        guard let executable = locateBinary() else {
            status = .failed("未检测到 Safarier 专用 DeepSeek Harness 运行时。\n请在项目根目录运行 scripts/build-dsh.sh 进行构建。")
            return
        }

        stopProcessOnly()

        status = .starting
        currentURL = nil
        logs.removeAll()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["web", "--no-open", "--port", "0"]

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
                self?.handleOutput(text)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.handleOutput(text)
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
    func stop() {
        cachedWebView?.stopLoading()
        cachedWebView?.removeFromSuperview()
        cachedWebView = nil
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
            if proc.isRunning {
                Darwin.kill(proc.processIdentifier, SIGKILL)
            }
        }
        #else
        stopProcessOnly()
        #endif
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
        guard controlledProcess == nil && acquisition == nil else { return }
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
        proc.arguments = [lease.entryURL.path, "web", "--no-open", "--port", "0"]
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
                    self.handleOutput(text)
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

    private func handleOutput(_ text: String) {
        logs.append(text)
        if logs.count > 120 { logs.removeFirst(logs.count - 120) }

        if case .starting = status {
            let lines = text.components(separatedBy: .newlines)
            for line in lines {
                // 查找形如 dsh web: http://127.0.0.1:55047/?token=... 的输出
                if line.contains("http://127.0.0.1:") || line.contains("http://localhost:") {
                    if let range = line.range(of: "https?://[^\\s\\)\\]]+", options: .regularExpression) {
                        let candidate = String(line[range])
                        if let url = URL(string: candidate) {
                            self.currentURL = url
                            self.status = .running(url: url)
                            return
                        }
                    }
                }
            }
        }
    }

    /// 获取或复用持久化的 dsh Web 视图，支持在切换 Tab 时保活会话与 DOM 状态，避免重复加载
    func getOrCreateWebView(for url: URL) -> WKWebView {
        if let existing = cachedWebView {
            existing.removeFromSuperview()
            if existing.url == nil || (existing.url?.host != url.host || existing.url?.port != url.port) {
                existing.load(URLRequest(url: url))
            }
            return existing
        }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // 使用默认持久化 dataStore 保存登录态与工作区会话
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Safarier/1.0"
        wv.load(URLRequest(url: url))

        cachedWebView = wv
        return wv
    }

    private func handleTermination(_ proc: Process) {
        cachedWebView?.stopLoading()
        cachedWebView?.removeFromSuperview()
        cachedWebView = nil
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
