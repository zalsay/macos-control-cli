import AppKit
import Darwin
import Foundation
import OSLog
import SafarierCore

enum ManagerHostAction: String, CaseIterable, Sendable {
    case start, status, authorize, authorizationStatus, stop
}

enum ManagerHostMenuPolicy {
    static func enabled(_ action: ManagerHostAction, profile: Profile?, busy: Bool) -> Bool {
        guard !busy, let profile else { return false }
        return (action != .start && action != .authorize) || profile.allowsAgentAccess
    }
}

@MainActor
protocol ManagerHostServicing {
    func perform(_ action: ManagerHostAction, profileID: UUID) async throws -> String
    func authorization(profileID: UUID, requestID: UUID?) async throws -> HostAuthorizationReceipt
}

/// Owns only Hosts started by this Manager instance. In particular, observing
/// a pre-existing socket never adopts its server as a GUI-owned child.
@MainActor
final class ManagerHostDaemonService: ManagerHostServicing {
    private static let startTimeout: TimeInterval = 15
    private static let exchangeTimeout: TimeInterval = 75
    private static let childExitTimeout: TimeInterval = 15
    private static let socketRemovalTimeout: TimeInterval = 5
    private static let localRuntime = NSHomeDirectory() + "/.safarier-control"
    private static let localLog = Logger(subsystem: "sh.safarier", category: "local-control-startup")

    private var children: [UUID: ManagerHostChild] = [:]
    private var startingProfiles: Set<UUID> = []
    private var stopTasks: [UUID: (id: UUID, task: Task<Void, Error>)] = [:]
    private var shutdownTask: (id: UUID, task: Task<Void, Error>)?
    private var explicitExitTask: Task<Void, Error>?
    private var explicitExitCompleted = false
    private var shuttingDown = false
    private var localDaemon: ManagerHostChild?
    private var localStartup: Task<Void, Never>?
    #if SAFARIER_CONTROL_TESTING
    var testLocalStartup: (@MainActor () async throws -> Void)?
    #endif

    var hasOwnedChildren: Bool { !children.isEmpty || localDaemon != nil }
    var needsTerminationCheck: Bool { hasOwnedChildren || !startingProfiles.isEmpty || localStartup != nil }

