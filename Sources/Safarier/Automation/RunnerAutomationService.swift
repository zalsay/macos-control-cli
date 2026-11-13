import Foundation
import SafarierCore
#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Darwin
private func openingDiagnosticCode(_ error: Error) -> String {
    (error as? AutomationError)?.code.rawValue ?? "unknown"
}
#endif

enum RunnerPageOwnership { case owned, borrowed }

@MainActor private func disposeAutomationPage(_ page: any RunnerAutomationPage, ownership: RunnerPageOwnership) async -> Bool {
    switch ownership {
    case .owned: return await page.destroy()
    case .borrowed: return await page.detachBorrowedControl()
    }
}

/// One owner for an adopted page and its private store. A late or deinitializing
/// owner starts each cleanup at most once; storage I/O never executes on MainActor.
private final class RunnerSessionResources: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanupStarted = false
    private var transferred = false
    private var releaseTicket: UUID?
    private var borrowedReceipt: CleanupReceipt?
    private let page: any RunnerAutomationPage
    private let expected: AutomationTargetIdentity
    private let ownership: RunnerPageOwnership
    let store: AutomationSnapshotStore
    init(page: any RunnerAutomationPage, expected: AutomationTargetIdentity, store: AutomationSnapshotStore, ownership: RunnerPageOwnership) {
        self.page = page; self.expected = expected; self.store = store; self.ownership = ownership
    }
    func borrowedCleanupReceipt() -> CleanupReceipt? { lock.lock(); defer { lock.unlock() }; return borrowedReceipt }
    private func rememberBorrowedReceipt(_ receipt: CleanupReceipt) { lock.lock(); defer { lock.unlock() }; borrowedReceipt = receipt }
    private func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !cleanupStarted, !transferred else { return false }; cleanupStarted = true; return true }
    @MainActor func prepareRelease(_ identity: AutomationTargetIdentity) async throws -> ControlReleasePreparation {
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.cleanupSeconds)
        func requireTime() throws {
            guard !Task.isCancelled else { throw AutomationError(code: .cancelled) }
            guard ContinuousClock.now < deadline else { throw AutomationError(code: .timeout) }
        }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let started = DispatchTime.now().uptimeNanoseconds
        func trace(_ phase: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= started ? (now - started) / 1_000_000 : 0
            fputs("RELEASE_DIAG phase=\(phase) elapsed_ms=\(elapsed) monotonic_ms=\(now / 1_000_000)\n", stderr)
        }
        #endif
        guard identity == expected, page.identity == expected, releaseTicket == nil else { throw AutomationError(code: .targetChanged) }
        try requireTime()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        trace("input.before")
        #endif
        try await page.prepareControlRelease()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        trace("input.after")
        #endif
        try requireTime()
        guard !Task.isCancelled, page.identity == expected else { throw AutomationError(code: .cancelled) }
        let result = await Task.detached { [store] in store.close() }.value
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        trace("store.after")
        #endif
        try requireTime()
        guard !Task.isCancelled, result.cleaned, page.identity == expected else { throw AutomationError(code: .targetChanged) }
        _ = try page.viewport()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        trace("prepare.done")
        #endif
        try requireTime()
        let id = UUID(); try requireTime(); releaseTicket = id
        return ControlReleasePreparation(target: expected, transferID: id, inputReleased: true, artifactsCleaned: result.cleaned, browserRetained: true)
    }
    @MainActor func commitRelease(_ id: UUID, identity: AutomationTargetIdentity) throws -> ControlReleaseReceipt {
        guard releaseTicket == id, identity == expected, page.identity == expected, !Task.isCancelled else { throw AutomationError(code: .targetChanged) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        fputs("RELEASE_DIAG phase=runner.commit.before monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000)\n", stderr)
        #endif
        try page.commitControlRelease()
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        fputs("RELEASE_DIAG phase=runner.commit.after monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000)\n", stderr)
        #endif
        return ControlReleaseReceipt(target: expected, transferID: id, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)
    }
    @MainActor func finishTransfer(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cleanupStarted, !transferred, releaseTicket == id else { return false }
        guard (try? page.finishControlRelease()) != nil else { return false }
        transferred = true; releaseTicket = nil; return true
    }
    @MainActor func quiesceInput() {
        if page.identity == expected { page.quiesceInput() }
    }
    @MainActor func cleanup(_ identity: AutomationTargetIdentity) async -> CleanupReceipt {
        guard claim() else { return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }
        let storage = Task.detached { [store] in store.close() }
        let destroyed: Bool
        if identity == expected && page.identity == expected { destroyed = await disposeAutomationPage(page, ownership: ownership) } else { destroyed = false }
        let result = await storage.value
        let retained: RetainedBrowserCleanup? = ownership == .borrowed && destroyed && result.cleaned
            ? RetainedBrowserCleanup(target: expected, inputReleased: true, artifactsCleaned: true,
                                     browserRetained: true, manualInteractionEnabled: true) : nil
        let receipt = CleanupReceipt(cleaned: ownership == .owned && destroyed && result.cleaned,
                                     terminatedOwnedRunner: false, retainedBrowser: retained)
        if retained != nil { rememberBorrowedReceipt(receipt) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        fputs("CLOSE_DIAG phase=runner.cleanup destroyed=\(destroyed) storeCleaned=\(result.cleaned) removedFiles=\(result.removedFiles) retainedFiles=\(result.retainedFiles) directoryRemoved=\(result.directoryRemoved)\n", stderr)
        #endif
        return receipt
    }
    deinit {
        guard claim() else { return }
        let page = page, expected = expected, store = store, ownership = ownership
        Task { @MainActor in if page.identity == expected { _ = await disposeAutomationPage(page, ownership: ownership) } }
        Task.detached { _ = store.close() }
    }
}

/// Offline composition only. Construction is internal and the shipping entry
/// below does not instantiate this service while admission remains unavailable.
@MainActor final class RunnerAutomationService {
    typealias PermissionReader = @MainActor () async -> Bool
    typealias PageFactory = @MainActor () async throws -> any RunnerAutomationPage
    typealias SnapshotFactory = @Sendable () throws -> AutomationSnapshotStore
    typealias Now = RunnerAutomationController.Now
    typealias SleepUntil = RunnerAutomationController.SleepUntil
    private final class Opening {
        let request: AutomationRequest
        let continuation: CheckedContinuation<AutomationReply, Never>
        let generation: UUID
        let expectedProfile: UUID, expectedInstance: UUID
        let ownership: RunnerPageOwnership
        let cancellation: CancelFlag, deadline: Double
        var lastInstant: Double
        var expectedIdentity: AutomationTargetIdentity?
        var completed = false
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var page: (any RunnerAutomationPage)?
        var store: AutomationSnapshotStore?
        init(request: AutomationRequest, continuation: CheckedContinuation<AutomationReply, Never>, expectedProfile: UUID, expectedInstance: UUID, ownership: RunnerPageOwnership, cancellation: CancelFlag, startedAt: Double, deadline: Double) {
            self.request = request; self.continuation = continuation; self.generation = UUID()
            self.expectedProfile = expectedProfile; self.expectedInstance = expectedInstance; self.ownership = ownership
            self.cancellation = cancellation; self.lastInstant = startedAt; self.deadline = deadline
        }
        deinit {
            timer?.cancel(); worker?.cancel()
            if !completed { continuation.resume(returning: AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .runnerExited)))) }
            if let page, let expectedIdentity { let ownership = ownership; Task { @MainActor in if page.identity == expectedIdentity { _ = await disposeAutomationPage(page, ownership: ownership) } } }
            if let store { Task.detached { _ = store.close() } }
        }
    }
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock(); private var cancelled = false, committed = false
        func set() { lock.lock(); cancelled = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func commitIfNotCancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled, !committed else { return false }
            committed = true; return true
        }
    }
    private let profileID: UUID, runnerInstanceID: UUID
    private let permissionReader: PermissionReader
    private let pageFactory: PageFactory
    private let snapshotFactory: SnapshotFactory
    private let now: Now
    private let sleepUntil: SleepUntil
    private let cleanupVerifier: @MainActor () -> Bool
    private let localCandidate: Bool
    private let pageOwnership: RunnerPageOwnership
    private var opening: Opening?
    private var openingTasks = Set<UUID>()
    private var orphanCleanups = Set<UUID>()
    private var orphanCleanupFailed = false
    private var session: AutomationSessionMachine?
    private var controller: RunnerAutomationController?
    private var resources: RunnerSessionResources?
    private var openedRequest: AutomationRequest?
    private var openedReply: AutomationReply?
    private var stopped = false
    private var shutdownStarted = false
    private var controlTransferFinalized = false

    init(profileID: UUID, runnerInstanceID: UUID, permissionReader: @escaping PermissionReader, pageFactory: @escaping PageFactory, snapshotFactory: @escaping SnapshotFactory, now: @escaping Now = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }, sleepUntil: @escaping SleepUntil = { deadline in
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let delay = max(0, deadline - now)
        guard delay.isFinite, delay < Double(UInt64.max) / 1_000_000_000 else { throw CancellationError() }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }, cleanupVerifier: @escaping @MainActor () -> Bool = { true }, localCandidate: Bool = false, pageOwnership: RunnerPageOwnership = .owned) {
        self.cleanupVerifier = cleanupVerifier; self.localCandidate = localCandidate; self.pageOwnership = pageOwnership
        self.profileID = profileID; self.runnerInstanceID = runnerInstanceID; self.permissionReader = permissionReader
        self.pageFactory = pageFactory; self.snapshotFactory = snapshotFactory; self.now = now; self.sleepUntil = sleepUntil
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func matchesBoundIdentity(profileID: UUID, runnerInstanceID: UUID) -> Bool {
        self.profileID == profileID && self.runnerInstanceID == runnerInstanceID
    }

    #if SAFARIER_PARALLEL_PERMISSION_CANDIDATE
    /// Read-only prefetch candidate. Structured children are drained on all exits;
    /// neither their values nor an initial identity success authorize an action.
    static func parallelPermission(validate: @escaping @Sendable () async throws -> Void,
                                   read: @escaping @Sendable () async throws -> Bool) async -> Bool {
        do {
            async let first: Void = validate()
            async let allowed: Bool = read()
            let (_, result) = try await (first, allowed)
            try Task.checkCancellation()
            try await validate()
            try Task.checkCancellation()
            return result
        } catch { return false }
    }
    #endif
    #endif

    /// Disk I/O is detached and missing, corrupt, inaccessible or revoked is false.
    static func repositoryPermission(profileID: UUID, root: URL) async -> Bool {
        await Task.detached {
            do {
                guard let profile = try SafarierWorkspace(root: root).profiles.record(id: profileID) else { return false }
                return profile.id == profileID && profile.allowsAgentAccess
            }
            catch { return false }
        }.value
    }
    private func error(_ request: AutomationRequest, _ code: AutomationErrorCode) -> AutomationReply {
        AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: code)))
    }
    func handle(_ request: AutomationRequest) async -> AutomationReply {
        // Protect the sole open receipt's ID without creating another replay
        // cache. Authenticate the session before reporting an ID collision.
        if openedRequest?.requestID == request.requestID {
            switch request.action {
            case .capabilities, .openSession: break
            default:
                guard session?.acceptsSessionID(request.sessionID) == true else { return error(request, .sessionNotFound) }
            }
        }
        guard (try? AutomationCodec.encodeRequest(request)) != nil else { return error(request, .invalidRequest) }
        guard !stopped else { return error(request, .sessionExpired) }
        switch request.action {
        case .capabilities:
            if openedRequest?.requestID == request.requestID { return error(request, .requestIDReused) }
            let caps = AutomationCapabilities(backend: localCandidate ? .unverified : .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: localCandidate ? "1-bound-local-candidate" : "1", role: "runner", managerPID: Int(getppid()))
            return AutomationReply(requestID: request.requestID, outcome: .success(.capabilities(caps)))
        case .openSession(let requestedProfile):
            if let old = openedRequest, old.requestID == request.requestID {
                guard old.action == request.action else { return error(request, .requestIDReused) }
                guard session?.state != .stopping, session?.state != .closed, let openedReply else { return error(request, .sessionExpired) }
                return openedReply
            }
            if let current = opening, current.request.requestID == request.requestID && current.request.action != request.action { return error(request, .requestIDReused) }
            guard requestedProfile == profileID else { return error(request, .profileNotAllowed) }
            guard controller == nil, opening == nil, openingTasks.isEmpty else { return error(request, .sessionBusy) }
            let flag = CancelFlag()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    guard !flag.value, !Task.isCancelled, !stopped else { continuation.resume(returning: error(request, .cancelled)); return }
                    let start = now(), deadline = start + AutomationLimits.startupSeconds
                    guard start.isFinite, deadline.isFinite else { continuation.resume(returning: error(request, .invalidRequest)); return }
                    let current = Opening(request: request, continuation: continuation, expectedProfile: profileID, expectedInstance: runnerInstanceID, ownership: pageOwnership, cancellation: flag, startedAt: start, deadline: deadline)
                    opening = current
                    let sleeper = sleepUntil, generation = current.generation
                    current.timer = Task { @MainActor [weak self] in
                        do { try await sleeper(deadline); self?.openTimer(generation, deadline: deadline) }
                        catch { self?.openTimerFailed(generation) }
                    }
                    startPermission(generation, final: false)
                }
            }, onCancel: { [weak self] in
                flag.set()
                Task { @MainActor [weak self] in self?.cancelOpen(requestID: request.requestID) }
            })
        default:
            guard let controller else { return error(request, .sessionNotFound) }
            if openedRequest?.requestID == request.requestID { return error(request, .requestIDReused) }
            return await controller.handle(request)
        }
    }
    /// Check synchronously at every opening continuation / factory boundary.
    private func openingUsable(_ generation: UUID) -> Bool {
        guard let current = opening, current.generation == generation, !stopped else { return false }
        if current.cancellation.value { abortOpening(.cancelled); return false }
        let instant = now()
        guard instant.isFinite, instant >= current.lastInstant else { abortOpening(.backendUnavailable); return false }
        current.lastInstant = instant
        guard instant < current.deadline else { abortOpening(.timeout); return false }
        return true
    }
    private func startPermission(_ generation: UUID, final: Bool) {
        guard openingUsable(generation), let current = opening else { return }
        let taskID = UUID(), read = permissionReader
        openingTasks.insert(taskID)
        current.worker = Task { @MainActor [weak self] in
            guard self?.openingUsable(generation) == true else { self?.openingTasks.remove(taskID); return }
            let allowed = await read()
            self?.openingTasks.remove(taskID)
            self?.permissionResult(generation, allowed: allowed, final: final)
        }
    }
    private func permissionResult(_ generation: UUID, allowed: Bool, final: Bool) {
        guard openingUsable(generation), let current = opening else { return }
        guard allowed else { abortOpening(.profileNotAllowed); return }
        if final { finishOpening(generation); return }
        let taskID = UUID(), factory = pageFactory, profile = profileID, instance = runnerInstanceID, ownership = pageOwnership
        openingTasks.insert(taskID)
        current.worker = Task { @MainActor [weak self] in
            guard self?.openingUsable(generation) == true else { self?.openingTasks.remove(taskID); return }
            do {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                fputs("OPEN_DIAG phase=runner.page_factory.before\n", stderr)
                #endif
                let page = try await factory()
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                fputs("OPEN_DIAG phase=runner.page_factory.after\n", stderr)
                #endif
                if let self { self.openingTasks.remove(taskID); self.pageResult(generation, page: page) }
                else if page.identity.profileID == profile && page.identity.runnerInstanceID == instance { _ = await disposeAutomationPage(page, ownership: ownership) }
            } catch {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                fputs("OPEN_DIAG phase=runner.page_factory.failure code=\(openingDiagnosticCode(error))\n", stderr)
                #endif
                self?.openingTasks.remove(taskID); self?.abortIfCurrent(generation, code: .backendUnavailable)
            }
        }
    }
    private func pageResult(_ generation: UUID, page: any RunnerAutomationPage) {
        let actual = page.identity
        let matches = actual.profileID == profileID && actual.runnerInstanceID == runnerInstanceID
        guard openingUsable(generation), let current = opening else {
            if matches { cleanupOrphan(page: page, identity: actual, store: nil) }
            return
        }
        guard matches else { abortOpening(.targetChanged); return }
        current.page = page; current.expectedIdentity = actual
        do { _ = try page.viewport() } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            fputs("OPEN_DIAG phase=runner.page_viewport.failure code=\(openingDiagnosticCode(error))\n", stderr)
            #endif
            abortOpening(.targetChanged); return
        }
        let taskID = UUID(), factory = snapshotFactory
        openingTasks.insert(taskID)
        current.worker = Task { @MainActor [weak self] in
            guard self?.openingUsable(generation) == true else { self?.openingTasks.remove(taskID); return }
            do {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                fputs("OPEN_DIAG phase=runner.store_factory.before\n", stderr)
                #endif
                let store = try await Task.detached { try factory() }.value
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                fputs("OPEN_DIAG phase=runner.store_factory.after\n", stderr)
                #endif
                if let self { self.openingTasks.remove(taskID); self.storeResult(generation, store: store) }
                else { Task.detached { _ = store.close() } }
            } catch {
                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                fputs("OPEN_DIAG phase=runner.store_factory.failure code=\(openingDiagnosticCode(error))\n", stderr)
                #endif
                self?.openingTasks.remove(taskID); self?.abortIfCurrent(generation, code: .backendUnavailable)
            }
        }
    }
    private func storeResult(_ generation: UUID, store: AutomationSnapshotStore) {
        guard openingUsable(generation), let current = opening else { cleanupOrphan(page: nil, identity: nil, store: store); return }
        current.store = store
        startPermission(generation, final: true)
    }
    private func finishOpening(_ generation: UUID) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        fputs("OPEN_DIAG phase=runner.finish_opening.before\n", stderr)
        #endif
        guard openingUsable(generation), let current = opening, let page = current.page, let store = current.store else {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            fputs("OPEN_DIAG phase=runner.finish_opening.unavailable\n", stderr)
            #endif
            return
        }
        do {
            guard page.identity.profileID == profileID, page.identity.runnerInstanceID == runnerInstanceID, page.identity == current.expectedIdentity else { abortOpening(.targetChanged); return }
            let viewport = try page.viewport(), token = try AutomationSessionToken.generate()
            let machine = try AutomationSessionMachine.open(profileID: profileID, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: now()).get()
            guard machine.bind(target: page.identity, viewport: viewport, at: now()).isEmpty, machine.state == .ready else { abortOpening(.targetChanged); return }
            let identity = page.identity
            guard openingUsable(generation) else { return }
            // Claim before transferring ownership: on cancellation Opening still
            // owns the page/store and abortOpening tracks their actual cleanup.
            guard current.cancellation.commitIfNotCancelled() else { abortOpening(.cancelled); return }
            let resources = RunnerSessionResources(page: page, expected: identity, store: store, ownership: pageOwnership)
            // Ownership transfers before the final cancellation check, so exactly
            // one of Opening or RunnerSessionResources performs cleanup.
            current.page = nil; current.store = nil
            let controller = RunnerAutomationController(machine: machine, permissionReader: { [permissionReader] in await permissionReader() }, targetReader: { [weak page] in
                guard let page else { throw AutomationError(code: .targetChanged) }
                return page.identity
            }, actionSink: { [weak machine, weak page] request, ticket in
                guard !Task.isCancelled, let machine, let page, machine.currentTicket == ticket, let expected = machine.boundViewport, page.identity == identity else { throw AutomationError(code: .targetChanged) }
                let value: AutomationResult
                switch request.action {
                case .releaseControl:
                    value = .controlReleasePrepared(try await resources.prepareRelease(identity))
                    guard !Task.isCancelled, machine.currentTicket == ticket, page.identity == identity,
                          try page.viewport() == expected else { throw AutomationError(code: .targetChanged) }
                case .commitControlRelease(let transferID):
                    value = .controlReleased(try resources.commitRelease(transferID, identity: identity))
                case .getState:
                    guard try page.viewport() == expected else { throw AutomationError(code: .targetChanged) }
                    value = .stateRead(try page.readState(sessionState: machine.state, expectedViewport: expected))
                case .screenshot:
                    guard try page.viewport() == expected else { throw AutomationError(code: .targetChanged) }
                    let snapshot = try await page.captureSnapshot(expectedViewport: expected)
                    guard !Task.isCancelled, machine.currentTicket == ticket, page.identity == identity, machine.boundViewport == expected, snapshot.viewport == expected else { throw AutomationError(code: .targetChanged) }
                    let path = try await Task.detached { try store.write(png: snapshot.png, viewport: snapshot.viewport) }.value
                    guard !Task.isCancelled, machine.currentTicket == ticket, page.identity == identity, machine.boundViewport == expected else { throw AutomationError(code: .targetChanged) }
                    value = .snapshotWritten(path: path.path, viewport: snapshot.viewport)
                default:
                    if !request.action.isNavigation, try page.viewport() != expected { throw AutomationError(code: .targetChanged) }
                    value = try await page.perform(request.action, expectedViewport: expected)
                    guard !Task.isCancelled, machine.currentTicket == ticket, page.identity == identity, machine.boundViewport == expected else { throw AutomationError(code: .targetChanged) }
                }
                return AutomationReply(requestID: request.requestID, outcome: .success(value))
            }, cleanupSink: { [resources] owned, _, _ in
                await resources.cleanup(owned)
            }, borrowedCleanupReceipt: { [resources] in resources.borrowedCleanupReceipt() }, now: now, sleepUntil: sleepUntil)
            page.onBlocked = { [weak controller] request in controller?.blockUI(request) }
            let reply = AutomationReply(requestID: current.request.requestID, outcome: .success(.sessionOpened(sessionID: token, target: identity, viewport: viewport)))
            openedRequest = current.request; openedReply = reply; session = machine; self.controller = controller; self.resources = resources
            current.page = nil; current.store = nil; current.completed = true
            opening = nil; current.timer?.cancel()
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            fputs("OPEN_DIAG phase=runner.finish_opening.success\n", stderr)
            #endif
            current.continuation.resume(returning: reply)
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            fputs("OPEN_DIAG phase=runner.finish_opening.failure code=\(openingDiagnosticCode(error))\n", stderr)
            #endif
            abortOpening(.backendUnavailable)
        }
    }
    private func abortIfCurrent(_ generation: UUID, code: AutomationErrorCode) { if opening?.generation == generation { abortOpening(code) } }
    private func cancelOpen(requestID: UUID) { if opening?.request.requestID == requestID { abortOpening(.cancelled) } }
    private func cleanupOrphan(page: (any RunnerAutomationPage)?, identity: AutomationTargetIdentity?, store: AutomationSnapshotStore?) {
        let id = UUID()
        orphanCleanups.insert(id)
        Task { @MainActor [self] in
            var cleaned = true
            if let page {
                if let identity, page.identity == identity { cleaned = await disposeAutomationPage(page, ownership: pageOwnership) }
                else { cleaned = false }
            }
            if let store {
                let result = await Task.detached { store.close() }.value
                cleaned = cleaned && result.cleaned
            }
            if !cleaned { orphanCleanupFailed = true }
            orphanCleanups.remove(id)
        }
    }
    private func abortOpening(_ code: AutomationErrorCode) {
        guard let current = opening else { return }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        fputs("OPEN_DIAG phase=runner.abort_opening code=\(code.rawValue)\n", stderr)
        #endif
        stopped = true
        opening = nil; current.timer?.cancel(); current.worker?.cancel()
        let page = current.page, identity = current.expectedIdentity, store = current.store
        current.page = nil; current.store = nil
        if page != nil || store != nil { cleanupOrphan(page: page, identity: identity, store: store) }
        current.completed = true
        current.continuation.resume(returning: error(current.request, code))
    }
    private func openTimer(_ generation: UUID, deadline: Double) {
        guard let current = opening, current.generation == generation else { return }
        if current.cancellation.value { abortOpening(.cancelled); return }
        let instant = now()
        guard instant.isFinite, instant >= current.lastInstant, instant >= deadline else { abortOpening(.backendUnavailable); return }
        abortOpening(.timeout)
    }
    private func openTimerFailed(_ generation: UUID) { if opening?.generation == generation { abortOpening(.backendUnavailable) } }
    func shutdown() {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        stopped = true
        // A committed transfer no longer owns the page or its input lease.
        // Do not quiesce an already returned window in a later generation.
        if controlTransferFinalized { return }
        if let resources { resources.quiesceInput() }
        else if let current = opening, let page = current.page, let expected = current.expectedIdentity,
                expected.profileID == current.expectedProfile, expected.runnerInstanceID == current.expectedInstance,
                page.identity == expected { page.quiesceInput() }
        abortOpening(.cancelled)
        controller?.shutdown()
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func finishControlRelease(_ receipt: ControlReleaseReceipt) -> Bool {
        guard session?.controlReleaseCommitted == true, session?.state == .released,
              receipt.target == session?.boundTarget, receipt.inputReleased, receipt.artifactsCleaned,
              receipt.browserRetained, receipt.manualInteractionEnabled, let resources else { return false }
        guard resources.finishTransfer(receipt.transferID) else { return false }
        controlTransferFinalized = true
        return true
    }
    #endif
    /// Wait for actual owned work, not merely the reducer's cancellation reply.
    func shutdownAndDrain() async -> Bool {
        shutdown()
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.cleanupSeconds)
        while !openingTasks.isEmpty || !orphanCleanups.isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
        }
        guard !orphanCleanupFailed else { return false }
        if controlTransferFinalized { return cleanupVerifier() }
        if session?.controlReleaseCommitted == true, !controlTransferFinalized,
           let resources, let target = session?.boundTarget {
            let receipt = await resources.cleanup(target)
            let proved = receipt.cleaned || (receipt.retainedBrowser?.target == target && receipt.retainedBrowser?.confirmed == true)
            return proved && cleanupVerifier()
        }
        if let controller {
            let drained = await controller.shutdownAndDrain()
            return drained && cleanupVerifier()
        }
        return resources == nil && cleanupVerifier()
    }
    func serve(channel: AutomationChannel, idleSeconds: Double = AutomationLimits.idleSeconds) async -> Int32 {
        let server = AutomationRunnerServer(profileID: profileID, runnerInstanceID: runnerInstanceID, channel: channel, idleSeconds: idleSeconds, handler: { [weak self] request in
            guard let self else { return .failure(AutomationError(code: .runnerExited)) }
            return await self.handle(request).outcome
        }, shutdown: { [weak self] in Task { @MainActor [weak self] in self?.shutdown() } })
        let status = await server.serve()
        shutdown()
        return status
    }
}

/// No factory or permission reader is consulted here. A future verified target
/// preparation path must be separately authorized before this branch changes.
enum RunnerAutomationEntry {
    static func serve(profileID: UUID, channel: AutomationChannel) async -> Int32 {
        guard NativeInputPreflight.shippingAdmissionAvailable else { return await AutomationRunnerBootstrap.serveUnavailable(profileID: profileID, channel: channel) }
        return await AutomationRunnerBootstrap.serveUnavailable(profileID: profileID, channel: channel)
    }
}
