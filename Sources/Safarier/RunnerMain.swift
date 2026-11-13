import AppKit
import CoreFoundation
import WebKit
import SafarierCore
import Darwin
import SafarierNetwork
import SafarierWebKit

#if SAFARIER_BOUND_LOCAL_CANDIDATE
private func runnerTrace(_ phase: String, _ start: UInt64, _ result: String = "ok") {
    let now = DispatchTime.now().uptimeNanoseconds
    let ms = now >= start ? (now - start) / 1_000_000 : 0
    fputs("BOUND_DIAG phase=\(phase) elapsed_ms=\(ms) result=\(result)\n", stderr)
}
private func runnerError(_ error: Error) -> String {
    if let error = error as? AutomationError { return error.code.rawValue }
    if error is CancellationError { return "cancelled" }
    if let error = error as? RunnerPreparationError {
        switch error {
        case .profileMismatch: return "profileMismatch"
        case .invalidBackgroundLaunch: return "invalidBackgroundLaunch"
        case .boundNodeMismatch: return "boundNodeMismatch"
        case .proxyNotFound: return "proxyNotFound"
        case .proxyMismatch: return "proxyMismatch"
        }
    }
    return "unknown"
}
#endif

/// Runner 进程入口：一个进程只服务一个 profile。
@MainActor
enum RunnerMain {
    /// 进程存活期间一直持有，退出（含崩溃）时内核自动释放。
    private static var lock: ProfileLock?
    private static var controller: AnyObject?
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    final class RetainedBrowserOwner {
        let session: BrowserSession
        let window: NSWindow
        let webView: BrowserWebView
        let resources: RunnerPreparation.OwnedResources
        fileprivate init(session: BrowserSession, window: NSWindow, webView: BrowserWebView, resources: RunnerPreparation.OwnedResources) {
            self.session = session; self.window = window; self.webView = webView; self.resources = resources
        }
    }
    private static var retainedBrowserOwner: RetainedBrowserOwner?
    static func prepareRetainedBrowser(resources: RunnerPreparation.OwnedResources, receipt: ControlReleaseReceipt) -> RetainedBrowserOwner? {
        guard retainedBrowserOwner == nil, let session = controller as? BrowserSession,
              session.profile.id == receipt.target.profileID, session.executionPolicy == .interactive,
              session.openControllers.count == 1, let browser = session.openControllers.first,
              browser.session === session, browser.webView.window === browser.window,
              receipt.inputReleased, receipt.artifactsCleaned, receipt.browserRetained,
              receipt.manualInteractionEnabled, NSApp.isRunning else { return nil }
        return RetainedBrowserOwner(session: session, window: browser.window, webView: browser.webView, resources: resources)
    }
    static func retainReleasedBrowser(_ owner: RetainedBrowserOwner) {
        retainedBrowserOwner = owner
    }
    #endif
    private static var signalSources: [DispatchSourceSignal] = []
    /// 绑定订阅节点时由这个 Runner 拉起的代理内核（sing-box 或 mihomo）。atexit 和信号处理里要用，所以不隔离到主线程。
    nonisolated(unsafe) private static var singbox: (manager: SingboxProcessManager, profileID: UUID)?

