import Foundation
import Darwin
@testable import SafarierCore
#if !RUNNER_SERVICE_STANDALONE
@testable import Safarier
#endif

@MainActor public enum RunnerAutomationServiceCases {
    struct Failure: Error { let label: String }
    @MainActor final class Gate<T> {
        var waits: [CheckedContinuation<T, Never>] = []
        func wait() async -> T { await withCheckedContinuation { waits.append($0) } }
        func release(_ value: T) { let all = waits; waits.removeAll(); for wait in all { wait.resume(returning: value) } }
    }
    static func drain() async { for _ in 0..<120 { await Task.yield() } }
    static func until(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100_000 { if predicate() { return }; await Task.yield() }
        throw Failure(label: label)
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var number = 0
        func increment() { lock.lock(); number += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return number }
    }
    final class BlockingWriter: @unchecked Sendable {
        private let condition = NSCondition()
        private var waiting = false, released = false, pathValue: String?
        func write(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            _ = fcntl(fd, F_GETPATH, &path)
            condition.lock(); pathValue = String(cString: path); waiting = true; condition.broadcast()
            while !released { condition.wait() }
            condition.unlock()
            return Darwin.write(fd, bytes, count)
        }
        var started: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
        var path: String? { condition.lock(); defer { condition.unlock() }; return pathValue }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }
    @MainActor final class FakeClock { var now = 0.0 }
    @MainActor final class Page: RunnerAutomationPage {
        var identity: AutomationTargetIdentity
        var onBlocked: ((BackgroundUIRequest) -> Void)?
        var destroyed = 0, calls = 0, quiesced = 0, effects = 0
        var performGate: Gate<Void>?
        var onPerform: (() -> Void)?
        var destroyGate: Gate<Bool>?
        var snapshotGate: Gate<RunnerAutomationPageSnapshot>?
        let view = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        init(identity: AutomationTargetIdentity) { self.identity = identity }
        func viewport() throws -> AutomationViewport { view }
        func readState(sessionState: AutomationSessionState, expectedViewport: AutomationViewport) throws -> AutomationState { AutomationState(target: identity, url: URL(string: "about:blank"), loading: false, sessionState: sessionState, viewVersion: expectedViewport.viewVersion) }
        func perform(_ action: AutomationAction, expectedViewport: AutomationViewport) async throws -> AutomationResult {
            calls += 1; onPerform?()
            if let performGate { await performGate.wait(); if quiesced == 0 { effects += 1 } }
            if case .mouseDown = action { return .nativeDelivered(sequence: UInt64(calls), buttons: 1, viewVersion: expectedViewport.viewVersion) }
            return .nativeDelivered(sequence: UInt64(calls), buttons: 0, viewVersion: expectedViewport.viewVersion)
        }
        func captureSnapshot(expectedViewport: AutomationViewport) async throws -> RunnerAutomationPageSnapshot {
            if let snapshotGate { return await snapshotGate.wait() }
            return RunnerAutomationPageSnapshot(png: Data([137,80,78,71,13,10,26,10, 0,0,0,13,73,72,68,82, 0,0,0,1,0,0,0,1, 8,6,0,0,0, 0,0,0,0]), viewport: expectedViewport)
        }
        func quiesceInput() { quiesced += 1 }
        func destroy() async -> Bool { destroyed += 1; if let destroyGate { return await destroyGate.wait() }; return true }
    }
    private static func runOpeningCases(base: URL) async throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws { checks += 1; if !value() { throw Failure(label: name) } }
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target), gate = Gate<any RunnerAutomationPage>(), destroyGate = Gate<Bool>()
        page.destroyGate = destroyGate
        var factoryCalls = 0
        let storeCalls = Counter()
        let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { factoryCalls += 1; return await gate.wait() }, snapshotFactory: { storeCalls.increment(); return try AutomationSnapshotStore(baseDirectory: base) })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        let task = Task { await service.handle(open) }
        try await until("factory did not start") { gate.waits.count == 1 }
        let wrongToken = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let maliciousClose = AutomationRequest(version: 1, requestID: UUID(), sessionID: wrongToken, action: .cancel)
        let badClose = await service.handle(maliciousClose)
        try check(badClose.outcome == .failure(AutomationError(code: .sessionNotFound)) && gate.waits.count == 1, "wrong token cannot abort opening")
        service.shutdown()
        let cancelled = await task.value
        try check(cancelled.outcome == .failure(AutomationError(code: .cancelled)), "shutdown cancels open")
        gate.release(page)
        try await until("late owned page cleanup not started") { page.destroyed == 1 }
        let second = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id)))
        try check(second.outcome == .failure(AutomationError(code: .sessionExpired)) && factoryCalls == 1 && storeCalls.value == 0, "late factory cannot reopen or publish")
        destroyGate.release(true); await drain()
        try check(page.destroyed == 1, "late owned cleanup once")
        try check(page.quiesced == 0, "late factory result is not adopted for quiesce")
        let foreign = Page(identity: AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        let foreignService = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { foreign }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let rejected = await foreignService.handle(open)
        try check(rejected.outcome == .failure(AutomationError(code: .targetChanged)) && foreign.destroyed == 0, "foreign factory never destroyed")
        var cancelledTask: Task<AutomationReply, Never>?, entries = 0
        let queued = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: {
            Task { @MainActor in cancelledTask?.cancel() }
            return true
        }, pageFactory: { entries += 1; return Page(identity: target) }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        cancelledTask = Task { await queued.handle(open) }
        guard let t = cancelledTask else { throw Failure(label: "missing cancel task") }
        let queuedReply = await t.value; await drain()
        try check(queuedReply.outcome == .failure(AutomationError(code: .cancelled)) && entries == 0, "cancel flag blocks queued factory")
        let latePage = Page(identity: target), finalGate = Gate<Bool>()
        var permissionCount = 0
        let finalWaitService = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { permissionCount += 1; return permissionCount == 1 ? true : await finalGate.wait() }, pageFactory: { latePage }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let finalWaitTask = Task { await finalWaitService.handle(open) }
        try await until("final permission did not start") { finalGate.waits.count == 1 }
        finalWaitService.shutdown()
        try check(latePage.quiesced == 1 && latePage.destroyed == 0, "opening quiesce synchronous before destroy")
        finalWaitService.shutdown()
        try check(latePage.quiesced == 1, "opening repeated shutdown quiesces once")
        let finalWaitReply = await finalWaitTask.value
        try await until("opening resources not cleaned") { latePage.destroyed == 1 && (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true }
        try check(finalWaitReply.outcome == .failure(AutomationError(code: .cancelled)), "cancel final permission and clean owned resources")
        finalGate.release(true); await drain()
        try check(latePage.destroyed == 1, "late final permission cannot publish or clean twice")
        let driftingPage = Page(identity: target), driftGate = Gate<Bool>()
        var driftPermissions = 0
        let driftingService = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { driftPermissions += 1; return driftPermissions == 1 ? true : await driftGate.wait() }, pageFactory: { driftingPage }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let driftingTask = Task { await driftingService.handle(open) }
        try await until("drifting final permission did not start") { driftGate.waits.count == 1 }
        driftingPage.identity = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        driftingService.shutdown()
        try check(driftingPage.quiesced == 0, "opening identity drift never quiesced")
        _ = await driftingTask.value
        driftGate.release(true); await drain()
        try await until("drifting opening storage cleanup") { (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true }
        try check(driftingPage.destroyed == 0, "opening identity drift never destroyed")
        let fakeClock = FakeClock(), permissionGate = Gate<Bool>(), sleeper = Gate<Void>()
        var overdueFactories = 0
        let overdue = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { await permissionGate.wait() }, pageFactory: { overdueFactories += 1; return Page(identity: target) }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) }, now: { fakeClock.now }, sleepUntil: { _ in await sleeper.wait() })
        let overdueTask = Task { await overdue.handle(open) }
        try await until("overdue reader") { permissionGate.waits.count == 1 }
        fakeClock.now = 30; permissionGate.release(true)
        let overdueReply = await overdueTask.value
        try check(overdueReply.outcome == .failure(AutomationError(code: .timeout)) && overdueFactories == 0, "deadline checked before factory")
        sleeper.release(()); await drain()
        let denied = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { false }, pageFactory: { overdueFactories += 1; return Page(identity: target) }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let deniedReply = await denied.handle(open)
        try check(deniedReply.outcome == .failure(AutomationError(code: .profileNotAllowed)) && overdueFactories == 0, "denied before page factory")
        return checks
    }
    private static func runOwnershipCases(base: URL) async throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws { checks += 1; if !value() { throw Failure(label: name) } }
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target)
        var service: RunnerAutomationService? = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        weak let weakService = service
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        guard let response = await service?.handle(open), case .success(.sessionOpened(let token, _, _)) = response.outcome else { throw Failure(label: "ownership open") }
        let snapshot = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        guard let shot = await service?.handle(snapshot), case .success(.snapshotWritten(let path, _)) = shot.outcome else { throw Failure(label: "ownership screenshot") }
        page.identity = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let read = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState)
        guard let wrong = await service?.handle(read) else { throw Failure(label: "target request") }
        try check(wrong.outcome == .failure(AutomationError(code: .targetChanged)), "wrong target refused")
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try await until("own storage not closed") { !FileManager.default.fileExists(atPath: directory) }
        try check(page.destroyed == 0, "foreign page never destroyed")
        service = nil; await drain()
        try check(weakService == nil, "service releases after shutdown")
        return checks
    }
    private static func runCancelInsidePage(base: URL) async throws -> Int {
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target)
        let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        guard case let .success(.sessionOpened(token, _, _)) = await service.handle(open).outcome else { throw Failure(label: "cancel-inside open") }
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 0, y: 0), viewVersion: 1, count: 1))
        var requestTask: Task<AutomationReply, Never>?
        page.onPerform = { requestTask?.cancel() }
        requestTask = Task { await service.handle(click) }
        guard let task = requestTask else { throw Failure(label: "cancel-inside task") }
        let reply = await task.value
        page.onPerform = nil; service.shutdown()
        try await until("cancel-inside cleanup") { page.destroyed == 1 && (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true }
        guard case .failure = reply.outcome else { throw Failure(label: "cancel flag set inside page must not publish success") }
        return 1
    }
    private static func runOpenIDAliases(base: URL) async throws -> Int {
        var checks = 0
        for useCancel in [false, true] {
            let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
            let page = Page(identity: target)
            let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
            let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
            guard case let .success(.sessionOpened(token, _, _)) = await service.handle(open).outcome else { throw Failure(label: "alias open") }
            let action: AutomationAction = useCancel ? .cancel : .click(point: ViewportPoint(x: 0, y: 0), viewVersion: 1, count: 1)
            let wrongToken = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let wrong = await service.handle(AutomationRequest(version: 1, requestID: open.requestID, sessionID: wrongToken, action: action))
            let malformedToken = await service.handle(AutomationRequest(version: 1, requestID: open.requestID, sessionID: "not-a-token", action: action))
            guard malformedToken.outcome == .failure(AutomationError(code: .sessionNotFound)) else { throw Failure(label: "alias malformed token precedence") }
            checks += 1
            let alias = await service.handle(AutomationRequest(version: 1, requestID: open.requestID, sessionID: token, action: action))
            let capabilityAlias = await service.handle(AutomationRequest(version: 1, requestID: open.requestID, sessionID: nil, action: .capabilities))
            guard capabilityAlias.outcome == .failure(AutomationError(code: .requestIDReused)) else { throw Failure(label: "capability open ID collision") }
            checks += 1
            let calls = page.calls, destroyed = page.destroyed
            let close = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
            _ = await service.handle(close)
            try await until("alias cleanup") { page.destroyed == 1 && (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true }
            guard wrong.outcome == .failure(AutomationError(code: .sessionNotFound)) else { throw Failure(label: "alias wrong token precedence") }
            checks += 1
            guard alias.outcome == .failure(AutomationError(code: .requestIDReused)), calls == 0, destroyed == 0 else { throw Failure(label: "open ID must not dispatch or clean") }
            checks += 1
        }
        return checks
    }
    private static func runShippingGate() async throws -> Int {
        guard !NativeInputPreflight.shippingAdmissionAvailable else { throw Failure(label: "shipping gate unexpectedly open") }
        let id = UUID(), pair = try AutomationChannel.makePair(), child = try AutomationChannel(adopting: pair.child)
        let serving = Task { await RunnerAutomationEntry.serve(profileID: id, channel: child) }
        _ = try await AutomationHandshakeCodec.negotiate(channel: pair.parent, profileID: id, expectedPID: getpid(), timeoutSeconds: 3)
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        try await pair.parent.send(AutomationCodec.encodeRequest(open))
        guard let data = try await pair.parent.receive(), try AutomationCodec.decodeReply(data).outcome == .failure(AutomationError(code: .backendUnavailable)) else { throw Failure(label: "shipping gate did not fail closed") }
        pair.parent.close(); _ = await serving.value
        return 2
    }
    private static func runDroppedOwner(base: URL) async throws -> Int {
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target)
        var owner: RunnerAutomationService? = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        weak let weakOwner = owner
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        guard let opened = await owner?.handle(open), case let .success(.sessionOpened(token, _, _)) = opened.outcome else { throw Failure(label: "drop owner open") }
        let shot = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        guard let snapshot = await owner?.handle(shot), case let .success(.snapshotWritten(path, _)) = snapshot.outcome else { throw Failure(label: "drop owner snapshot") }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        owner = nil
        try await until("dropped owner cleanup") { weakOwner == nil && page.destroyed == 1 && access(directory, F_OK) != 0 }
        return 2
    }
    private static func runHeldCancelAndRepository(base: URL) async throws -> Int {
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target)
        let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        guard case let .success(.sessionOpened(token, _, _)) = await service.handle(open).outcome else { throw Failure(label: "held open") }
        let down = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .mouseDown(point: ViewportPoint(x: 0, y: 0), viewVersion: 1))
        guard case .success(.nativeDelivered) = await service.handle(down).outcome else { throw Failure(label: "held down") }
        let cancel = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .cancel)
        guard case .success(.sessionClosed) = await service.handle(cancel).outcome, page.calls == 1, page.destroyed == 1 else { throw Failure(label: "held cancel no synthetic input") }
        let root = base.appendingPathComponent("profile-" + UUID().uuidString)
        guard mkdir(root.path, 0o700) == 0 else { throw Failure(label: "profile fixture mkdir") }
        defer { _ = unlink(root.appendingPathComponent("profiles.json").path); _ = rmdir(root.path) }
        guard await !RunnerAutomationService.repositoryPermission(profileID: id, root: root) else { throw Failure(label: "missing profile allowed") }
        let repository = SafarierWorkspace(root: root).profiles
        var profile = Profile(id: id, name: "fixture", mode: .ephemeral)
        try repository.insert(profile)
        guard await !RunnerAutomationService.repositoryPermission(profileID: id, root: root) else { throw Failure(label: "revoked profile allowed") }
        profile.allowsBackgroundAutomation = true; try repository.update(profile)
        guard await RunnerAutomationService.repositoryPermission(profileID: id, root: root) else { throw Failure(label: "authorized profile refused") }
        try Data("invalid".utf8).write(to: root.appendingPathComponent("profiles.json"))
        guard await !RunnerAutomationService.repositoryPermission(profileID: id, root: root) else { throw Failure(label: "corrupt profile allowed") }
        return 5
    }
    private static func runLateSnapshot(base: URL) async throws -> Int {
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target), writer = BlockingWriter()
        defer { writer.release() }
        let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base, clock: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }, writer: { writer.write($0, $1, $2) }) })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        guard case let .success(.sessionOpened(token, _, _)) = await service.handle(open).outcome else { throw Failure(label: "late snapshot open") }
        let shot = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        let screenshotTask = Task { await service.handle(shot) }
        try await until("snapshot write did not start") { writer.started }
        let cancel = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .cancel)
        let cancelTask = Task { await service.handle(cancel) }
        let interrupted = await screenshotTask.value
        guard case .failure = interrupted.outcome else { throw Failure(label: "late snapshot must not succeed") }
        let closed = await cancelTask.value
        guard closed.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))), page.destroyed == 1 else { throw Failure(label: "blocked I/O cleanup deadline") }
        guard let path = writer.path else { throw Failure(label: "late snapshot fixture path") }
        writer.release()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try await until("late snapshot directory remained") { access(directory, F_OK) != 0 }
        await drain()
        return 3
    }
    private static func runQuiesceCases(base: URL) async throws -> Int {
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target), destroyGate = Gate<Bool>(), actionGate = Gate<Void>()
        page.destroyGate = destroyGate; page.performGate = actionGate
        let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        guard case let .success(.sessionOpened(token, _, _)) = await service.handle(open).outcome else { throw Failure(label: "quiesce open") }
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .mouseDown(point: ViewportPoint(x: 0, y: 0), viewVersion: 1))
        let action = Task { await service.handle(click) }
        try await until("pending fake action") { actionGate.waits.count == 1 }
        service.shutdown()
        guard page.quiesced == 1 && page.destroyed == 0 else { throw Failure(label: "active synchronous quiesce before destroy") }
        service.shutdown()
        guard page.quiesced == 1 else { throw Failure(label: "active repeated shutdown") }
        actionGate.release(())
        let result = await action.value
        guard case .failure = result.outcome, page.effects == 0 else { throw Failure(label: "pending fake sink after stop") }
        try await until("blocked destroy not started") { page.destroyed == 1 }
        guard page.quiesced == 1 else { throw Failure(label: "stop depends on destroy") }
        destroyGate.release(true)
        try await until("quiesce storage cleanup") { (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true }
        let foreign = Page(identity: target)
        let other = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { foreign }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        guard case .success(.sessionOpened) = await other.handle(open).outcome else { throw Failure(label: "drift open") }
        foreign.identity = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        other.shutdown()
        guard foreign.quiesced == 0 else { throw Failure(label: "drift page quiesced") }
        try await until("drift storage cleanup") { (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true }
        guard foreign.destroyed == 0 else { throw Failure(label: "drift page destroyed") }
        return 7
    }
    private static func runServerCases(base: URL) async throws -> Int {
        let id = UUID(), instance = UUID(), target = AutomationTargetIdentity(profileID: id, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target), destroyGate = Gate<Bool>()
        page.destroyGate = destroyGate
        let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let pair = try AutomationChannel.makePair(), child = try AutomationChannel(adopting: pair.child)
        let server = Task { await service.serve(channel: child, idleSeconds: 3) }
        let response = try await AutomationHandshakeCodec.negotiate(channel: pair.parent, profileID: id, expectedPID: getpid(), timeoutSeconds: 3)
        guard response.runnerInstanceID == instance else { throw Failure(label: "server instance identity") }
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id))
        try await pair.parent.send(AutomationCodec.encodeRequest(request))
        guard let data = try await pair.parent.receive() else { throw Failure(label: "server EOF") }
        let reply = try AutomationCodec.decodeReply(data)
        guard case let .success(.sessionOpened(token, target, _)) = reply.outcome, target.runnerInstanceID == instance else { throw Failure(label: "server open identity") }
        let shot = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        try await pair.parent.send(AutomationCodec.encodeRequest(shot))
        guard let shotData = try await pair.parent.receive(), case let .success(.snapshotWritten(path, _)) = try AutomationCodec.decodeReply(shotData).outcome else { throw Failure(label: "server snapshot") }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        pair.parent.close(); _ = await server.value
        guard page.quiesced == 1 else { throw Failure(label: "socket EOF serve returned before quiesce") }
        try await until("socket destroy started") { page.destroyed == 1 }
        destroyGate.release(true)
        try await until("server cleanup") { page.destroyed == 1 && access(directory, F_OK) != 0 }
        await drain()
        return 4
    }
    public static func run(base: URL) async throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws { checks += 1; if !value() { throw Failure(label: name) } }
        let profileID = UUID(), instance = UUID()
        let target = AutomationTargetIdentity(profileID: profileID, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let page = Page(identity: target)
        let service = RunnerAutomationService(profileID: profileID, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profileID))
        let reply = await service.handle(open)
        guard case let .success(.sessionOpened(token, identity, viewport)) = reply.outcome else { throw Failure(label: "open") }
        try check(identity == target && AutomationSessionToken.isCanonical(token), "bound open")
        let openReplay = await service.handle(open)
        try check(openReplay == reply, "open replay")
        let otherOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profileID))
        let otherOpenReply = await service.handle(otherOpen)
        try check(otherOpenReply.outcome == .failure(AutomationError(code: .sessionBusy)), "only one open receipt")
        var bounded = true
        for _ in 0..<300 {
            let candidate = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profileID))
            if await service.handle(candidate).outcome != .failure(AutomationError(code: .sessionBusy)) { bounded = false }
        }
        try check(bounded, "open flood has one successful receipt")
        let reusedOpen = AutomationRequest(version: 1, requestID: open.requestID, sessionID: nil, action: .openSession(profileID: UUID()))
        let reusedOpenReply = await service.handle(reusedOpen)
        try check(reusedOpenReply.outcome == .failure(AutomationError(code: .requestIDReused)), "open ID payload conflict")
        let wrongToken = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let wrongClose = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: wrongToken, action: .closeSession))
        try check(wrongClose.outcome == .failure(AutomationError(code: .sessionNotFound)) && page.destroyed == 0, "wrong token never cleans")
        let read = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState)
        let state = await service.handle(read)
        if case .success(.stateRead(let value)) = state.outcome { try check(value.target == target && value.viewVersion == viewport.viewVersion, "state") } else { throw Failure(label: "state result") }
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 0, y: 0), viewVersion: viewport.viewVersion, count: 1))
        let clickReply = await service.handle(click)
        try check(page.calls == 1 && clickReply.requestID == click.requestID, "click delivered once")
        let clickReplay = await service.handle(click)
        try check(clickReplay == clickReply && page.calls == 1, "click replay")
        let screenshot = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        let shot = await service.handle(screenshot)
        if case .success(.snapshotWritten(let path, _)) = shot.outcome { try check(FileManager.default.fileExists(atPath: path), "snapshot persisted") } else { throw Failure(label: "snapshot result") }
        let close = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
        let closed = await service.handle(close)
        try check(closed.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: true, terminatedOwnedRunner: false))) && page.destroyed == 1, "owned cleanup")
        let repeatedClose = await service.handle(close)
        try check(repeatedClose == closed && page.destroyed == 1, "same close returns stable receipt")
        let freshClose = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
        let freshClosed = await service.handle(freshClose)
        try check(freshClosed.outcome == closed.outcome && page.destroyed == 1, "new close returns stable cleanup result")
        checks += try await runOpeningCases(base: base)
        checks += try await runOwnershipCases(base: base)
        checks += try await runQuiesceCases(base: base)
        checks += try await runServerCases(base: base)
        checks += try await runHeldCancelAndRepository(base: base)
        checks += try await runLateSnapshot(base: base)
        checks += try await runDroppedOwner(base: base)
        checks += try await runShippingGate()
        checks += try await runCancelInsidePage(base: base)
        checks += try await runOpenIDAliases(base: base)
        return checks
    }
}

