import Foundation
import Darwin
import SafarierCore
#if !MANAGER_STANDALONE
@testable import Safarier
#endif

public enum AutomationManagerCases {
    struct Failure: Error { let label: String }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 100
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ newValue: Double) { lock.lock(); value = max(value, newValue); lock.unlock() }
        func force(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
    }
    final class Scheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var mode = 0
        func set(_ value: Int) { lock.lock(); mode = value; lock.unlock() }
        func read() -> Int { lock.lock(); defer { lock.unlock() }; return mode }
        func sleep(_ deadline: Double) async throws {
            switch read() {
            case 1: throw CancellationError()
            case 2: return
            default:
                let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
    actor ProfileSource {
        let profile: Profile
        var reads = 0, factories = 0
        init(_ profile: Profile) { self.profile = profile }
        func read(_ id: UUID) -> Profile? { reads += 1; return id == profile.id ? profile : nil }
        func spawned() { factories += 1 }
        func counts() -> (Int, Int) { (reads, factories) }
    }
    actor SlowReader {
        let profile: Profile
        var reads = 0
        init(_ profile: Profile) { self.profile = profile }
        func read(_ id: UUID) async -> Profile? {
            reads += 1
            if reads >= 3 { try? await Task.sleep(nanoseconds: 200_000_000) }
            return id == profile.id ? profile : nil
        }
        func count() -> Int { reads }
    }
    actor FakeEndpoint: AutomationManagerEndpoint {
        nonisolated let pid: Int32 = 4321
        nonisolated let runnerInstanceID = UUID()
        nonisolated let ownershipID = UUID()
        let profileID: UUID
        let token = String(repeating: "A", count: 43)
        let window = UUID(), page = UUID()
        var requests = 0, closes = 0
        var failure: AutomationError?
        var requestDelay: UInt64 = 0, closeDelay: UInt64 = 0
        func setDelays(request: UInt64, close: UInt64) { requestDelay = request; closeDelay = close }
        func setFailure(_ error: AutomationError?) { failure = error }
        init(profileID: UUID) { self.profileID = profileID }
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            requests += 1
            if requestDelay > 0 { try? await Task.sleep(nanoseconds: requestDelay) }
            if let failure { throw failure }
            let target = AutomationTargetIdentity(profileID: profileID, runnerInstanceID: runnerInstanceID, windowID: window, pageID: page)
            switch request.action {
            case .openSession:
                let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
                return AutomationReply(requestID: request.requestID, outcome: .success(.sessionOpened(sessionID: token, target: target, viewport: viewport)))
            case .click: return AutomationReply(requestID: request.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
            default: throw AutomationError(code: .invalidRequest)
            }
        }
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? {
            closes += 1
            if closeDelay > 0 { try? await Task.sleep(nanoseconds: closeDelay) }
            return ProcessExit(pid: pid, status: 0, uncaughtSignal: false)
        }
        func counts() -> (Int, Int) { (requests, closes) }
    }
    @MainActor public static func run() async throws -> Int {
        let uid = geteuid()
        let bytes = Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
        let proof = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: bytes)
        let same = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: bytes)
        let reused = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: Data(repeating: 8, count: bytes.count))
        guard proof.sameCaller(as: same), !proof.sameCaller(as: reused) else { throw Failure(label: "opaque caller comparison") }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let manager = AutomationManager.shipping(workspace: SafarierWorkspace(root: root))
        guard manager.pendingWorkCount == 0, !FileManager.default.fileExists(atPath: root.path) else { throw Failure(label: "init IO") }
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: UUID()))
        let reply = await manager.handle(request, role: .manager, proof: proof, currentUID: uid)
        guard reply.outcome == .failure(AutomationError(code: .backgroundLaunchUnverified)), !FileManager.default.fileExists(atPath: root.path) else { throw Failure(label: "closed gate") }
        let profile = Profile(name: "fixture", mode: .ephemeral, allowsBackgroundAutomation: true)
        let endpoint = FakeEndpoint(profileID: profile.id)
        let managed = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime); try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let opened = await managed.handle(open, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let token, _, _)) = opened.outcome, managed.pendingWorkCount == 1 else { throw Failure(label: "open") }
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let first = await managed.handle(click, role: .manager, proof: proof, currentUID: uid)
        let second = await managed.handle(click, role: .manager, proof: proof, currentUID: uid)
        let denied = await managed.handle(click, role: .manager, proof: reused, currentUID: uid)
        let alias = AutomationRequest(version: 1, requestID: click.requestID, sessionID: token, action: .closeSession)
        let aliasReply = await managed.handle(alias, role: .manager, proof: proof, currentUID: uid)
        let wrongToken = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "B", count: 42) + "A", action: .getState)
        let wrongReply = await managed.handle(wrongToken, role: .manager, proof: proof, currentUID: uid)
        let beforeClose = await endpoint.counts()
        guard first == second, denied.outcome == .failure(AutomationError(code: .sessionNotFound)), aliasReply.outcome == .failure(AutomationError(code: .requestIDReused)), wrongReply.outcome == .failure(AutomationError(code: .sessionNotFound)), beforeClose.0 == 2 else { throw Failure(label: "route and replay") }
        let expectedError = AutomationError(code: .timeout, retryable: true, sideEffects: .possible)
        await endpoint.setFailure(expectedError)
        let failedClick = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let failedReply = await managed.handle(failedClick, role: .manager, proof: proof, currentUID: uid)
        guard failedReply.outcome == .failure(expectedError) else { throw Failure(label: "typed error must retain retryability and side effects") }
        await endpoint.setFailure(nil)
        let close = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
        let closed = await managed.handle(close, role: .manager, proof: proof, currentUID: uid)
        let again = await managed.handle(close, role: .manager, proof: proof, currentUID: uid)
        let counts = await endpoint.counts()
        guard closed == again, closed.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: true))), counts.1 == 1, managed.pendingWorkCount == 0 else { throw Failure(label: "close") }
        let clock = Clock(), late = FakeEndpoint(profileID: profile.id)
        let timed = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in try? await Task.sleep(nanoseconds: 200_000_000); return late }, admission: { true }, now: { clock.read() }, sleepUntil: { deadline in try await Task.sleep(nanoseconds: 30_000_000); clock.advance(deadline) })
        let timedOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let start = ProcessInfo.processInfo.systemUptime
        let timedReply = await timed.handle(timedOpen, role: .manager, proof: proof, currentUID: uid)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed < 0.15, timedReply.outcome == .failure(AutomationError(code: .timeout)) else { throw Failure(label: "uncooperative factory deadline") }
        try await Task.sleep(nanoseconds: 250_000_000)
        let lateCounts = await late.counts()
        guard lateCounts.0 == 0, lateCounts.1 == 1 else { throw Failure(label: "late factory disposed") }
        let actionClock = Clock(), slow = FakeEndpoint(profileID: profile.id)
        let actionManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in slow }, admission: { true }, now: { actionClock.read() }, sleepUntil: { deadline in let delta = max(0, deadline - actionClock.read()); try await Task.sleep(nanoseconds: UInt64(delta * 1_000_000)); actionClock.advance(deadline) })
        let slowOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let slowOpened = await actionManager.handle(slowOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let slowToken, _, _)) = slowOpened.outcome else { throw Failure(label: "slow fixture open") }
        await slow.setDelays(request: 200_000_000, close: 0)
        let slowClick = AutomationRequest(version: 1, requestID: UUID(), sessionID: slowToken, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let actionStart = ProcessInfo.processInfo.systemUptime
        let slowResult = await actionManager.handle(slowClick, role: .manager, proof: proof, currentUID: uid)
        guard ProcessInfo.processInfo.systemUptime - actionStart < 0.15, slowResult.outcome == .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible)) else { throw Failure(label: "uncooperative action deadline") }
        let closeClock = Clock(), slowClose = FakeEndpoint(profileID: profile.id)
        let closeManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in slowClose }, admission: { true }, now: { closeClock.read() }, sleepUntil: { deadline in let delta = max(0, deadline - closeClock.read()); try await Task.sleep(nanoseconds: UInt64(delta * 1_000_000)); closeClock.advance(deadline) })
        let closeOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let closeOpened = await closeManager.handle(closeOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let closeToken, _, _)) = closeOpened.outcome else { throw Failure(label: "close fixture open") }
        await slowClose.setDelays(request: 0, close: 200_000_000)
        let closeRequest = AutomationRequest(version: 1, requestID: UUID(), sessionID: closeToken, action: .closeSession)
        let closeStart = ProcessInfo.processInfo.systemUptime
        async let a = closeManager.handle(closeRequest, role: .manager, proof: proof, currentUID: uid)
        async let b = closeManager.handle(closeRequest, role: .manager, proof: proof, currentUID: uid)
        let (aResult, bResult) = await (a, b)
        let unknown = AutomationOutcome.success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false)))
        guard ProcessInfo.processInfo.systemUptime - closeStart < 0.15, aResult.outcome == unknown, bResult.outcome == unknown else { throw Failure(label: "bounded joined close") }
        try await Task.sleep(nanoseconds: 250_000_000)
        let lateClose = await closeManager.handle(closeRequest, role: .manager, proof: proof, currentUID: uid)
        let closeCounts = await slowClose.counts()
        guard lateClose.outcome == unknown, closeCounts.1 == 1 else { throw Failure(label: "late exit must not rewrite receipt") }
        let reader = SlowReader(profile), revokeEndpoint = FakeEndpoint(profileID: profile.id)
        let revokeManager = AutomationManager(profileReader: { id in await reader.read(id) }, humanRunning: { _ in false }, runnerFactory: { _ in revokeEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime); try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) })
        let revokeOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let revokeOpened = await revokeManager.handle(revokeOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let revokeToken, _, _)) = revokeOpened.outcome else { throw Failure(label: "revoke fixture open") }
        let revokeClick = AutomationRequest(version: 1, requestID: UUID(), sessionID: revokeToken, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let pending = Task { await revokeManager.handle(revokeClick, role: .manager, proof: proof, currentUID: uid) }
        for _ in 0..<100 where await reader.count() < 3 { try await Task.sleep(nanoseconds: 1_000_000) }
        let revokeStart = ProcessInfo.processInfo.systemUptime
        revokeManager.profilePermissionsChanged(allowedProfileIDs: [])
        let revokedResult = await pending.value
        guard ProcessInfo.processInfo.systemUptime - revokeStart < 0.15, revokedResult.outcome == .failure(AutomationError(code: .cancelled)) else { throw Failure(label: "revoke cancels pending read") }
        try await Task.sleep(nanoseconds: 220_000_000)
        let revokedCounts = await revokeEndpoint.counts()
        guard revokedCounts.0 == 1, revokedCounts.1 == 1, revokeManager.pendingWorkCount == 0 else { throw Failure(label: "revoked read never dispatches") }
        let leaseClock = Clock(), source = ProfileSource(profile), leaseEndpoint = FakeEndpoint(profileID: profile.id)
        let leaseManager = AutomationManager(profileReader: { id in await source.read(id) }, humanRunning: { _ in false }, runnerFactory: { _ in await source.spawned(); return leaseEndpoint }, admission: { true }, now: { leaseClock.read() }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        let leaseOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let leaseOpened = await leaseManager.handle(leaseOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let leaseToken, _, _)) = leaseOpened.outcome else { throw Failure(label: "lease fixture open") }
        let leaseClick = AutomationRequest(version: 1, requestID: UUID(), sessionID: leaseToken, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let clicked = await leaseManager.handle(leaseClick, role: .manager, proof: proof, currentUID: uid)
        let beforeWrong = await source.counts()
        let reusedAlias = AutomationRequest(version: 1, requestID: leaseOpen.requestID, sessionID: leaseToken, action: .cancel)
        let wrongCaller = await leaseManager.handle(reusedAlias, role: .manager, proof: reused, currentUID: uid)
        let afterWrong = await source.counts()
        guard wrongCaller.outcome == .failure(AutomationError(code: .sessionNotFound)), beforeWrong.0 == afterWrong.0 else { throw Failure(label: "wrong caller before alias or read") }
        leaseClock.advance(100 + AutomationLimits.idleSeconds - 1)
        let historic = await leaseManager.handle(leaseClick, role: .manager, proof: proof, currentUID: uid)
        leaseClock.advance(100 + AutomationLimits.idleSeconds)
        let expired = await leaseManager.handle(leaseClick, role: .manager, proof: proof, currentUID: uid)
        let leaseCounts = await leaseEndpoint.counts()
        guard clicked == historic, expired.outcome == .failure(AutomationError(code: .sessionExpired)), leaseCounts.0 == 2 else { throw Failure(label: "replay does not renew lease same=\(clicked == historic) expired=\(expired.outcome == .failure(AutomationError(code: .sessionExpired))) calls=\(leaseCounts.0)") }
        let lockSource = ProfileSource(profile)
        let locked = AutomationManager(profileReader: { id in await lockSource.read(id) }, humanRunning: { _ in true }, runnerFactory: { _ in await lockSource.spawned(); return leaseEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        let lockedResult = await locked.handle(leaseOpen, role: .manager, proof: proof, currentUID: uid)
        let lockCounts = await lockSource.counts()
        guard lockedResult.outcome == .failure(AutomationError(code: .profileAlreadyRunning)), lockCounts.1 == 0 else { throw Failure(label: "human lock rejects before factory") }
        let cancelSource = ProfileSource(profile), cancelEndpoint = FakeEndpoint(profileID: profile.id)
        let cancelManager = AutomationManager(profileReader: { id in await cancelSource.read(id) }, humanRunning: { _ in false }, runnerFactory: { _ in await cancelSource.spawned(); try? await Task.sleep(nanoseconds: 200_000_000); return cancelEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime); try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) })
        let cancelOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let opening = Task { await cancelManager.handle(cancelOpen, role: .manager, proof: proof, currentUID: uid) }
        for _ in 0..<100 where await cancelSource.counts().1 == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        opening.cancel()
        let cancelled = await opening.value
        guard cancelled.outcome == .failure(AutomationError(code: .cancelled)) else { throw Failure(label: "open task cancellation") }
        try await Task.sleep(nanoseconds: 250_000_000)
        let cancelCounts = await cancelEndpoint.counts()
        guard cancelCounts.0 == 0, cancelCounts.1 == 1 else { throw Failure(label: "cancelled late factory disposed once") }
        let badEndpoint = FakeEndpoint(profileID: profile.id)
        let openError = AutomationError(code: .timeout, retryable: true, sideEffects: .possible)
        await badEndpoint.setFailure(openError)
        let badManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in badEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime); try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) })
        let badOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let badResult = await badManager.handle(badOpen, role: .manager, proof: proof, currentUID: uid)
        let badRetry = await badManager.handle(badOpen, role: .manager, proof: proof, currentUID: uid)
        let badCounts = await badEndpoint.counts()
        guard badResult.outcome == .failure(openError), badRetry == badResult, badCounts.0 == 1, badCounts.1 == 1 else { throw Failure(label: "open typed error is stable") }
        let throwing = Scheduler(), throwEndpoint = FakeEndpoint(profileID: profile.id)
        let throwManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in throwEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in try await throwing.sleep(deadline) })
        let throwOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let throwOpened = await throwManager.handle(throwOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let throwToken, _, _)) = throwOpened.outcome else { throw Failure(label: "throw sleeper fixture open") }
        await throwEndpoint.setDelays(request: 0, close: 200_000_000)
        throwing.set(1)
        let throwClose = AutomationRequest(version: 1, requestID: UUID(), sessionID: throwToken, action: .closeSession)
        let throwReceipt = await throwManager.handle(throwClose, role: .manager, proof: proof, currentUID: uid)
        try await Task.sleep(nanoseconds: 20_000_000)
        let throwCounts = await throwEndpoint.counts()
        guard throwReceipt.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))), throwCounts.1 == 1 else { throw Failure(label: "throwing scheduler must still attempt close") }
        let early = Scheduler(), earlyEndpoint = FakeEndpoint(profileID: profile.id)
        let earlyManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in earlyEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in try await early.sleep(deadline) })
        let earlyOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let earlyOpened = await earlyManager.handle(earlyOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let earlyToken, _, _)) = earlyOpened.outcome else { throw Failure(label: "early sleeper fixture open") }
        await earlyEndpoint.setDelays(request: 200_000_000, close: 0)
        early.set(2)
        let earlyState = AutomationRequest(version: 1, requestID: UUID(), sessionID: earlyToken, action: .getState)
        let earlyTask = Task { await earlyManager.handle(earlyState, role: .manager, proof: proof, currentUID: uid) }
        try await Task.sleep(nanoseconds: 50_000_000)
        earlyTask.cancel()
        let earlyResult = await earlyTask.value
        guard earlyResult.outcome == .failure(AutomationError(code: .timeout)) else { throw Failure(label: "early return must fail closed, not spin") }
        for invalid in [99.0, Double.nan] {
            let badClock = Clock(), clockEndpoint = FakeEndpoint(profileID: profile.id)
            let clockManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in clockEndpoint }, admission: { true }, now: { badClock.read() }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
            let clockOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
            let clockOpened = await clockManager.handle(clockOpen, role: .manager, proof: proof, currentUID: uid)
            guard case .success(.sessionOpened(let clockToken, _, _)) = clockOpened.outcome else { throw Failure(label: "clock fixture open") }
            badClock.force(invalid)
            let clockClick = AutomationRequest(version: 1, requestID: UUID(), sessionID: clockToken, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
            let clockReply = await clockManager.handle(clockClick, role: .manager, proof: proof, currentUID: uid)
            try await Task.sleep(nanoseconds: 20_000_000)
            let clockCounts = await clockEndpoint.counts()
            guard case .failure = clockReply.outcome, clockCounts.0 == 1, clockCounts.1 == 1 else { throw Failure(label: "invalid clock must close without dispatch") }
        }
        let droppedEndpoint = FakeEndpoint(profileID: profile.id), dropSleeper = Scheduler()
        var dropManager: AutomationManager? = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in droppedEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in try await dropSleeper.sleep(deadline) })
        let dropOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let dropResult = await dropManager!.handle(dropOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened) = dropResult.outcome else { throw Failure(label: "drop fixture open") }
        weak let weakManager = dropManager
        dropManager = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        let dropCounts = await droppedEndpoint.counts()
        guard weakManager == nil, dropCounts.1 == 1 else { throw Failure(label: "drop owner releases timer and closes endpoint") }
        var replayFailures: [String] = []
        let fullEndpoint = FakeEndpoint(profileID: profile.id)
        let fullManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in fullEndpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime); try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) })
        let fullOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let fullOpened = await fullManager.handle(fullOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let fullToken, _, _)) = fullOpened.outcome else { throw Failure(label: "full replay fixture open") }
        var usedID = UUID()
        for index in 0..<AutomationLimits.replayEntries {
            let id = UUID(); if index == 0 { usedID = id }
            let item = AutomationRequest(version: 1, requestID: id, sessionID: fullToken, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
            guard case .success(.nativeDelivered) = await fullManager.handle(item, role: .manager, proof: proof, currentUID: uid).outcome else { throw Failure(label: "fill replay window") }
        }
        let conflict = AutomationRequest(version: 1, requestID: usedID, sessionID: fullToken, action: .cancel)
        let wrongCallerConflict = await fullManager.handle(conflict, role: .manager, proof: reused, currentUID: uid)
        let conflictReply = await fullManager.handle(conflict, role: .manager, proof: proof, currentUID: uid)
        let fullCancel = AutomationRequest(version: 1, requestID: UUID(), sessionID: fullToken, action: .cancel)
        let fullClosed = await fullManager.handle(fullCancel, role: .manager, proof: proof, currentUID: uid)
        let fullRepeat = await fullManager.handle(fullCancel, role: .manager, proof: proof, currentUID: uid)
        let fullCounts = await fullEndpoint.counts()
        if wrongCallerConflict.outcome != .failure(AutomationError(code: .sessionNotFound)) || conflictReply.outcome != .failure(AutomationError(code: .requestIDReused)) || fullClosed.outcome != .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: true))) || fullRepeat != fullClosed || fullCounts.1 != 1 { replayFailures.append("full replay must not block owned cancel or hide conflicts") }
        let slowClock = Clock(), slowOpenEndpoint = FakeEndpoint(profileID: profile.id)
        let slowOpenManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in slowClock.advance(100 + AutomationLimits.idleSeconds - 5); return slowOpenEndpoint }, admission: { true }, now: { slowClock.read() }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        let slowOpenRequest = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let slowOpenResult = await slowOpenManager.handle(slowOpenRequest, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let slowOpenToken, _, _)) = slowOpenResult.outcome else { throw Failure(label: "slow startup fixture open") }
        slowClock.advance(100 + AutomationLimits.idleSeconds + 4)
        let afterStartup = AutomationRequest(version: 1, requestID: UUID(), sessionID: slowOpenToken, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let afterStartupResult = await slowOpenManager.handle(afterStartup, role: .manager, proof: proof, currentUID: uid)
        if case .success(.nativeDelivered) = afterStartupResult.outcome { } else { replayFailures.append("slow open must start session replay at binding") }
        let expiredClock = Clock(), expiredEndpoint = FakeEndpoint(profileID: profile.id)
        let expiredManager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in expiredEndpoint }, admission: { true }, now: { expiredClock.read() }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        let expiredOpen = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let expiredOpened = await expiredManager.handle(expiredOpen, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let expiredToken, _, _)) = expiredOpened.outcome else { throw Failure(label: "expired replay fixture open") }
        let expiredClick = AutomationRequest(version: 1, requestID: UUID(), sessionID: expiredToken, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        _ = await expiredManager.handle(expiredClick, role: .manager, proof: proof, currentUID: uid)
        expiredClock.advance(100 + AutomationLimits.idleSeconds + 1)
        let expiredAlias = AutomationRequest(version: 1, requestID: expiredClick.requestID, sessionID: expiredToken, action: .cancel)
        let expiredAliasResult = await expiredManager.handle(expiredAlias, role: .manager, proof: proof, currentUID: uid)
        let expiredCancel = AutomationRequest(version: 1, requestID: UUID(), sessionID: expiredToken, action: .cancel)
        let expiredCloseResult = await expiredManager.handle(expiredCancel, role: .manager, proof: proof, currentUID: uid)
        let expiredCounts = await expiredEndpoint.counts()
        if expiredAliasResult.outcome != .failure(AutomationError(code: .requestIDReused)) || expiredCloseResult.outcome != .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: true))) || expiredCounts.1 != 1 { replayFailures.append("expired replay must preserve conflicts and allow owned cancel") }
        if !replayFailures.isEmpty { throw Failure(label: replayFailures.joined(separator: "; ")) }
        return 21
    }
}
