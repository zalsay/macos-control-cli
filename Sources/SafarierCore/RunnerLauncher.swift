import Foundation

/// 抽象出进程创建，方便测试 Manager 的启动逻辑。
public protocol ProcessSpawning: Sendable {
    /// 启动后立即返回 pid，不等待子进程结束。
    func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32
    func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> Int32
    func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> OwnedRunnerProcess
}

public enum ControlledLaunchError: Error, Equatable {
    case unsupportedControlledInput, unsupportedOwnedProcess, missingControlledInput, unexpectedControlledInput, incompatibleMode, backgroundNotAllowed
}
public extension ProcessSpawning {
    func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> OwnedRunnerProcess {
        throw ControlledLaunchError.unsupportedOwnedProcess
    }
    func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> Int32 {
        throw ControlledLaunchError.unsupportedControlledInput
    }
}

/// 子进程退出信息。图形管理器靠它发现 Runner 启动失败，命令行不关心。
public struct ProcessExit: Equatable, Sendable {
    public var pid: Int32
    /// 正常退出时是退出码，被信号结束时是信号编号。
    public var status: Int32
    public var uncaughtSignal: Bool

    public init(pid: Int32, status: Int32, uncaughtSignal: Bool) {
        self.pid = pid
        self.status = status
        self.uncaughtSignal = uncaughtSignal
    }

    /// 退出码非 0 或崩溃算失败；被 TERM/KILL/INT/HUP 结束（用户强制退出、注销）不算。
    public var isFailure: Bool {
        uncaughtSignal ? ![SIGTERM, SIGKILL, SIGINT, SIGHUP].contains(status) : status != 0
    }
}

public struct FoundationProcessSpawner: ProcessSpawning {
    /// 在任意线程回调。
    public var onExit: (@Sendable (ProcessExit) -> Void)?

    public init(onExit: (@Sendable (ProcessExit) -> Void)? = nil) {
        self.onExit = onExit
    }

    public func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
        try spawnProcess(executableURL: executableURL, arguments: arguments, environment: environment, logURL: logURL, standardInput: nil, ownedState: nil).processIdentifier
    }

    public func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> Int32 {
        try spawnProcess(executableURL: executableURL, arguments: arguments, environment: environment, logURL: logURL, standardInput: standardInput, ownedState: nil).processIdentifier
    }

    public func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle) throws -> OwnedRunnerProcess {
        let state = OwnedRunnerProcess.State()
        let process = try spawnProcess(executableURL: executableURL, arguments: arguments, environment: environment, logURL: logURL, standardInput: standardInput, ownedState: state)
        return OwnedRunnerProcess(process: process, state: state)
    }

    public func spawnOwned(executableURL: URL, arguments: [String], environment: [String: String], standardInput: FileHandle, standardOutput: FileHandle, standardError: FileHandle) throws -> OwnedRunnerProcess {
        let state = OwnedRunnerProcess.State()
        let process = try spawnProcess(executableURL: executableURL, arguments: arguments, environment: environment, logURL: nil, standardInput: standardInput, ownedState: state, standardOutput: standardOutput, standardError: standardError)
        return OwnedRunnerProcess(process: process, state: state)
    }

    private func spawnProcess(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?, standardInput: FileHandle?, ownedState: OwnedRunnerProcess.State?, standardOutput: FileHandle? = nil, standardError: FileHandle? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = standardInput ?? FileHandle.nullDevice
        if let logURL {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }
        if let standardOutput { process.standardOutput = standardOutput }
        if let standardError { process.standardError = standardError }
        if ownedState != nil || onExit != nil {
            let callback = onExit
            process.terminationHandler = { process in
                let result = ProcessExit(pid: process.processIdentifier, status: process.terminationStatus, uncaughtSignal: process.terminationReason == .uncaughtSignal)
                if let ownedState {
                    if ownedState.record(result) { callback?(result) }
                } else { callback?(result) }
            }
        }
        try process.run()
        return process
    }
}

/// Manager 侧：把一个 profile 交给独立的 Runner 进程。每个 profile 一个进程，
/// 这样语言、时区这类进程级设置互不影响，崩溃也不会连带。
public struct RunnerLauncher: Sendable {
    public let executableURL: URL
    public let spawner: any ProcessSpawning
    public let logDirectory: URL?

    public init(
        executableURL: URL = RunnerLauncher.defaultRunnerExecutableURL(),
        spawner: any ProcessSpawning = FoundationProcessSpawner(),
        logDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.spawner = spawner
        self.logDirectory = logDirectory
    }