    static func start(arguments: [String]) -> Never {
        // Manager 把 stdout 重定向到日志文件；改成行缓冲，否则进程被结束时最后的输出会丢。
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let spec = try RunnerLaunchSpec.parse(arguments, environment: ProcessInfo.processInfo.environment)
            let workspace = try SafarierWorkspace.default()
            guard let profile = try workspace.profiles.record(id: spec.profileID) else {
                fail("找不到 profile \(spec.profileID.uuidString)")
            }
            let originalLock: ProfileLock
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            if spec.backgroundAutomation || spec.registeredInteractive {
                if spec.registeredInteractive {
                    try AutomationChannel.validateConnectedStream(fileDescriptor: STDIN_FILENO)
                }
                // Only the safely inspected original lock can be loaned to Core.
                originalLock = try ProfileLock.acquireForBoundCandidate(profileID: profile.id, in: workspace.locksDirectory)
            } else {
                originalLock = try ProfileLock.acquire(profileID: profile.id, in: workspace.locksDirectory)
            }
            #else
            originalLock = try ProfileLock.acquire(profileID: profile.id, in: workspace.locksDirectory)
            #endif
            lock = originalLock
            if spec.backgroundAutomation {
                guard spec.startURL == URL(string: "about:blank"), spec.spiOverride == nil, !spec.probe else {
                    fail("后台自动化未授权或参数不合规")
                }
                let rawInput = FileHandle(fileDescriptor: STDIN_FILENO, closeOnDealloc: false)
                try AutomationChannel.validateConnectedStream(fileDescriptor: rawInput.fileDescriptor)
                let app = NSApplication.shared
                guard app.setActivationPolicy(.prohibited), !app.isActive else {
                    fail("后台自动化应用策略不可用")
                }
                Task { @MainActor in
                    let status = await RunnerAutomationEntry.serve(profile: profile, spec: spec, workspace: workspace, arguments: arguments, rawInput: rawInput, originalLock: originalLock)
                    #if SAFARIER_BOUND_LOCAL_CANDIDATE
                    if let owner = retainedBrowserOwner {
                        fputs("CONTROL_RELEASE_DIAG phase=serve_return status=\(status) retainedOwner=true\n", stderr)
                        owner.session.confirmRetainedControlFinished()
                        return
                    }
                    #endif
                    exit(status)
                }
                app.run()
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                if retainedBrowserOwner != nil { exit(0) }
                #endif
                fail("后台自动化主运行循环意外返回")
            }
            installTerminationCleanup()
            let prepared = try RunnerPreparation.prepare(profile: profile, spec: spec, workspace: workspace, arguments: arguments, executionPolicy: .interactive)
            let effectiveProfile = prepared.effectiveProfile
            let output = prepared.output
            let diagnostics = prepared.diagnostics

            let app = NSApplication.shared
            if spec.probe {
                app.setActivationPolicy(.prohibited)
                let probe = ProbeController(
                    profile: effectiveProfile,
                    spec: spec,
                    output: output,
                    adapter: prepared.adapter,
                    spiFeatures: prepared.spiFeatures,
                    diagnostics: diagnostics,
                    outbound: prepared.outbound
                )
                controller = probe
                probe.start()
            } else {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                app.setActivationPolicy(spec.nonActivatingPresentation ? .accessory : .regular)
                #else
                app.setActivationPolicy(.regular)
                #endif
                app.mainMenu = BrowserMenu.make()
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                let session = BrowserSession(profile: effectiveProfile, output: output, outboundDescription: prepared.outboundDescription, diagnostics: diagnostics, promoteOnActivation: spec.nonActivatingPresentation, workspace: workspace)
                #else
                let session = BrowserSession(profile: effectiveProfile, output: output, outboundDescription: prepared.outboundDescription, diagnostics: diagnostics, workspace: workspace)
                #endif
                controller = session
                app.delegate = session
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                if spec.registeredInteractive {
                    session.startRegisteredInteractive(url: spec.startURL)
                    let root = try AutomationChannel(adopting: FileHandle(fileDescriptor: STDIN_FILENO, closeOnDealloc: false))
                    let instance = UUID()
                    Task { @MainActor in
                        let ok = await RegisteredRunnerServer.serve(channel: root, profileID: profile.id,
                            runnerInstanceID: instance, originalLock: originalLock, workspace: workspace) { epoch, channel in
                            await serveRegisteredGeneration(epoch: epoch, channel: channel, profile: profile,
                                spec: spec, workspace: workspace, arguments: arguments, originalLock: originalLock,
                                runnerInstanceID: instance, session: session, launchPlan: prepared.launchPlan)
                        }
                        if !ok { fputs("REGISTERED_DIAG phase=root_closed result=unconfirmed\n", stderr) }
                    }
                } else {
                    session.start(url: spec.startURL)
                }
                #else
                session.start(url: spec.startURL)
                #endif
            }
            app.run()
            exit(0)
        } catch {
            fail("Runner 启动失败：\(error)")
        }
    }

    /// Defend this composition boundary even when called independently of the entry.
    static func makeAutomationService(prepared: RunnerPreparation.Result, workspace: SafarierWorkspace) throws -> RunnerAutomationService {
        try NativePageInput.requireShippingAdmission()
        guard prepared.output.executionPolicy == .automationBackground else {
            throw AutomationError(code: .backgroundLaunchUnverified)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let session = BrowserSession(profile: prepared.effectiveProfile, output: prepared.output, outboundDescription: prepared.outboundDescription, diagnostics: prepared.diagnostics, workspace: workspace)
        controller = session
        app.delegate = session
        return try session.makeAutomationService(workspace: workspace, runnerInstanceID: UUID())
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private static func serveRegisteredGeneration(epoch: UUID, channel: AutomationChannel, profile: Profile,
        spec: RunnerLaunchSpec, workspace: SafarierWorkspace, arguments: [String], originalLock: ProfileLock,
        runnerInstanceID: UUID, session: BrowserSession, launchPlan: RunnerPreparationPlan) async -> Bool {
        enum Stage: String { case installContext, slotInstall, serveAppBound, closeSlot, drain, finish }
        var stage = Stage.installContext
        let slot = BoundRunnerServiceSlot(registeredSession: session, registeredLaunchPlan: launchPlan)
        let server = AutomationRunnerServer(profileID: profile.id, runnerInstanceID: runnerInstanceID,
            channel: channel, handler: { request in await slot.handle(request) },
            shutdown: { Task { @MainActor in slot.beginClosing() } })
        do {
            stage = .installContext
            let context = try await server.installAppContext(workspace: workspace, spec: spec,
                originalLock: originalLock, arguments: arguments,
                environment: ProcessInfo.processInfo.environment, registrationEpoch: epoch)
            stage = .slotInstall
            try slot.install(context)
            stage = .serveAppBound
            let status = await server.serveAppBound { bound in
                try await slot.prepare(context: bound, profile: profile, spec: spec, workspace: workspace)
            }
            stage = .closeSlot
            slot.beginClosing()
            stage = .drain
            guard await slot.drain() else { context.beginClosing(); return false }
            stage = .finish
            await context.finishAfterResourcesDrained()
            return status == 0
        } catch {
            RootIdentityDiagnostic.emit("REGISTERED_GENERATION_DIAG side=runner stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            slot.beginClosing()
            _ = await slot.drain()
            return false
        }
    }

    static func makeBoundAutomationService(prepared: RunnerPreparation.Result, workspace: SafarierWorkspace, context: RunnerBinderContext) async throws -> RunnerAutomationService {
        let started = DispatchTime.now().uptimeNanoseconds
        var phase = "service.validate.before"
        do {
            runnerTrace(phase, started)
            try await context.validate()
            guard prepared.output.executionPolicy == .automationBackground,
                  prepared.effectiveProfile.id == context.profileID else { throw AutomationError(code: .targetChanged) }
            try context.checkLive()
            phase = "service.application.before"; runnerTrace(phase, started)
            let app = NSApplication.shared
            phase = "service.application.after"; runnerTrace(phase, started)
            app.setActivationPolicy(.prohibited)
            let session = BrowserSession(profile: prepared.effectiveProfile, output: prepared.output,
                outboundDescription: prepared.outboundDescription, diagnostics: prepared.diagnostics, workspace: workspace)
            controller = session
            app.delegate = session
            phase = "service.final_validate.before"; runnerTrace(phase, started)
            try await context.validate()
            phase = "service.create.before"; runnerTrace(phase, started)
            let service = try session.makeBoundAutomationService(workspace: workspace, context: context)
            runnerTrace("service.create.after", started)
            return service
        } catch { runnerTrace(phase, started, runnerError(error)); throw error }
    }
    #endif

    /// 跟随代理：重新启动过的 Runner 直接用带过来的结果；否则经代理探测出口国家（失败时按节点名推断）。
    static func resolveFollowProxy(proxy: ProxySettings?, nodeHint: String?) -> ProxyGeoResult? {
        let environment = ProcessInfo.processInfo.environment
        if let carried = ProxyGeoResult(relaunchedFrom: environment) { return carried }
        let password = proxy.flatMap { proxy -> String? in
            guard proxy.username?.isEmpty == false else { return nil }
            return try? KeychainCredentialStore().password(forKey: proxy.credentialKey)
        }
        let resolved = ProxyGeoResolver.resolve(proxy: proxy, password: password, nodeHint: nodeHint)
        if let resolved {
            FileHandle.standardError.write(Data("[geo] 出口 \(resolved.countryCode)：语言 \(resolved.languages)，时区 \(resolved.timeZoneIdentifier)（\(resolved.source)）\n".utf8))
        }
        return resolved
    }

    /// 带上新的 `-AppleLanguages`（和跟随代理的 TZ）重新执行自己：先停 sing-box、释放 profile 锁，
    /// 进程号不变，管理器的进程跟踪不受影响。重新启动后的进程从头开始，再起 sing-box、再拿锁。
    static func relaunch(arguments: [String], resolved: ProxyGeoResult, followTimeZone: Bool) -> Never {
        stopSingbox()
        lock?.release()
        lock = nil
        for (key, value) in resolved.relaunchEnvironment { setenv(key, value, 1) }
        if followTimeZone { setenv("TZ", resolved.timeZoneIdentifier, 1) }
        let executable = RunnerLauncher.currentExecutableURL().path
        let argv = [executable] + RunnerLaunchSpec.replacingAppleLanguages(resolved.languages, in: arguments)
        FileHandle.standardError.write(Data("[geo] 带上 -AppleLanguages \(resolved.languages) 重新启动 Runner\n".utf8))
        var cArguments = argv.map { strdup($0) } + [nil]
        execv(executable, &cArguments)
        fail("重新启动 Runner 失败（errno \(errno)）")
    }

    /// 起节点对应的代理内核（sing-box 或 mihomo）并等它的本地端口可用。stdout/stderr 进 Runner 自己的日志（不记访问的域名）。
    static func startProxyCore(
        profileID: UUID,
        node: SubscriptionNode,
        workspace: SafarierWorkspace
    ) throws -> (proxy: ProxySettings, pid: Int32) {
        let engine = node.proxyEngine
        let manager = SingboxProcessManager(engine: engine, stateDirectory: workspace.singboxDirectory, logHandle: FileHandle.standardError)
        singbox = (manager, profileID)
        let pid = try manager.start(profileID: profileID, node: node)
        let port = try manager.waitUntilReady(profileID: profileID)
        // 写 stderr：探针模式下 stdout 只能有 JSON。
        FileHandle.standardError.write(Data("[\(engine.displayName)] \(manager.executableURL.path) pid \(pid)，节点「\(node.name)」（\(node.type.rawValue) \(node.server):\(node.serverPort)）→ 127.0.0.1:\(port)\n".utf8))
        let proxy = ProxySettings(name: engine.displayName, kind: .socks5, host: SingboxConfigBuilder.defaultInboundAddress, port: port)
        return (proxy, pid)
    }

    /// 结束本 Runner 拉起的 sing-box。会被调用多次（applicationWillTerminate、atexit、信号），只有第一次生效。
    nonisolated static func stopSingbox() {
        guard let (manager, profileID) = singbox else { return }
        singbox = nil
        try? manager.stop(profileID: profileID)
    }

    /// 所有退出路径都要带走 sing-box：exit()（含 NSApp.terminate 和 fail）走 atexit，
    /// SIGTERM/SIGINT/SIGHUP 先清理再按原信号退出（管理器据此区分"被结束"和"出错"）。
    /// SIGKILL 和崩溃拦不住，留下的进程由下次启动或图形管理器按 pid 文件清理。
    private static func installTerminationCleanup() {
        atexit { RunnerMain.stopSingbox() }
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                if let session = controller as? BrowserSession {
                    session.saveSessionState()
                }
                RunnerMain.stopSingbox()
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
