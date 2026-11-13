import Foundation
import Darwin
import SafarierCore
import SafarierNetwork
import SafarierWebKit

#if SAFARIER_BOUND_LOCAL_CANDIDATE
private func prepTrace(_ phase: String, _ start: UInt64, _ result: String = "ok") {
    let now = DispatchTime.now().uptimeNanoseconds
    let ms = now >= start ? (now - start) / 1_000_000 : 0
    fputs("BOUND_DIAG phase=\(phase) elapsed_ms=\(ms) result=\(result)\n", stderr)
}
private func prepError(_ error: Error) -> String {
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

@MainActor
enum RunnerPreparation {
    struct Result {
        let launchPlan: RunnerPreparationPlan
        let effectiveProfile: Profile
        let output: WebViewConfigurationFactory.Output
        let spiFeatures: SPIFeatures
        let diagnostics: SPIDiagnostics
        let outbound: [String: Any]
        let outboundDescription: String
        let adapter: String
    }

    static func prepare(profile: Profile, spec: RunnerLaunchSpec, workspace: SafarierWorkspace, arguments: [String], executionPolicy: BrowserExecutionPolicy) throws -> Result {
        try WebViewConfigurationFactory.requireExecutionPolicy(executionPolicy)
        guard executionPolicy != .automationBackground, !spec.backgroundAutomation else {
            throw RunnerPreparationError.invalidBackgroundLaunch
        }
        let plan = try RunnerPreparationPlan.resolve(profile: profile, spec: spec, proxyReader: { try workspace.proxies.record(id: $0) }, boundNodeReader: { try workspace.boundNode(for: $0) })
        let diagnostics = SPIDiagnostics.standardError()

        let displayState = installDisplay(profile: profile, diagnostics: diagnostics)

        // 出站：独立代理直接交给 WebKit；订阅节点先起代理内核（sing-box 或 mihomo），把它的本地 SOCKS5 入站当成代理交给 WebKit。
        // 后者在工厂看来就是"绑定了一个代理"，所以内核断了时页面加载失败，不会退回直连。
        var effectiveProfile = profile
        var proxy = plan.proxy
        var outbound: [String: Any] = proxy.map { ["kind": "proxy", "name": $0.name] } ?? ["kind": "direct"]
        var outboundDescription = proxy.map { "代理「\($0.name)」（\($0.kind.rawValue) \($0.host):\($0.port)）" } ?? "直连"

        let bound = plan.boundNode
        if let bound {
            let engine = bound.node.proxyEngine
            let local = try RunnerMain.startProxyCore(profileID: profile.id, node: bound.node, workspace: workspace)
            effectiveProfile.proxyID = local.proxy.id
            proxy = local.proxy
            outbound = [
                "kind": "subscriptionNode",
                "subscription": bound.subscription.name,
                "node": bound.node.name,
                "protocol": bound.node.type.rawValue,
                "engine": engine.rawValue,
                "proxyCorePID": local.pid,
                "localProxy": "\(local.proxy.host):\(local.proxy.port)",
            ]
            outboundDescription = "订阅「\(bound.subscription.name)」节点「\(bound.node.name)」（经 \(engine.displayName)）"
        }

        return try finish(plan: plan, profile: profile, spec: spec, arguments: arguments, executionPolicy: executionPolicy,
                          effectiveProfile: effectiveProfile, proxy: proxy, bound: bound,
                          outbound: outbound, outboundDescription: outboundDescription, diagnostics: diagnostics, displayState: displayState)
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    static func prepareBoundLocal(profile: Profile, spec: RunnerLaunchSpec, workspace: SafarierWorkspace, context: RunnerBinderContext) async throws -> BackgroundResult {
        let started = DispatchTime.now().uptimeNanoseconds
        var phase = "prepare.validate.before"
        var resources = OwnedResources()
        do {
            try await context.validate(profile: profile)
            guard spec.backgroundAutomation, spec.profileID == context.profileID,
                  spec.startURL == URL(string: "about:blank"), !spec.probe,
                  spec.spiOverride == nil else { throw RunnerPreparationError.invalidBackgroundLaunch }
            let plan = try RunnerPreparationPlan.resolve(profile: profile, spec: spec,
                proxyReader: { try workspace.proxies.record(id: $0) }, boundNodeReader: { try workspace.boundNode(for: $0) })
            try await context.validate(preparation: plan)
            let diagnostics = SPIDiagnostics.standardError()
            let displayState = installDisplay(profile: profile, diagnostics: diagnostics)
            let outbound = try await prepareOwnedOutbound(plan: plan, workspace: workspace)
            resources = outbound.resources
            try Task.checkCancellation()
            try await context.validate(preparation: plan)
            let privacy = CompositePrivacyAdapter([PublicAPIPrivacyAdapter(), SPIPrivacyAdapter(features: profile.spi, diagnostics: diagnostics)])
            let factory = WebViewConfigurationFactory(credentials: KeychainCredentialStore(), privacy: privacy)
            phase = "prepare.factory.before"; prepTrace(phase, started)
            var output = try await factory.makeBoundLocal(plan: plan, effectiveProfile: outbound.profile, proxy: outbound.proxy, context: context)
            if let displayState { output.report.set(displayState, for: .displayCapabilities) }
            try await context.validate(preparation: plan)
            try Task.checkCancellation()
            phase = "prepare.factory.after"; prepTrace(phase, started)
            return BackgroundResult(prepared: Result(launchPlan: plan, effectiveProfile: outbound.profile, output: output,
                spiFeatures: profile.spi, diagnostics: diagnostics, outbound: outbound.details,
                outboundDescription: outbound.description, adapter: factory.privacy.identifier), resources: resources)
        } catch {
            prepTrace(phase, started, prepError(error))
            guard await resources.close() else { throw BackgroundError.ownedCleanupUnobserved }
            throw error
        }
    }
    #endif

    enum BackgroundError: Error { case ownedCleanupUnobserved }

    struct BackgroundResult {
        let prepared: Result
        let resources: OwnedResources
    }

    @MainActor
    final class OwnedResources {
        private let manager: SingboxProcessManager?
        private let identity: SingboxProcessManager.OwnedIdentity?
        private var closeTask: Task<Bool, Never>?
        private var closeResult: Bool?

        init(manager: SingboxProcessManager? = nil, identity: SingboxProcessManager.OwnedIdentity? = nil) {
            self.manager = manager
            self.identity = identity
        }

        func close() async -> Bool {
            if let closeResult { return closeResult }
            if let closeTask { return await closeTask.value }
            guard let manager, let identity else {
                let result = manager == nil && identity == nil
                closeResult = result
                return result
            }
            let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(2_000_000_000)
            guard !overflow else { closeResult = false; return false }
            do { try manager.requestStopOwned(identity) }
            catch { closeResult = false; return false }
            let task = Task.detached { () -> Bool in
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let remaining = Double(deadline - now) / 1_000_000_000
                do {
                    let exit = try await manager.stopOwned(identity, timeoutSeconds: remaining)
                    return exit != nil && DispatchTime.now().uptimeNanoseconds <= deadline
                } catch { return false }
            }
            closeTask = task
            return await task.value
        }
    }

    private struct OwnedOutbound {
        let profile: Profile
        let proxy: ProxySettings?
        let details: [String: Any]
        let description: String
        let resources: OwnedResources
    }

    /// Shared controlled preparation; retains the exact owned subscription bridge.
    private static func prepareOwnedOutbound(plan: RunnerPreparationPlan, workspace: SafarierWorkspace) async throws -> OwnedOutbound {
        var effective = plan.profile
        var proxy = plan.proxy
        var details: [String: Any] = proxy.map { ["kind": "proxy", "name": $0.name] } ?? ["kind": "direct"]
        var description = proxy.map { "代理「\($0.name)」（\($0.kind.rawValue) \($0.host):\($0.port)）" } ?? "直连"
        var resources = OwnedResources()
        if let bound = plan.boundNode {
            let engine = bound.node.proxyEngine
            let manager = SingboxProcessManager(engine: engine, stateDirectory: workspace.singboxDirectory, logHandle: FileHandle.standardError)
            let identity: SingboxProcessManager.OwnedIdentity
            do { identity = try await manager.startOwned(profileID: plan.profile.id, node: bound.node, timeoutSeconds: 10) }
            catch {
                await Task.detached { await manager.stopAllOwned(timeoutSeconds: 2) }.value
                guard manager.pendingOwnedCount == 0 else { throw BackgroundError.ownedCleanupUnobserved }
                throw error
            }
            resources = OwnedResources(manager: manager, identity: identity)
            effective.proxyID = identity.proxy.id; proxy = identity.proxy
            details = ["kind": "subscriptionNode", "subscription": bound.subscription.name,
                       "node": bound.node.name, "protocol": bound.node.type.rawValue,
                       "engine": engine.rawValue, "proxyCorePID": identity.pid,
                       "localProxy": "\(identity.proxy.host):\(identity.proxy.port)"]
            description = "订阅「\(bound.subscription.name)」节点「\(bound.node.name)」（经 \(engine.displayName)）"
        }
        return OwnedOutbound(profile: effective, proxy: proxy, details: details, description: description, resources: resources)
    }

    static func prepareBackground(profile: Profile, spec: RunnerLaunchSpec, workspace: SafarierWorkspace, arguments: [String]) async throws -> BackgroundResult {
        try WebViewConfigurationFactory.requireExecutionPolicy(.automationBackground)
        try Task.checkCancellation()
        try NativePageInput.requireShippingAdmission()
        guard spec.backgroundAutomation else { throw RunnerPreparationError.invalidBackgroundLaunch }
        let plan = try RunnerPreparationPlan.resolve(profile: profile, spec: spec, proxyReader: { try workspace.proxies.record(id: $0) }, boundNodeReader: { try workspace.boundNode(for: $0) })
        try Task.checkCancellation()
        let diagnostics = SPIDiagnostics.standardError()
        let displayState = installDisplay(profile: profile, diagnostics: diagnostics)
        let outbound = try await prepareOwnedOutbound(plan: plan, workspace: workspace)
        let resources = outbound.resources
        do {
            try Task.checkCancellation()
            let prepared = try finish(plan: plan, profile: profile, spec: spec, arguments: arguments, executionPolicy: .automationBackground,
                                      effectiveProfile: outbound.profile, proxy: outbound.proxy, bound: plan.boundNode,
                                      outbound: outbound.details, outboundDescription: outbound.description, diagnostics: diagnostics, displayState: displayState)
            try Task.checkCancellation()
            return BackgroundResult(prepared: prepared, resources: resources)
        } catch {
            guard await resources.close() else { throw BackgroundError.ownedCleanupUnobserved }
            throw error
        }
    }

    private static func installDisplay(profile: Profile, diagnostics: SPIDiagnostics) -> CapabilityState? {
        profile.deviceModel.flatMap(MacDeviceModel.preset)
            .map { DeviceSimulation.installDisplayOverride(for: $0, diagnostics: diagnostics) }
    }

    private static func finish(plan: RunnerPreparationPlan, profile: Profile, spec: RunnerLaunchSpec, arguments: [String], executionPolicy: BrowserExecutionPolicy,
                               effectiveProfile initialProfile: Profile, proxy: ProxySettings?,
                               bound: (subscription: Subscription, node: SubscriptionNode)?,
                               outbound initialOutbound: [String: Any], outboundDescription: String,
                               diagnostics: SPIDiagnostics, displayState: CapabilityState?) throws -> Result {
        if executionPolicy == .automationBackground {
            guard !profile.followProxyLanguages, !profile.followProxyTimeZone else {
                throw AutomationError(code: .backendUnavailable)
            }
        }
        var effectiveProfile = initialProfile
        var outbound = initialOutbound
        // 原生引擎接口只在 profile（或本次 --spi）显式开启时才碰；公开适配器先写结论，SPI 适配器再覆盖。
        var spiFeatures = spec.spiOverride ?? profile.spi

        // 语言 / 时区跟随代理：按出口 IP 的国家定下语言和时区，再交给工厂。
        if profile.followProxyLanguages || profile.followProxyTimeZone {
            // 重新启动过的 Runner 带着上一次的结果：先记下是不是重启过，用完就把这些环境变量清掉，不再传给子进程。
            let wasRelaunched = ProcessInfo.processInfo.environment[ProxyGeoResult.relaunchFlag] != nil
            let resolved = RunnerMain.resolveFollowProxy(proxy: proxy, nodeHint: bound?.node.name)
            for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("SAFARIER_GEO_") { unsetenv(key) }
            if let resolved {
                outbound["geo"] = [
                    "country": resolved.countryCode, "languages": resolved.languages,
                    "timeZone": resolved.timeZoneIdentifier, "source": "\(resolved.source)",
                ]
                if profile.followProxyLanguages {
                    // -AppleLanguages 只能在进程启动时生效：语言不一样就带上新参数重新启动自己（只重启一次）。
                    let current = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
                    if current != resolved.languages && !wasRelaunched {
                        RunnerMain.relaunch(arguments: arguments, resolved: resolved, followTimeZone: profile.followProxyTimeZone)
                    }
                    effectiveProfile.languages = resolved.languages
                }
                if profile.followProxyTimeZone {
                    effectiveProfile.timeZoneIdentifier = resolved.timeZoneIdentifier
                    spiFeatures.insert(.engineTimeZone)
                }
            } else {
                FileHandle.standardError.write(Data("[geo] 跟随代理没能确定出口国家，语言和时区沿用系统\n".utf8))
            }
        }
        let privacy = CompositePrivacyAdapter([
            PublicAPIPrivacyAdapter(),
            SPIPrivacyAdapter(features: spiFeatures, diagnostics: diagnostics),
        ])
        let factory = WebViewConfigurationFactory(credentials: KeychainCredentialStore(), privacy: privacy)
        var output = try factory.make(profile: effectiveProfile, proxy: proxy, executionPolicy: executionPolicy)
        if let displayState { output.report.set(displayState, for: .displayCapabilities) }
        return Result(launchPlan: plan, effectiveProfile: effectiveProfile, output: output, spiFeatures: spiFeatures, diagnostics: diagnostics, outbound: outbound, outboundDescription: outboundDescription, adapter: factory.privacy.identifier)
    }
}

// Watches a previously validated private socket without reading or changing it.
// The duplicated fd is owned and closed exclusively by the polling task.
final class BackgroundStartupControlWatch {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stopping = false
        private var ready = false
        func markReady() { lock.lock(); ready = true; lock.unlock() }
        func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return ready }
        func requestStop() { lock.lock(); stopping = true; lock.unlock() }
        func isStopping() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    }

    enum WatchError: Error { case systemCall(Int32) }
    private let state: State
    private let task: Task<Bool, Never>

    init(input: FileHandle, onDisconnect: @Sendable @escaping () -> Void) throws {
        try AutomationChannel.validateConnectedStream(fileDescriptor: input.fileDescriptor)
        let fd = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw WatchError.systemCall(errno) }
        let state = State()
        self.state = state
        self.task = Task.detached {
            defer { state.markReady(); Darwin.close(fd) }
            var firstPoll = true
            while true {
                let stopping = state.isStopping()
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&descriptor, 1, stopping || firstPoll ? 0 : 25)
                if result < 0 && errno == EINTR {
                    if state.isStopping() { return false }
                    continue
                }
                if result < 0 || descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    onDisconnect()
                    return true
                }
                if firstPoll { state.markReady(); firstPoll = false }
                if stopping { return false }
                // Queued hello makes POLLIN level-triggered; leave it untouched without spinning.
                if result > 0 { usleep(25_000) }
            }
        }
    }

    func waitUntilReady() async throws {
        while !state.isReady() {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try Task.checkCancellation()
    }

    func stop() async -> Bool {
        state.requestStop()
        return await task.value
    }

    deinit { state.requestStop() }
}