    private func prepare(_ spec: RunnerLaunchSpec, baseEnvironment: [String: String], controlInput: FileHandle?) throws -> (arguments: [String], environment: [String: String], logURL: URL?) {
        guard !(spec.probe && spec.backgroundAutomation) else { throw ControlledLaunchError.incompatibleMode }
        if spec.backgroundAutomation {
            guard spec.startURL == URL(string: "about:blank"), spec.spiOverride == nil else { throw ControlledLaunchError.incompatibleMode }
            guard let controlInput else { throw ControlledLaunchError.missingControlledInput }
            try AutomationChannel.validateConnectedStream(fileDescriptor: controlInput.fileDescriptor)
        } else {
            guard controlInput == nil else { throw ControlledLaunchError.unexpectedControlledInput }
        }
        return (spec.arguments(), spec.environment(inheriting: baseEnvironment), logDirectory?.appendingPathComponent("\(spec.profileID.uuidString).log"))
    }

    @discardableResult
    public func launch(
        _ spec: RunnerLaunchSpec,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        controlInput: FileHandle? = nil
    ) throws -> Int32 {
        let prepared = try prepare(spec, baseEnvironment: baseEnvironment, controlInput: controlInput)
        if let controlInput {
            return try spawner.spawn(executableURL: executableURL, arguments: prepared.arguments, environment: prepared.environment, logURL: prepared.logURL, standardInput: controlInput)
        }
        return try spawner.spawn(executableURL: executableURL, arguments: prepared.arguments, environment: prepared.environment, logURL: prepared.logURL)
    }

    /// Controlled-background launch returning the exact owned Foundation process.
    public func launchOwned(_ spec: RunnerLaunchSpec, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, controlInput: FileHandle? = nil) throws -> OwnedRunnerProcess {
        guard spec.backgroundAutomation else { throw ControlledLaunchError.incompatibleMode }
        let prepared = try prepare(spec, baseEnvironment: baseEnvironment, controlInput: controlInput)
        guard let controlInput else { throw ControlledLaunchError.missingControlledInput }
        return try spawner.spawnOwned(executableURL: executableURL, arguments: prepared.arguments, environment: prepared.environment, logURL: prepared.logURL, standardInput: controlInput)
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    /// The registration socket is only a transport: it does not confer control.
    /// Authentication and a fresh bounded generation must follow normal preparation.
    public func launchOwnedInteractive(_ spec: RunnerLaunchSpec, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, registrationInput: FileHandle) throws -> OwnedRunnerProcess {
        guard !spec.backgroundAutomation, !spec.probe, !spec.registeredInteractive else { throw ControlledLaunchError.incompatibleMode }
        try AutomationChannel.validateConnectedStream(fileDescriptor: registrationInput.fileDescriptor)
        var registered = spec
        registered.registeredInteractive = true
        let prepared = try prepare(registered, baseEnvironment: baseEnvironment, controlInput: nil)
        return try spawner.spawnOwned(executableURL: executableURL, arguments: prepared.arguments, environment: prepared.environment, logURL: prepared.logURL, standardInput: registrationInput)
    }
    #endif

    public static func defaultRunnerExecutableURL() -> URL {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        // Structural locator only; authorization remains with the C-verified role pair.
        let current = currentExecutableURL()
        guard let roles = try? BoundBundleRoles(selfExecutablePath: current.path) else { return current }
        switch roles.role {
        case .main: return URL(fileURLWithPath: roles.runnerExecutablePath)
        case .runner: return current
        }
        #else
        let current = currentExecutableURL()
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension.lowercased() == "app" {
            let candidates = [
                bundleURL.appendingPathComponent("Contents/Helpers/Safarier AI Browser.app/Contents/MacOS/Safarier AI Browser"),
                bundleURL.appendingPathComponent("Contents/Helpers/Safarier AI Browser.app/Contents/MacOS/Safarier"),
                bundleURL.deletingLastPathComponent().appendingPathComponent("Safarier AI Browser.app/Contents/MacOS/Safarier AI Browser"),
                bundleURL.deletingLastPathComponent().appendingPathComponent("Safarier AI Browser.app/Contents/MacOS/Safarier")
            ]
            for candidate in candidates {
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return current
        #endif
    }

    public static func currentExecutableURL() -> URL {
        Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }
}