    /// Reserve before returning to the launch caller; Runner launch does not wait for the daemon.
    func scheduleLocalDaemon(for profile: Profile) {
        guard profile.allowsAgentAccess, !shuttingDown, localStartup == nil else { return }
        localStartup = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { localStartup = nil }
            do { try await ensureLocalDaemon() }
            catch { Self.localLog.error("默认 SFA daemon 未就绪；浏览器照常运行：\(error.localizedDescription, privacy: .public)") }
        }
    }

    private func ensureLocalDaemon() async throws {
        guard !shuttingDown else { return }
        #if SAFARIER_CONTROL_TESTING
        if let testLocalStartup { return try await testLocalStartup() }
        #endif
        guard let executable = Bundle.main.executableURL else {
            throw ManagerHostFailure.unavailable("无法定位 Safarier 可执行文件。")
        }
        let appPath = Bundle.main.bundleURL.path
        let runtimePath = Self.localRuntime
        if let child = localDaemon {
            if child.process.isRunning {
                try await verifyLocalDaemon(applicationPath: appPath, expectedPeerPID: child.pid)
                return
            }
            forget(child)
        }
        if try await Self.localEndpointConnectable(runtimePath, create: true) {
            try await verifyLocalDaemon(applicationPath: appPath, expectedPeerPID: nil)
            return
        }
        guard let state = try await Self.startupSocketState(runtimePath) else {
            throw ManagerHostFailure.unavailable("默认控制 runtime 正忙；未启动或替换 daemon。")
        }
        if case .active = state {
            try await verifyLocalDaemon(applicationPath: appPath, expectedPeerPID: nil)
            return
        }
        guard !shuttingDown else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["control", "daemon", "serve", "--app", appPath, "--runtime", runtimePath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let child = ManagerHostChild(process: process, profileID: nil, runtimePath: runtimePath)
        process.terminationHandler = { [weak child] process in
            let status = process.terminationStatus
            Task { @MainActor in child?.recordExit(status) }
        }
        try process.run()
        localDaemon = child
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.startTimeout))
        while process.isRunning, ContinuousClock.now < deadline {
            if (try? await Self.localEndpointConnectable(runtimePath, create: false)) == true {
                try await verifyLocalDaemon(applicationPath: appPath, expectedPeerPID: child.pid)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !process.isRunning, !(await Self.socketExistsOffMain(child.socketPath)) { forget(child) }
        throw ManagerHostFailure.unavailable("未确认 Manager 启动的默认 SFA daemon 就绪。")
    }

    nonisolated private static func localEndpointConnectable(_ runtimePath: String, create: Bool) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            try ControlRuntime(path: runtimePath, create: create).endpointIsConnectable()
        }.value
    }

    private func verifyLocalDaemon(applicationPath: String, expectedPeerPID: Int32?) async throws {
        do {
            let (reply, _) = try await requestWithEndpointIdentity(.capabilities, applicationPath: applicationPath,
                runtimePath: Self.localRuntime, expectedPeerPID: expectedPeerPID, timeout: Self.startTimeout)
            guard reply.capabilities?.managerPID == Int(getpid()) else {
                throw ManagerHostFailure.unavailable("默认 SFA daemon 没有返回当前 Manager 的身份。")
            }
        } catch {
            throw ManagerHostFailure.unavailable("默认 SFA daemon 未通过 Manager 身份或 Apple Events 检查；未触发授权或替换进程。")
        }
    }

    private func forget(_ child: ManagerHostChild) {
        if let profileID = child.profileID {
            if children[profileID] === child { children[profileID] = nil }
        } else if localDaemon === child {
            localDaemon = nil
        }
    }

    func perform(_ action: ManagerHostAction, profileID: UUID) async throws -> String {
        guard explicitExitTask == nil else {
            throw ManagerHostFailure.unavailable("Manager 正在执行完整退出检查；请等待检查完成后再操作 Host。")
        }
        guard let executablePath = Bundle.main.executableURL?.path else {
            throw ManagerHostFailure.unavailable("无法定位 Safarier 可执行文件。")
        }
        let applicationPath = Bundle.main.bundleURL.path
        let runtimePath = RemoteHostRuntime.path(for: profileID)
        switch action {
        case .start:
            return try await startOwnedChild(profileID: profileID, executablePath: executablePath,
                                              applicationPath: applicationPath, runtimePath: runtimePath)
        case .status:
            return try await status(profileID: profileID, applicationPath: applicationPath, runtimePath: runtimePath)
        case .stop:
            return try await stop(profileID: profileID, applicationPath: applicationPath, runtimePath: runtimePath)
        case .authorize, .authorizationStatus:
            throw ManagerHostFailure.unavailable("请使用 Host 授权入口。")
        }
    }

    func authorization(profileID: UUID, requestID: UUID?) async throws -> HostAuthorizationReceipt {
        guard explicitExitTask == nil else {
            throw ManagerHostFailure.unavailable("Manager 正在执行完整退出检查；请等待检查完成后再操作 Host。")
        }
        let runtimePath = RemoteHostRuntime.path(for: profileID)
        let socketPath = runtimePath + "/control.sock"
        guard await Self.socketExistsOffMain(socketPath) else {
            throw ManagerHostFailure.unavailable("请先启动该环境的 Host。")
        }
        let operation: ControlOperation = requestID.map { .authorizationStatus(requestID: $0) } ?? .authorizationRequest
        let childPID = children[profileID]?.pid
        let reply = try await request(operation, applicationPath: Bundle.main.bundleURL.path,
                                      runtimePath: runtimePath, expectedPeerPID: childPID)
        guard let receipt = reply.authorization, !receipt.businessEventSent,
              requestID.map({ receipt.requestID == $0 }) ?? (receipt.status == "pending") else {
            throw ManagerHostFailure.unavailable("授权状态未确认；没有重试授权请求。")
        }
        return receipt
    }

    /// Called before Manager termination. This is deliberately restricted to
    /// retained Process instances; a CLI-started daemon is never adopted here.
    func stopOwnedChildrenForTermination() async throws {
        if let explicitExitTask {
            try await explicitExitTask.value
            return
        }
        if let shutdownTask {
            try await shutdownTask.task.value
            return
        }
        shuttingDown = true
        let taskID = UUID()
        let task = Task { @MainActor [self] in
            await localStartup?.value
            let profileIDs = children.keys.sorted { $0.uuidString < $1.uuidString }
            var failures: [String] = []
            for profileID in profileIDs {
                guard let child = children[profileID] else { continue }
                do { try await stopOwnedChild(child, applicationPath: Bundle.main.bundleURL.path) }
                catch { failures.append("\(profileID.uuidString): \(error.localizedDescription)") }
            }
            if let child = localDaemon {
                do { try await stopOwnedChildNow(child, applicationPath: Bundle.main.bundleURL.path) }
                catch { failures.append("默认 SFA daemon: \(error.localizedDescription)") }
            }
            guard failures.isEmpty else {
                throw ManagerHostFailure.unavailable("Manager 未退出：一个或多个 GUI-owned Host 未确认安全停止。\n" + failures.joined(separator: "\n"))
            }
        }
        shutdownTask = (taskID, task)
        do {
            try await task.value
        } catch {
            if shutdownTask?.id == taskID { shutdownTask = nil }
            shuttingDown = false
            throw error
        }
        if shutdownTask?.id == taskID { shutdownTask = nil }
    }

    /// Explicit full-exit action: stop only retained Manager-owned scoped Hosts
    /// and the one documented default CLI runtime. It never discovers or adopts
    /// other runtimes, and it never signals a process or removes a socket itself.
    func stopBackendsForExplicitExit() async throws {
        if let explicitExitTask {
            try await explicitExitTask.value
            return
        }
        guard shutdownTask == nil else {
            throw ManagerHostFailure.unavailable("Manager 的系统退出检查正在进行；请等待当前检查完成。")
        }
        shuttingDown = true
        let task = Task { @MainActor [self] in try await stopBackendsForExplicitExitNow() }
        explicitExitTask = task
        do {
            try await task.value
            explicitExitCompleted = true
        } catch {
            explicitExitTask = nil
            explicitExitCompleted = false
            shuttingDown = false
            throw error
        }
    }

    /// Reopen the start gate only when the UI has cancelled termination after
    /// this explicit shutdown completed (for example, a later exit precondition
    /// changed). A call during an in-flight shutdown is intentionally ignored.
    func resumeAfterCancelledExplicitExit() {
        guard explicitExitCompleted else { return }
        explicitExitTask = nil
        explicitExitCompleted = false
        shuttingDown = false
    }

    private func stopBackendsForExplicitExitNow() async throws {
        // Let starts already admitted before the menu action finish so their
        // retained Process instances are included in the preflight set.
        let startDeadline = Date().addingTimeInterval(Self.startTimeout + 1)
        while !startingProfiles.isEmpty || localStartup != nil, Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard startingProfiles.isEmpty, localStartup == nil else {
            throw ManagerHostFailure.unavailable("仍有 Manager-owned Host 正在启动；未停止任何 backend。请等待启动状态确认后再重试退出。")
        }
        guard stopTasks.isEmpty else {
            throw ManagerHostFailure.unavailable("已有 Manager-owned Host 停止操作正在进行；未开始全局退出停止。请等待当前操作确认后再重试。")
        }

        let applicationPath = Bundle.main.bundleURL.path
        var targets: [(child: ManagerHostChild?, runtimePath: String, expectedPeerPID: Int32?)] = []
        let owned = children.values.sorted { ($0.profileID?.uuidString ?? "") < ($1.profileID?.uuidString ?? "") }
            + (localDaemon.map { [$0] } ?? [])
        var knownTargetSocketPaths = owned.map(\.socketPath)
        for child in owned {
            if !child.process.isRunning { child.recordExit(child.process.terminationStatus) }
            if child.hasExited {
                guard !(await Self.socketExistsOffMain(child.socketPath)) else {
                    throw ManagerHostFailure.unavailable("Manager-owned Host 子进程已退出，但原 socket 仍存在；为避免触碰替代进程，未停止任何 backend。")
                }
                forget(child)
                continue
            }
            guard await Self.socketExistsOffMain(child.socketPath) else {
                throw ManagerHostFailure.unavailable("Manager-owned Host 子进程仍运行，但原控制 socket 缺失；未停止任何 backend。")
            }
            targets.append((child, child.runtimePath, child.pid))
        }

        // This is the sole non-owned backend in the explicit full-exit scope:
        // the default local CLI runtime, never profile enumeration or DSH.
        let defaultRuntimePath = Self.localRuntime
        let defaultSocketPath = defaultRuntimePath + "/control.sock"
        knownTargetSocketPaths.append(defaultSocketPath)
        if localDaemon == nil, await Self.socketExistsOffMain(defaultSocketPath) {
            targets.append((nil, defaultRuntimePath, nil))
        }

        // Read every known target before issuing the first mutation. Retain
        // each authenticated endpoint identity and require the stop exchange to
        // reach precisely the same socket inode and peer process incarnation.
        var preflighted: [(child: ManagerHostChild?, runtimePath: String,
                           endpoint: ControlCLI.EndpointIdentity, ready: Bool)] = []
        for target in targets {
            let (reply, endpoint) = try await requestWithEndpointIdentity(
                .status, applicationPath: applicationPath, runtimePath: target.runtimePath,
                expectedPeerPID: target.expectedPeerPID)
            guard let ready = reply.readyToStop else {
                throw ManagerHostFailure.unavailable("Host 未提供可验证的停止就绪状态；未停止任何 backend。")
            }
            preflighted.append((target.child, target.runtimePath, endpoint, ready))
        }
        guard preflighted.allSatisfy(\.ready) else {
            throw ManagerHostFailure.sessionBusy("至少一个目标 Host 当前忙碌或状态未就绪；没有向任何 backend 发送停止请求。请完成交回/释放后再重试。")
        }

        for target in preflighted {
            _ = try await requestWithEndpointIdentity(
                .daemonStop, applicationPath: applicationPath, runtimePath: target.runtimePath,
                expectedPeerPID: target.child?.pid, expectedEndpointIdentity: target.endpoint)
            if let child = target.child {
                let exitStatus = await child.waitForExit(timeout: Self.childExitTimeout)
                guard exitStatus != nil else {
                    throw ManagerHostFailure.unavailable("Host 已接受停止请求，但 Manager 未确认原始子进程退出；没有重试或强制结束。")
                }
                guard await Self.waitForSocketAbsence(child.socketPath, timeout: Self.socketRemovalTimeout) else {
                    throw ManagerHostFailure.unavailable("原始 Host 子进程已退出，但其 socket 仍存在；为避免触碰替代进程，Manager 保持运行。")
                }
                forget(child)
            } else {
                guard await Self.waitForSocketAbsence(target.runtimePath + "/control.sock",
                                                      timeout: Self.socketRemovalTimeout) else {
                    throw ManagerHostFailure.unavailable("默认 CLI Host 已接受停止请求，但固定 runtime 的 socket 仍存在；没有重试或删除 socket。")
                }
            }
        }

        // Catch a late replacement/restart without adopting or stopping it.
        // Any new endpoint means the complete exit condition is unconfirmed.
        for child in Array(children.values) + (localDaemon.map { [$0] } ?? []) {
            if !child.process.isRunning { child.recordExit(child.process.terminationStatus) }
            guard child.hasExited else {
                throw ManagerHostFailure.unavailable("最终检查发现 Manager-owned Host 仍运行或原 socket 未消失；没有额外停止或强制结束任何进程。")
            }
            forget(child)
        }
        for socketPath in knownTargetSocketPaths {
            guard !(await Self.socketExistsOffMain(socketPath)) else {
                throw ManagerHostFailure.unavailable("最终检查发现原始退出目标的 socket 仍存在或被替换；没有重试停止或删除 socket。")
            }
        }
    }

    nonisolated static func arguments(for action: ManagerHostAction, applicationPath: String, profileID: UUID) -> [String] {
        let operation: [String]
        switch action {
        case .start: operation = ["daemon", "serve"]
        case .status: operation = ["status"]
        case .stop: operation = ["daemon", "stop"]
        case .authorize: operation = ["authorization-request"]
        case .authorizationStatus: operation = ["authorization-status"]
        }
        return ["control"] + operation + ["--app", applicationPath, "--runtime", RemoteHostRuntime.path(for: profileID)]
    }

    private func startOwnedChild(profileID: UUID, executablePath: String, applicationPath: String,
                                 runtimePath: String) async throws -> String {
        guard !shuttingDown else { throw ManagerHostFailure.unavailable("Manager 正在退出；请等待退出检查完成后再启动 Host。") }
        guard startingProfiles.insert(profileID).inserted else {
            throw ManagerHostFailure.unavailable("该环境的 Host 正在启动；请等待状态校验完成后重试。")
        }
        defer { startingProfiles.remove(profileID) }
        if let child = children[profileID] {
            if !child.process.isRunning { child.recordExit(child.process.terminationStatus) }
            if !child.hasExited {
                _ = try await status(profileID: profileID, applicationPath: applicationPath, runtimePath: runtimePath)
                return "Manager 已拥有该环境的 Host 子进程，且通过其私有 socket 的状态校验。此状态不验证 Apple Events 或浏览器控制权限。"
            }
            let state = try await Self.startupSocketState(runtimePath)
            guard let state else {
                throw ManagerHostFailure.unavailable("原 Manager Host 已退出，但该 runtime 的启动锁仍被占用；为避免接管或干扰替代进程，本次不重启。请稍后查询状态。")
            }
            switch state {
            case .absent, .stale(_): break
            case .active:
                throw ManagerHostFailure.unavailable("Manager 启动的 Host 子进程已退出，但原 socket 仍存在；为避免碰触替代进程，不会重启或接管。请确认 Host 状态后重试。")
            }
            children[profileID] = nil
        }

        guard let state = try await Self.startupSocketState(runtimePath) else {
            throw ManagerHostFailure.unavailable("该环境的 Host 正在启动或运行；Manager 不会接管现有 daemon。请查询状态后重试。")
        }
        if case .active = state {
            throw ManagerHostFailure.unavailable("该环境已有 Host daemon，但不是本 Manager 保留的子进程；不会接管或在退出时停止它。请使用显式「停止 Host」操作，或先确认该 daemon 的来源。")
        }
        let socketPath = runtimePath + "/control.sock"
        guard !shuttingDown else { throw ManagerHostFailure.unavailable("Manager 正在退出；请等待退出检查完成后再启动 Host。") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = Self.arguments(for: .start, applicationPath: applicationPath, profileID: profileID)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let child = ManagerHostChild(process: process, profileID: profileID, runtimePath: runtimePath)
        process.terminationHandler = { [weak child] process in
            let status = process.terminationStatus
            Task { @MainActor in child?.recordExit(status) }
        }
        do { try process.run() }
        catch { throw ManagerHostFailure.unavailable("无法启动 Safarier Host 子进程：\(error.localizedDescription)") }
        children[profileID] = child

        let deadline = Date().addingTimeInterval(Self.startTimeout)
        while Date() < deadline {
            if !process.isRunning { child.recordExit(process.terminationStatus) }
            guard !child.hasExited else {
                if !(await Self.socketExistsOffMain(socketPath)) { children[profileID] = nil }
                throw ManagerHostFailure.unavailable("Safarier Host 子进程在 socket 状态校验前退出（退出码 \(child.exitStatus ?? process.terminationStatus)）。")
            }
            if await Self.socketExistsOffMain(socketPath) {
                do {
                    _ = try await request(.status, applicationPath: applicationPath, runtimePath: runtimePath,
                                          expectedPeerPID: child.pid)
                    return "Host 已由 Manager 直接启动，并通过其私有 socket 与子进程身份校验。此状态不验证 Apple Events 或浏览器控制权限。"
                } catch {
                    // Status is read-only; retry briefly while the newly-started
                    // server finishes accepting its private socket.
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ManagerHostFailure.unavailable("等待 GUI-owned Host 的私有 socket/PID 状态校验超时；进程仍由 Manager 跟踪，未强制结束。请查询状态或重试停止。")
    }

    private func status(profileID: UUID, applicationPath: String, runtimePath: String) async throws -> String {
        let socketPath = runtimePath + "/control.sock"
        guard await Self.socketExistsOffMain(socketPath) else { return "该环境的 Host daemon 当前未运行。" }
        let reply = try await request(.status, applicationPath: applicationPath, runtimePath: runtimePath,
                                      expectedPeerPID: children[profileID]?.pid)
        guard reply.status == "ok" else { throw Self.failure(for: reply.error) }
        return "该环境的 Host daemon 正在运行。状态检查不验证 Apple Events 或浏览器控制权限。"
    }

    private func stop(profileID: UUID, applicationPath: String, runtimePath: String) async throws -> String {
        if let child = children[profileID] {
            try await stopOwnedChild(child, applicationPath: applicationPath)
            return "该环境由 Manager 启动的 Host 子进程已退出，且其私有控制 socket 已消失。"
        }
        let socketPath = runtimePath + "/control.sock"
        guard await Self.socketExistsOffMain(socketPath) else { return "该环境的 Host daemon 当前未运行。" }
        _ = try await request(.daemonStop, applicationPath: applicationPath, runtimePath: runtimePath, expectedPeerPID: nil)
        guard await Self.waitForSocketAbsence(socketPath, timeout: Self.socketRemovalTimeout) else {
            throw ManagerHostFailure.unavailable("停止命令已被接受，但固定 runtime 的控制 socket 仍存在；没有确认停止，也未强制结束任何进程。请查询状态后再试。")
        }
        return "该环境的 Host daemon 已停止。"
    }

    private func stopOwnedChild(_ child: ManagerHostChild, applicationPath: String) async throws {
        guard let profileID = child.profileID else {
            return try await stopOwnedChildNow(child, applicationPath: applicationPath)
        }
        if let existing = stopTasks[profileID] {
            try await existing.task.value
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [self] in try await stopOwnedChildNow(child, applicationPath: applicationPath) }
        stopTasks[profileID] = (taskID, task)
        defer { if stopTasks[profileID]?.id == taskID { stopTasks[profileID] = nil } }
        try await task.value
    }

    private func stopOwnedChildNow(_ child: ManagerHostChild, applicationPath: String) async throws {
        if !child.process.isRunning { child.recordExit(child.process.terminationStatus) }
        if child.hasExited {
            guard !(await Self.socketExistsOffMain(child.socketPath)) else {
                throw ManagerHostFailure.unavailable("Manager 启动的 Host 子进程已退出，但 socket 仍存在；为避免停止同 runtime 的替代进程，Manager 保持运行。请检查状态并确认 socket 所属者。")
            }
            forget(child)
            return
        }

        do {
            _ = try await request(.daemonStop, applicationPath: applicationPath, runtimePath: child.runtimePath,
                                  expectedPeerPID: child.pid)
        } catch {
            if let hostFailure = error as? ManagerHostFailure, hostFailure.isSessionBusy { throw error }
            let observedExit = await child.waitForExit(timeout: Self.childExitTimeout)
            let socketAbsent = await Self.waitForSocketAbsence(child.socketPath, timeout: Self.socketRemovalTimeout)
            if observedExit != nil && socketAbsent {
                forget(child)
                return
            }
            throw ManagerHostFailure.unavailable("原始子进程退出或 socket 消失均未得到完整确认。Manager 保持运行，没有重试控制请求或强制结束进程。原始错误：\(error.localizedDescription) 请查询该 profile 的 Host 状态后再试。")
        }
        let exitStatus = await child.waitForExit(timeout: Self.childExitTimeout)
        guard exitStatus != nil else {
            throw ManagerHostFailure.unavailable("Host 已接受停止请求，但 Manager 尚未确认其原始子进程退出；没有发送 kill。Manager 保持运行，请查询状态后重试。")
        }
        guard await Self.waitForSocketAbsence(child.socketPath, timeout: Self.socketRemovalTimeout) else {
            throw ManagerHostFailure.unavailable("原始 Host 子进程已退出，但 runtime socket 仍存在；可能有另一个进程接管。Manager 不会停止该进程，并保持运行。请确认 socket 所属者。")
        }
        forget(child)
    }

    private func request(_ operation: ControlOperation, applicationPath: String, runtimePath: String,
                         expectedPeerPID: Int32?) async throws -> ControlBrokerReply {
        let result = try await requestWithEndpointIdentity(operation, applicationPath: applicationPath,
                                                           runtimePath: runtimePath, expectedPeerPID: expectedPeerPID)
        return result.reply
    }

    private func requestWithEndpointIdentity(_ operation: ControlOperation, applicationPath: String,
                                             runtimePath: String, expectedPeerPID: Int32?,
                                             expectedEndpointIdentity: ControlCLI.EndpointIdentity? = nil,
                                             timeout: TimeInterval? = nil)
    async throws -> (reply: ControlBrokerReply, endpointIdentity: ControlCLI.EndpointIdentity) {
        let request = ControlRequest(requestID: UUID(), operation: operation)
        let (data, endpointIdentity) = try await Self.exchangeWithTimeout(
            request, applicationPath: applicationPath, runtimePath: runtimePath,
            expectedPeerPID: expectedPeerPID, expectedEndpointIdentity: expectedEndpointIdentity,
            timeout: timeout ?? Self.exchangeTimeout)
        let reply = try ControlCLI.decodeReply(data, requestID: request.requestID)
        guard reply.status == "ok" else { throw Self.failure(for: reply.error) }
        return (reply, endpointIdentity)
    }

    nonisolated private static func exchangeWithTimeout(_ request: ControlRequest, applicationPath: String,
                                                         runtimePath: String, expectedPeerPID: Int32?,
                                                         expectedEndpointIdentity: ControlCLI.EndpointIdentity? = nil,
                                                         timeout: TimeInterval) async throws -> (Data, ControlCLI.EndpointIdentity) {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ManagerHostExchangeGate(continuation)
            Task.detached(priority: .userInitiated) {
                do { gate.finish(.success(try ControlCLI.exchangeWithEndpointIdentity(
                    request, applicationPath: applicationPath, runtimePath: runtimePath,
                    expectedPeerPID: expectedPeerPID, expectedEndpointIdentity: expectedEndpointIdentity))) }
                catch { gate.finish(.failure(error)) }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(timeout))
                gate.finish(.failure(ManagerHostFailure.unavailable("Host 控制 socket 请求超时；停止是否完成无法确认，Manager 保持运行且不会强制结束进程。请查询状态后重试。")))
            }
        }
    }

    nonisolated private static func socketExistsOffMain(_ path: String) async -> Bool {
        await Task.detached(priority: .utility) { socketExists(path) }.value
    }

    /// Start decisions share ControlRuntime's lock and fail closed on stale
    /// sockets not proven by a prior lock-owning daemon. This runs off the UI
    /// actor because the bounded lock wait may last briefly during stop/start.
    nonisolated private static func startupSocketState(_ runtimePath: String) async throws -> ControlRuntime.StartupSocketState? {
        do {
            return try await Task.detached(priority: .utility) {
                let runtime = try ControlRuntime(path: runtimePath, create: true)
                guard let lock = try runtime.acquireStartupLock(waitSeconds: 2) else { return nil }
                defer { lock.release() }
                return try runtime.startupSocketState(lockedBy: lock)
            }.value
        } catch {
            throw ManagerHostFailure.unavailable("runtime socket 无法通过目录、inode 与持久 owner pin 验证；Manager 不会删除或接管该路径。请确认 Host 状态后重试。")
        }
    }

    nonisolated private static func waitForSocketAbsence(_ path: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !(await socketExistsOffMain(path)) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !(await socketExistsOffMain(path))
    }

    nonisolated private static func socketExists(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        return true // Never treat an unexpected filesystem error as "stopped".
    }

    private static func failure(for code: String?) -> ManagerHostFailure {
        if code == "SESSION_BUSY" {
            return .sessionBusy("Host 当前有活动或尚未交回的控制连接；Manager 保持运行且没有停止 Host。请先完成交回/释放连接，再重试停止或退出。")
        }
        if code == "UNAVAILABLE" || code == "INDETERMINATE_RESULT" {
            return .unavailable("Host 停止结果未确认；Manager 保持运行且没有强制结束进程。请查询该 profile 的 Host 状态后重试。")
        }
        return .commandFailed("Safarier Host 命令未完成（\(code ?? "UNKNOWN")）。Manager 保持运行；请确认 Host 状态后重试。")
    }
}

@MainActor
private final class ManagerHostChild {
    let process: Process
    let profileID: UUID?
    let runtimePath: String
    var pid: Int32 { process.processIdentifier }
    private(set) var exitStatus: Int32?
    private var exitWaiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]

    init(process: Process, profileID: UUID?, runtimePath: String) {
        self.process = process
        self.profileID = profileID
        self.runtimePath = runtimePath
    }

    var socketPath: String { runtimePath + "/control.sock" }
    var hasExited: Bool { exitStatus != nil }

    func recordExit(_ status: Int32) {
        guard exitStatus == nil else { return }
        exitStatus = status
        let waiters = Array(exitWaiters.values)
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func waitForExit(timeout: TimeInterval) async -> Int32? {
        if let exitStatus { return exitStatus }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            if let exitStatus {
                continuation.resume(returning: exitStatus)
                return
            }
            exitWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let waiter = self.exitWaiters.removeValue(forKey: id) else { return }
                waiter.resume(returning: nil)
            }
        }
    }
}

private final class ManagerHostExchangeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, ControlCLI.EndpointIdentity), Error>?

    init(_ continuation: CheckedContinuation<(Data, ControlCLI.EndpointIdentity), Error>) { self.continuation = continuation }

    func finish(_ result: Result<(Data, ControlCLI.EndpointIdentity), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum ManagerHostFailure: LocalizedError {
    case unavailable(String)
    case commandFailed(String)
    case sessionBusy(String)

    var isSessionBusy: Bool {
        if case .sessionBusy = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .commandFailed(let message), .sessionBusy(let message): return message
        }
    }
}