// Bridges disconnects observed before the preparation task is installed.
private final class BackgroundStartupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var disconnected = false
    private var cancel: (@Sendable () -> Void)?
    func disconnect() {
        lock.lock(); disconnected = true; let cancel = self.cancel; lock.unlock()
        cancel?()
    }
    func install(_ cancel: @Sendable @escaping () -> Void) {
        lock.lock(); self.cancel = cancel; let disconnected = self.disconnected; lock.unlock()
        if disconnected { cancel() }
    }
}


// Keep the Foundation-only service entry independent of the App preparation path.
extension RunnerAutomationEntry {
    @MainActor
    static func serve(profile: Profile, spec: RunnerLaunchSpec, workspace: SafarierWorkspace, arguments: [String], rawInput: FileHandle, originalLock: ProfileLock) async -> Int32 {
        // Keep the actual lock object alive through the entry; the bound Core
        // handoff must borrow this object, never reacquire by profile ID.
        _ = originalLock
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        return await serveBoundLocal(profile: profile, spec: spec, workspace: workspace,
                                     arguments: arguments, rawInput: rawInput, originalLock: originalLock)
        #else
        guard NativeInputPreflight.shippingAdmissionAvailable else {
            do {
                let channel = try AutomationChannel(adopting: rawInput)
                return await AutomationRunnerBootstrap.serveUnavailable(profileID: profile.id, channel: channel)
            } catch { return 1 }
        }
        do {
            // Preserve the hard denial before creating any watcher or preparation task.
            try WebViewConfigurationFactory.requireExecutionPolicy(.automationBackground)
            try NativePageInput.requireShippingAdmission()
            do { try AutomationChannel.validateConnectedStream(fileDescriptor: rawInput.fileDescriptor) }
            catch { return 1 }
            let cancellation = BackgroundStartupCancellation()
            let watch: BackgroundStartupControlWatch
            do { watch = try BackgroundStartupControlWatch(input: rawInput, onDisconnect: { cancellation.disconnect() }) }
            catch { return 1 } // No preparation task or owned resources exist yet.
            do { try await watch.waitUntilReady() }
            catch { _ = await watch.stop(); return 1 }
            // No yield between task creation and installing the cancellation token on MainActor.
            let preparation = Task { @MainActor in
                try Task.checkCancellation()
                return try await RunnerPreparation.prepareBackground(profile: profile, spec: spec, workspace: workspace, arguments: arguments)
            }
            cancellation.install { preparation.cancel() }
            let prepared: Swift.Result<RunnerPreparation.BackgroundResult, Error> = await withTaskCancellationHandler {
                await preparation.result
            } onCancel: {
                preparation.cancel()
            }
            let disconnected = await watch.stop()
            let result: RunnerPreparation.BackgroundResult
            do { result = try prepared.get() }
            catch {
                if disconnected || preparation.isCancelled || Task.isCancelled { return 1 }
                throw error
            }
            let resources = result.resources
            if disconnected || preparation.isCancelled || Task.isCancelled {
                _ = await resources.close()
                return 1
            }
            let status: Int32
            do {
                let service = try RunnerMain.makeAutomationService(prepared: result.prepared, workspace: workspace)
                let channel = try AutomationChannel(adopting: rawInput)
                status = await service.serve(channel: channel)
            } catch {
                _ = await resources.close()
                return 1
            }
            return await resources.close() ? status : 1
        } catch RunnerPreparation.BackgroundError.ownedCleanupUnobserved {
            return 1
        } catch {
            do {
                let channel = try AutomationChannel(adopting: rawInput)
                return await AutomationRunnerBootstrap.serveUnavailable(profileID: profile.id, channel: channel)
            } catch { return 1 }
        }
        #endif
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    @MainActor
    private static func serveBoundLocal(profile: Profile, spec: RunnerLaunchSpec, workspace: SafarierWorkspace, arguments: [String], rawInput: FileHandle, originalLock: ProfileLock) async -> Int32 {
        let started = DispatchTime.now().uptimeNanoseconds
        var phase = "serve.channel.before"
        prepTrace(phase, started)
        do {
            let channel = try AutomationChannel(adopting: rawInput)
            let slot = BoundRunnerServiceSlot()
            let server = AutomationRunnerServer(profileID: profile.id, channel: channel, handler: { request in
                await slot.handle(request)
            }, shutdown: {
                Task { @MainActor in slot.beginClosing() }
            })
            phase = "serve.install_context.before"; prepTrace(phase, started)
            let context = try await server.installAppContext(workspace: workspace, spec: spec, originalLock: originalLock, arguments: arguments, environment: ProcessInfo.processInfo.environment)
            phase = "serve.install_context.after"; prepTrace(phase, started)
            try slot.install(context)
            phase = "serve.app_bound.before"; prepTrace(phase, started)
            let status = await server.serveAppBound { bound in
                prepTrace("serve.prepare_callback.before", started)
                do {
                    try await slot.prepare(context: bound, profile: profile, spec: spec, workspace: workspace)
                    prepTrace("serve.prepare_callback.after", started)
                } catch { prepTrace("serve.prepare_callback.failure", started, prepError(error)); throw error }
            }
            phase = "serve.app_bound.after"; prepTrace(phase, started, status == 0 ? "ok" : "failed")
            slot.beginClosing()
            guard await slot.drain() else { return 1 }
            await context.finishAfterResourcesDrained()
            return status
        } catch { prepTrace(phase, started, prepError(error)); return 1 }
    }
    #endif
}
