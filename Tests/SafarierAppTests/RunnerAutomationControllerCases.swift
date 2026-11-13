import Foundation
import SafarierCore
#if !RUNNER_CONTROLLER_STANDALONE
@testable import Safarier
#endif

@MainActor public enum RunnerAutomationControllerCases {
    struct Failure: Error { let label: String }
    @MainActor final class Counts { var permissions = 0; var targets = 0; var sink = 0; var cleanup = 0 }
    @MainActor final class VirtualClock {
        struct Wait { let deadline: Double; let continuation: CheckedContinuation<Void, Never> }
        var instant = 0.0
        var waits: [Wait] = []
        func sleep(_ deadline: Double) async { await withCheckedContinuation { waits.append(Wait(deadline: deadline, continuation: $0)) } }
        func advance(_ value: Double) {
            instant = value
            let ready = waits.filter { $0.deadline <= value }
            waits.removeAll { $0.deadline <= value }
            for wait in ready { wait.continuation.resume() }
        }
    }
    @MainActor final class Gate<T> {
        var waits: [CheckedContinuation<T, Never>] = []
        func wait() async -> T { await withCheckedContinuation { waits.append($0) } }
        func release(_ value: T) { let all = waits; waits = []; for continuation in all { continuation.resume(returning: value) } }
    }
    static func drain() async { for _ in 0..<80 { await Task.yield() } }
    static func waitUntil(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100_000 { if condition() { return }; await Task.yield() }
        throw Failure(label: label)
    }
    enum SleepFailure: Error { case broken }
    private static func runInitial() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        _ = machine.bind(target: target, viewport: viewport, at: 0)
        let counts = Counts()
        let controller = RunnerAutomationController(machine: machine, permissionReader: { counts.permissions += 1; return true }, targetReader: { counts.targets += 1; return target }, actionSink: { request, _ in counts.sink += 1; return AutomationReply(requestID: request.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1))) }, cleanupSink: { _, _, _ in counts.cleanup += 1; return CleanupReceipt(cleaned: true, terminatedOwnedRunner: false) }, now: { 0 }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let result = await controller.handle(click)
        try check(result.requestID == click.requestID && counts.sink == 1, "click completion")
        let again = await controller.handle(click)
        try check(again == result && counts.sink == 1, "idempotent replay")
        let bad = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "A", count: 42), action: .getState)
        let prior = counts.permissions
        let denied = await controller.handle(bad)
        try check(denied.outcome == .failure(AutomationError(code: .sessionNotFound)) && counts.permissions == prior, "wrong token no read")
        let countAfterWrong = counts.permissions
        let invalid = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .move(point: ViewportPoint(x: .nan, y: 0), viewVersion: 1))
        let invalidReply = await controller.handle(invalid)
        try check(invalidReply.outcome == .failure(AutomationError(code: .invalidRequest)) && counts.permissions == countAfterWrong, "invalid request no permission read")
        controller.shutdown()
        return checks
    }
    private static func runFixture0() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Permission never returns until explicitly released; cancellation must not wait.
        let clock1 = VirtualClock(), authGate = Gate<Bool>(), actionCount1 = Counts()
        let m1 = try fresh(clock1)
        let c1 = RunnerAutomationController(machine: m1, permissionReader: { actionCount1.permissions += 1; return await authGate.wait() }, targetReader: { actionCount1.targets += 1; return target }, actionSink: { r, _ in actionCount1.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in actionCount1.cleanup += 1; return CleanupReceipt(cleaned: true, terminatedOwnedRunner: false) }, now: { clock1.instant }, sleepUntil: { await clock1.sleep($0) })
        let nav = makeRequest(.navigate(url: URL(string: "https://example.com/")!))
        let pendingAuth = Task { await c1.handle(nav) }
        await drain()
        try check(authGate.waits.count == 1, "permission pending")
        let close = makeRequest(.cancel)
        let closeResult = await c1.handle(close)
        let authResult = await pendingAuth.value
        try check(closeResult.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: true, terminatedOwnedRunner: false))) && authResult.outcome == .failure(AutomationError(code: .cancelled)), "cancel bypasses stuck permission")
        authGate.release(true); await drain()
        try check(actionCount1.sink == 0 && actionCount1.cleanup == 1 && m1.state == .closed, "late permission ignored")
        clock1.advance(100); await drain()
        return checks
    }
    private static func runFixture1() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // The second authorization recheck fails after the first succeeds.
        let clock2 = VirtualClock(), counts2 = Counts(), m2 = try fresh(clock2)
        let c2 = RunnerAutomationController(machine: m2, permissionReader: { counts2.permissions += 1; return counts2.permissions == 1 }, targetReader: { counts2.targets += 1; return target }, actionSink: { r, _ in counts2.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in counts2.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock2.instant }, sleepUntil: { await clock2.sleep($0) })
        let refused = await c2.handle(click)
        try check(refused.outcome == .failure(AutomationError(code: .profileNotAllowed)) && counts2.permissions == 2 && counts2.sink == 0, "recheck permission before sink")
        await drain(); try check(counts2.cleanup == 1 && m2.state == .closed, "revoke cleanup")
        clock2.advance(100); await drain()
        return checks
    }
    private static func runFixture2() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let delivered = AutomationReply(requestID: click.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Concurrent duplicate IDs get distinct invocation outcomes; sink executes once.
        let clock3 = VirtualClock(), actionGate = Gate<AutomationReply>(), counts3 = Counts(), m3 = try fresh(clock3)
        let c3 = RunnerAutomationController(machine: m3, permissionReader: { true }, targetReader: { target }, actionSink: { _, _ in counts3.sink += 1; return await actionGate.wait() }, cleanupSink: { _, _, _ in counts3.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock3.instant }, sleepUntil: { await clock3.sleep($0) })
        let pendingClick = Task { await c3.handle(click) }; await drain()
        try check(actionGate.waits.count == 1, "click pending")
        let duplicate = await c3.handle(click)
        try check(duplicate.outcome == .failure(AutomationError(code: .sessionBusy)) && counts3.sink == 1, "duplicate inflight rejected")
        actionGate.release(delivered); let firstClick = await pendingClick.value
        let replayed = await c3.handle(click)
        try check(firstClick == delivered && replayed == delivered && counts3.sink == 1, "single sink then replay")
        c3.shutdown(); await drain(); clock3.advance(100); await drain()
        return checks
    }
    private static func runFixture3() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Exact hold deadline is driven by the virtual timer, not a success sleep.
        let clock4 = VirtualClock(), cleanupGate = Gate<CleanupReceipt>(), counts4 = Counts(), m4 = try fresh(clock4)
        let c4 = RunnerAutomationController(machine: m4, permissionReader: { true }, targetReader: { target }, actionSink: { r, _ in counts4.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 1, viewVersion: 1))) }, cleanupSink: { _, _, _ in counts4.cleanup += 1; return await cleanupGate.wait() }, now: { clock4.instant }, sleepUntil: { await clock4.sleep($0) })
        let down = makeRequest(.mouseDown(point: ViewportPoint(x: 1, y: 1), viewVersion: 1))
        _ = await c4.handle(down); await drain()
        try check(m4.state == .held, "held after down")
        clock4.advance(4.99); await drain(); try check(m4.state == .held && counts4.cleanup == 0, "hold before deadline")
        clock4.advance(5); try await waitUntil("hold timer did not fire") { m4.state == .stopping && counts4.cleanup == 1 }
        try check(m4.state == .stopping && counts4.cleanup == 1, "hold exact deadline")
        try await waitUntil("cleanup timer not installed") { clock4.waits.contains { $0.deadline == 7 } }
        clock4.advance(7); try await waitUntil("cleanup timer did not fire") { m4.state == .closed }
        try check(m4.state == .closed, "cleanup exact deadline")
        cleanupGate.release(CleanupReceipt(cleaned: true, terminatedOwnedRunner: true)); await drain()
        let afterTimeout = await c4.handle(makeRequest(.closeSession))
        try check(afterTimeout.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))), "late cleanup cannot claim success")
        clock4.advance(100); await drain()
        return checks
    }
    private static func runFixture4() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Deadline generation prevents a cancelled old timer from expiring a renewed lease.
        let clock5 = VirtualClock(), counts5 = Counts(), m5 = try fresh(clock5)
        let c5 = RunnerAutomationController(machine: m5, permissionReader: { true }, targetReader: { target }, actionSink: { r, _ in
            counts5.sink += 1
            let value = AutomationState(target: target, url: nil, loading: false, sessionState: .ready, viewVersion: 1)
            return AutomationReply(requestID: r.requestID, outcome: .success(.stateRead(value)))
        }, cleanupSink: { _, _, _ in counts5.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock5.instant }, sleepUntil: { await clock5.sleep($0) })
        await drain(); clock5.advance(10); await drain(); _ = await c5.handle(makeRequest(.getState)); await drain()
        clock5.advance(30); await drain(); try check(m5.state == .ready && counts5.cleanup == 0, "stale timer ignored")
        clock5.advance(40); await drain(); try check(counts5.cleanup == 1, "renewed lease exact deadline")
        clock5.advance(100); await drain()
        return checks
    }
    private static func runFixture5() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Wrong target on the second read stops before the sink.
        let clock6 = VirtualClock(), counts6 = Counts(), m6 = try fresh(clock6)
        let wrongTarget = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let c6 = RunnerAutomationController(machine: m6, permissionReader: { true }, targetReader: { counts6.targets += 1; return counts6.targets == 1 ? target : wrongTarget }, actionSink: { r, _ in counts6.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in counts6.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock6.instant }, sleepUntil: { await clock6.sleep($0) })
        let wrongTargetResult = await c6.handle(click)
        try check(wrongTargetResult.outcome == .failure(AutomationError(code: .targetChanged)) && counts6.sink == 0, "recheck target before sink")
        clock6.advance(100); await drain()
        return checks
    }
    private static func runFixture6() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Window close maps to terminal target change, not an ordinary block.
        let clock7 = VirtualClock(), counts7 = Counts(), m7 = try fresh(clock7)
        var lastReason: AutomationCloseReason?
        let c7 = RunnerAutomationController(machine: m7, permissionReader: { true }, targetReader: { target }, actionSink: { r, _ in counts7.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, reason, _ in counts7.cleanup += 1; lastReason = reason; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock7.instant }, sleepUntil: { await clock7.sleep($0) })
        c7.blockUI(.windowClose); await drain()
        try check(counts7.cleanup == 1 && lastReason == .targetChanged && m7.state == .closed, "window close shuts down")
        clock7.advance(100); await drain()
        return checks
    }
    private static func runFixture7() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // A queued shutdown can run between the final read and the queued sink task.
        let raceClock = VirtualClock(), raceCounts = Counts(), raceMachine = try fresh(raceClock)
        var raceController: RunnerAutomationController?
        raceController = RunnerAutomationController(machine: raceMachine, permissionReader: { true }, targetReader: {
            raceCounts.targets += 1
            if raceCounts.targets == 2 { Task { @MainActor in raceController?.shutdown() } }
            return target
        }, actionSink: { r, _ in raceCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in raceCounts.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { raceClock.instant }, sleepUntil: { await raceClock.sleep($0) })
        guard let rc = raceController else { throw Failure(label: "race controller") }
        let raceReply = await rc.handle(click); await drain()
        if case .failure(let e) = raceReply.outcome { try check(e.sideEffects == .none, "pre-sink cancellation has no side effects") } else { throw Failure(label: "race response") }
        try check(raceCounts.sink == 0, "queued sink not invoked after shutdown")
        raceClock.advance(100); await drain(); raceController = nil
        return checks
    }
    private static func runFixture8() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Caller cancellation before its task starts cannot enter a reader.
        let preClock = VirtualClock(), preCounts = Counts(), preMachine = try fresh(preClock)
        let preController = RunnerAutomationController(machine: preMachine, permissionReader: { preCounts.permissions += 1; return true }, targetReader: { target }, actionSink: { r, _ in preCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { preClock.instant }, sleepUntil: { await preClock.sleep($0) })
        let preTask = Task { await preController.handle(click) }; preTask.cancel()
        let preReply = await preTask.value
        try check(preReply.outcome == .failure(AutomationError(code: .cancelled)) && preCounts.permissions == 0 && preCounts.sink == 0, "cancel before task install")
        preController.shutdown(); await drain(); preClock.advance(100); await drain()
        return checks
    }
    private static func runFixture9() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let delivered = AutomationReply(requestID: click.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Task cancellation after sink dispatch must shut down, and late sink must not revive.
        let cancelClock = VirtualClock(), cancelCounts = Counts(), cancelGate = Gate<AutomationReply>(), cancelMachine = try fresh(cancelClock)
        let cancelController = RunnerAutomationController(machine: cancelMachine, permissionReader: { true }, targetReader: { target }, actionSink: { _, _ in cancelCounts.sink += 1; return await cancelGate.wait() }, cleanupSink: { _, _, _ in cancelCounts.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { cancelClock.instant }, sleepUntil: { await cancelClock.sleep($0) })
        let cancelTask = Task { await cancelController.handle(click) }; await drain()
        try check(cancelGate.waits.count == 1, "inflight sink started")
        cancelTask.cancel(); let cancelledReply = await cancelTask.value
        try check(cancelledReply.outcome == .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible)), "inflight cancellation possible")
        cancelGate.release(delivered); await drain()
        try check(cancelCounts.cleanup == 1 && cancelMachine.state == .closed, "late sink cannot revive")
        cancelClock.advance(100); await drain()
        return checks
    }
    private static func runFixture10() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // A pending target lookup is also settled on close, without waiting for the reader.
        let authClock = VirtualClock(), targetGate = Gate<AutomationTargetIdentity>(), authCounts = Counts(), authMachine = try fresh(authClock)
        let authController = RunnerAutomationController(machine: authMachine, permissionReader: { true }, targetReader: { authCounts.targets += 1; return await targetGate.wait() }, actionSink: { r, _ in authCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in authCounts.cleanup += 1; return CleanupReceipt(cleaned: true, terminatedOwnedRunner: false) }, now: { authClock.instant }, sleepUntil: { await authClock.sleep($0) })
        let targetWait = Task { await authController.handle(click) }; await drain()
        try check(targetGate.waits.count == 1, "target reader pending")
        _ = await authController.handle(makeRequest(.closeSession)); let targetWaitReply = await targetWait.value
        targetGate.release(target); await drain()
        try check(targetWaitReply.outcome == .failure(AutomationError(code: .cancelled)) && authCounts.sink == 0 && authMachine.state == .closed, "close settles preauthorization")
        authClock.advance(100); await drain()
        return checks
    }
    private static func runFixture11() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Idle deadline settles stuck authorization, then cleanup deadline bounds response.
        let leaseClock = VirtualClock(), leaseAuth = Gate<Bool>(), leaseCleanup = Gate<CleanupReceipt>(), leaseCounts = Counts(), leaseMachine = try fresh(leaseClock)
        let leaseController = RunnerAutomationController(machine: leaseMachine, permissionReader: { leaseCounts.permissions += 1; return await leaseAuth.wait() }, targetReader: { target }, actionSink: { r, _ in leaseCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in leaseCounts.cleanup += 1; return await leaseCleanup.wait() }, now: { leaseClock.instant }, sleepUntil: { await leaseClock.sleep($0) })
        let leaseCall = Task { await leaseController.handle(click) }; await drain()
        try await waitUntil("lease timer not installed") { leaseClock.waits.contains { $0.deadline == 30 } }
        leaseClock.advance(30); try await waitUntil("lease did not stop") { leaseMachine.state == .stopping && leaseCounts.cleanup == 1 }; let leaseReply = await leaseCall.value
        try check(leaseReply.outcome == .failure(AutomationError(code: .cancelled)) && leaseCounts.cleanup == 1 && leaseMachine.state == .stopping, "lease settles pending authorization")
        try await waitUntil("lease cleanup timer not installed") { leaseClock.waits.contains { $0.deadline == 32 } }
        leaseClock.advance(32); try await waitUntil("lease cleanup did not close") { leaseMachine.state == .closed }
        leaseAuth.release(true); leaseCleanup.release(CleanupReceipt(cleaned: true, terminatedOwnedRunner: true)); await drain()
        try check(leaseMachine.state == .closed && leaseCounts.sink == 0, "late authorization and cleanup ignored")
        leaseClock.advance(100); await drain()
        return checks
    }
    private static func runFixture12() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        let delivered = AutomationReply(requestID: click.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Foreign callback cannot complete another controller's same-request-ID ticket.
        let crossClock = VirtualClock(), gateA = Gate<AutomationReply>(), gateB = Gate<AutomationReply>()
        let crossA = try fresh(crossClock), crossB = try fresh(crossClock), crossCounts = Counts()
        let crossControllerA = RunnerAutomationController(machine: crossA, permissionReader: { true }, targetReader: { target }, actionSink: { _, _ in crossCounts.sink += 1; return await gateA.wait() }, cleanupSink: { _, _, _ in CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { crossClock.instant }, sleepUntil: { await crossClock.sleep($0) })
        let crossControllerB = RunnerAutomationController(machine: crossB, permissionReader: { true }, targetReader: { target }, actionSink: { _, _ in crossCounts.sink += 1; return await gateB.wait() }, cleanupSink: { _, _, _ in CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { crossClock.instant }, sleepUntil: { await crossClock.sleep($0) })
        let taskA = Task { await crossControllerA.handle(click) }, taskB = Task { await crossControllerB.handle(click) }; await drain()
        try check(gateA.waits.count == 1 && gateB.waits.count == 1 && crossCounts.sink == 2, "two session sinks pending")
        crossControllerA.shutdown(); _ = await taskA.value
        gateA.release(delivered); await drain()
        let crossDuplicate = await crossControllerB.handle(click)
        try check(crossDuplicate.outcome == .failure(AutomationError(code: .sessionBusy)), "foreign late callback leaves other pending")
        gateB.release(delivered); let crossResult = await taskB.value
        try check(crossResult == delivered, "own session callback completes")
        crossControllerB.shutdown(); await drain(); crossClock.advance(100); await drain()
        return checks
    }
    private static func runFixture13() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Closure workers must not retain the controller through a stuck reader.
        let lifeClock = VirtualClock(), lifeGate = Gate<Bool>(), lifeMachine = try fresh(lifeClock)
        var lifeController: RunnerAutomationController? = RunnerAutomationController(machine: lifeMachine, permissionReader: { await lifeGate.wait() }, targetReader: { target }, actionSink: { r, _ in AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { lifeClock.instant }, sleepUntil: { await lifeClock.sleep($0) })
        weak let weakLife = lifeController
        let lifeTask = Task { [weak lifeController] in await lifeController?.handle(click) }; await drain()
        lifeController?.shutdown(); _ = await lifeTask.value; await drain()
        lifeController = nil; await drain()
        try check(weakLife == nil, "stuck authorization does not retain controller")
        lifeGate.release(true); lifeClock.advance(100); await drain()
        return checks
    }
    private static func runFixture14() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Closed calls must not wait on a permission reader that will never return.
        let closedClock = VirtualClock(), closedGate = Gate<Bool>(), closedCounts = Counts(), closedMachine = try fresh(closedClock)
        let closedController = RunnerAutomationController(machine: closedMachine, permissionReader: { closedCounts.permissions += 1; return await closedGate.wait() }, targetReader: { target }, actionSink: { r, _ in AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { closedClock.instant }, sleepUntil: { await closedClock.sleep($0) })
        closedController.shutdown(); await drain()
        @MainActor final class ReplyBox { var value: AutomationReply? }
        let closedBox = ReplyBox()
        let closedTask = Task { closedBox.value = await closedController.handle(makeRequest(.getState)) }
        await drain()
        try check(closedBox.value?.outcome == .failure(AutomationError(code: .sessionExpired)) && closedCounts.permissions == 0, "closed request bypasses stuck reader")
        closedGate.release(true); await closedTask.value; closedClock.advance(100); await drain()
        return checks
    }
    private static func runFixture15() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // A current-generation sleeper error cannot leave an active session alive.
        let failedClock = VirtualClock(), failedMachine = try fresh(failedClock), failedCounts = Counts(), failedCleanup = Gate<CleanupReceipt>()
        let failedController = RunnerAutomationController(machine: failedMachine, permissionReader: { true }, targetReader: { target }, actionSink: { r, _ in failedCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in failedCounts.cleanup += 1; return await failedCleanup.wait() }, now: { failedClock.instant }, sleepUntil: { _ in throw SleepFailure.broken })
        await drain()
        try check(failedCounts.cleanup == 1 && failedMachine.state == .closed && failedCounts.sink == 0, "sleeper failure cleans once and closes")
        let failedClose = await failedController.handle(makeRequest(.closeSession))
        try check(failedClose.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))), "scheduler failure does not invent cleanup")
        failedCleanup.release(CleanupReceipt(cleaned: true, terminatedOwnedRunner: true)); await drain()
        let failedClose2 = await failedController.handle(makeRequest(.closeSession))
        try check(failedClose2.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))), "late failed-scheduler cleanup ignored")
        return checks
    }
    private static func runFixture16() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // CancellationError from the current sleeper is an error, not an old-timer cancellation.
        let cancelSleepClock = VirtualClock(), cancelSleepMachine = try fresh(cancelSleepClock), cancelSleepCounts = Counts(), cancelSleepGate = Gate<Void>(), blockedAuth = Gate<Bool>(), cancelSleepCleanup = Gate<CleanupReceipt>()
        let cancelSleepController = RunnerAutomationController(machine: cancelSleepMachine, permissionReader: { cancelSleepCounts.permissions += 1; return await blockedAuth.wait() }, targetReader: { target }, actionSink: { r, _ in cancelSleepCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in cancelSleepCounts.cleanup += 1; return await cancelSleepCleanup.wait() }, now: { cancelSleepClock.instant }, sleepUntil: { _ in await cancelSleepGate.wait(); throw CancellationError() })
        let blockedTask = Task { await cancelSleepController.handle(click) }; await drain()
        try check(blockedAuth.waits.count == 1 && cancelSleepGate.waits.count == 1, "pending auth and sleeper")
        cancelSleepGate.release(()); await drain()
        let blockedReply = await blockedTask.value
        try check(blockedReply.outcome == .failure(AutomationError(code: .cancelled)) && cancelSleepCounts.cleanup == 1 && cancelSleepMachine.state == .closed, "current CancellationError fails closed")
        blockedAuth.release(true); cancelSleepCleanup.release(CleanupReceipt(cleaned: true, terminatedOwnedRunner: true)); await drain()
        let noInvented = await cancelSleepController.handle(makeRequest(.closeSession))
        try check(noInvented.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))) && cancelSleepCounts.sink == 0, "scheduler error late replies ignored")
        return checks
    }
    private static func runFixture17() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Current timer failure while cleanup is already awaiting also settles the close.
        let stopClock = VirtualClock(), stopMachine = try fresh(stopClock), stopCounts = Counts(), stopSleep = Gate<Void>(), stopCleanup = Gate<CleanupReceipt>()
        let stopController = RunnerAutomationController(machine: stopMachine, permissionReader: { true }, targetReader: { target }, actionSink: { r, _ in AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in stopCounts.cleanup += 1; return await stopCleanup.wait() }, now: { stopClock.instant }, sleepUntil: { _ in await stopSleep.wait(); throw SleepFailure.broken })
        await drain()
        let stopTask = Task { await stopController.handle(makeRequest(.closeSession)) }; await drain()
        try check(stopCounts.cleanup == 1 && stopMachine.state == .stopping && stopSleep.waits.count >= 2, "cleanup started with active timer")
        stopSleep.release(()); await drain(); let stopResult = await stopTask.value
        try check(stopResult.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))) && stopMachine.state == .closed && stopCounts.cleanup == 1, "timer failure while cleanup settles once")
        stopCleanup.release(CleanupReceipt(cleaned: true, terminatedOwnedRunner: true)); await drain()
        return checks
    }
    private static func runFixture18() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // The second target lookup suspends while permission is revoked.
        let flipClock = VirtualClock(), flipMachine = try fresh(flipClock), flipCounts = Counts(), flipTarget = Gate<AutomationTargetIdentity>()
        var permissionStillAllowed = true
        let flipController = RunnerAutomationController(machine: flipMachine, permissionReader: { flipCounts.permissions += 1; return permissionStillAllowed }, targetReader: { flipCounts.targets += 1; return flipCounts.targets == 2 ? await flipTarget.wait() : target }, actionSink: { r, _ in flipCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in flipCounts.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { flipClock.instant }, sleepUntil: { await flipClock.sleep($0) })
        let flipTask = Task { await flipController.handle(click) }
        try await waitUntil("post-target read did not start") { flipTarget.waits.count == 1 }
        permissionStillAllowed = false; flipTarget.release(target)
        let flipReply = await flipTask.value
        try check(flipCounts.sink == 0 && flipReply.outcome == .failure(AutomationError(code: .profileNotAllowed)), "permission reread after target suspension")
        await drain(); try check(flipCounts.cleanup == 1, "revocation after target cleans")
        flipClock.advance(100); await drain()
        return checks
    }
    private static func runFixture19() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Authorization is bounded; a reducing close bypasses a full registry.
        let capClock = VirtualClock(), capMachine = try fresh(capClock), capGate = Gate<Bool>(), capCounts = Counts()
        let capController = RunnerAutomationController(machine: capMachine, permissionReader: { capCounts.permissions += 1; return await capGate.wait() }, targetReader: { target }, actionSink: { r, _ in capCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in capCounts.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { capClock.instant }, sleepUntil: { await capClock.sleep($0) })
        var capTasks: [Task<AutomationReply, Never>] = []
        for _ in 0..<AutomationLimits.replayEntries { let r = makeRequest(.getState); capTasks.append(Task { await capController.handle(r) }) }
        try await waitUntil("registry did not fill") { capGate.waits.count == AutomationLimits.replayEntries }
        try check(capGate.waits.count == AutomationLimits.replayEntries, "pending registry reaches bounded capacity")
        let capExtra = await capController.handle(makeRequest(.getState))
        try check(capExtra.outcome == .failure(AutomationError(code: .replayWindowFull)), "pending registry rejects excess")
        let capClose = await capController.handle(makeRequest(.cancel))
        try check(capClose.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))) && capCounts.cleanup == 1, "cancel bypasses full registry")
        for task in capTasks { let r = await task.value; try check(r.outcome == .failure(AutomationError(code: .cancelled)), "each preauthorization settled") }
        capGate.release(true); capClock.advance(100); await drain()
        return checks
    }
    private static func runFixture20() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !condition() { throw Failure(label: label) } }
        let profile = UUID(), target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        func fresh(_ clock: VirtualClock) throws -> AutomationSessionMachine {
            let m = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: clock.instant).get()
            _ = m.bind(target: target, viewport: viewport, at: clock.instant)
            return m
        }
        func makeRequest(_ action: AutomationAction, id: UUID = UUID()) -> AutomationRequest { AutomationRequest(version: 1, requestID: id, sessionID: token, action: action) }
        // Expired action is checked immediately at sink entry, even if timer is queued.
        let delayedClock = VirtualClock(), delayedMachine = try fresh(delayedClock), delayedCounts = Counts(), delayedTarget = Gate<AutomationTargetIdentity>()
        let delayedController = RunnerAutomationController(machine: delayedMachine, permissionReader: { true }, targetReader: { delayedCounts.targets += 1; return delayedCounts.targets == 2 ? await delayedTarget.wait() : target }, actionSink: { r, _ in delayedCounts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in delayedCounts.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { delayedClock.instant }, sleepUntil: { await delayedClock.sleep($0) })
        let delayedTask = Task { await delayedController.handle(click) }; await drain()
        try check(delayedTarget.waits.count == 1, "final target read pending")
        delayedClock.instant = 5; delayedTarget.release(target); await drain()
        let delayedReply = await delayedTask.value
        try check(delayedCounts.sink == 0 && delayedCounts.cleanup == 1 && delayedReply.outcome == .failure(AutomationError(code: .indeterminateResult)), "deadline checked at final sink entry")
        delayedClock.advance(100); await drain()
        return checks
    }
    private static func runCleanupLifecycle() async throws -> Int {
        let profile = UUID(), token = String(repeating: "A", count: 43)
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let clock = VirtualClock(), counts = Counts(), gate = Gate<CleanupReceipt>()
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        _ = machine.bind(target: target, viewport: viewport, at: 0)
        var controller: RunnerAutomationController? = RunnerAutomationController(machine: machine, permissionReader: { true }, targetReader: { target }, actionSink: { r, _ in counts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in counts.cleanup += 1; return await gate.wait() }, now: { clock.instant }, sleepUntil: { await clock.sleep($0) })
        weak let weakOwner = controller
        controller?.shutdown()
        clock.instant = 3
        controller?.shutdown()
        guard machine.state == .closed else { throw Failure(label: "cleanup deadline not applied") }
        controller = nil
        try await waitUntil("cleanup not attempted after owner release") { counts.cleanup == 1 }
        guard weakOwner == nil && counts.sink == 0 else { throw Failure(label: "cleanup retains owner or dispatches input") }
        gate.release(CleanupReceipt(cleaned: true, terminatedOwnedRunner: true)); await drain()
        let close = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
        let effects = machine.begin(close, permission: true, target: target, at: 3)
        let expected = AutomationReply(requestID: close.requestID, outcome: .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))))
        guard effects.contains(where: { if case .reply(let value) = $0 { return value == expected }; return false }) else { throw Failure(label: "late cleanup changed terminal receipt") }
        clock.advance(100); await drain()
        return 4
    }
    private static func runQueuedCancellation() async throws -> Int {
        let id = UUID(), token = String(repeating: "A", count: 43), clock = VirtualClock(), counts = Counts()
        let target = AutomationTargetIdentity(profileID: id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let machine = try AutomationSessionMachine.open(profileID: id, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        _ = machine.bind(target: target, viewport: viewport, at: 0)
        var task: Task<AutomationReply, Never>?
        let controller = RunnerAutomationController(machine: machine, permissionReader: { true }, targetReader: {
            counts.targets += 1
            if counts.targets == 2 { Task { @MainActor in task?.cancel() } }
            return target
        }, actionSink: { r, _ in counts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in counts.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock.instant }, sleepUntil: { await clock.sleep($0) })
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 0, y: 0), viewVersion: 1, count: 1))
        task = Task { await controller.handle(request) }
        guard let task else { throw Failure(label: "missing task") }
        let result = await task.value
        await drain()
        guard counts.sink == 0, case .failure(let error) = result.outcome, error.sideEffects == .none else { throw Failure(label: "queued caller cancellation must not enter sink") }
        clock.advance(100); await drain()
        return 1
    }
    private static func runStoppingFastPath() async throws -> Int {
        let id = UUID(), token = String(repeating: "A", count: 43), clock = VirtualClock(), counts = Counts(), gate = Gate<CleanupReceipt>()
        let target = AutomationTargetIdentity(profileID: id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let machine = try AutomationSessionMachine.open(profileID: id, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        _ = machine.bind(target: target, viewport: viewport, at: 0)
        let controller = RunnerAutomationController(machine: machine, permissionReader: { counts.permissions += 1; return await Gate<Bool>().wait() }, targetReader: { target }, actionSink: { r, _ in AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in counts.cleanup += 1; return await gate.wait() }, now: { clock.instant }, sleepUntil: { await clock.sleep($0) })
        controller.shutdown(); try await waitUntil("cleanup did not start") { counts.cleanup == 1 }
        let read = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState)
        let response = await controller.handle(read)
        guard response.outcome == .failure(AutomationError(code: .sessionBusy)), counts.permissions == 0 else { throw Failure(label: "stopping cannot await reader") }
        gate.release(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false)); await drain(); clock.advance(100); await drain()
        return 1
    }
    private static func runEarlySleeper() async throws -> Int {
        let id = UUID(), token = String(repeating: "A", count: 43), counts = Counts()
        let target = AutomationTargetIdentity(profileID: id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let machine = try AutomationSessionMachine.open(profileID: id, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        _ = machine.bind(target: target, viewport: viewport, at: 0)
        let gate = Gate<CleanupReceipt>()
        let controller = RunnerAutomationController(machine: machine, permissionReader: { true }, targetReader: { target }, actionSink: { r, _ in counts.sink += 1; return AutomationReply(requestID: r.requestID, outcome: .failure(AutomationError(code: .timeout))) }, cleanupSink: { _, _, _ in counts.cleanup += 1; return await gate.wait() }, now: { 0 }, sleepUntil: { _ in })
        await drain()
        guard machine.state == .closed && counts.cleanup == 1 else { throw Failure(label: "early sleeper must fail closed without spin") }
        let close = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
        let reply = await controller.handle(close)
        guard reply.outcome == .success(.sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false))) else { throw Failure(label: "early sleeper cleanup receipt") }
        gate.release(CleanupReceipt(cleaned: true, terminatedOwnedRunner: true)); await drain()
        return 2
    }
    private static func runRetainedReaderBudget() async throws -> Int {
        let id = UUID(), token = String(repeating: "A", count: 43), clock = VirtualClock(), gate = Gate<Bool>()
        let target = AutomationTargetIdentity(profileID: id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let machine = try AutomationSessionMachine.open(profileID: id, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        _ = machine.bind(target: target, viewport: viewport, at: 0)
        var released = false
        let controller = RunnerAutomationController(machine: machine, permissionReader: { if released { return true }; return await gate.wait() }, targetReader: { target }, actionSink: { r, _ in
            let state = AutomationState(target: target, url: nil, loading: false, sessionState: .ready, viewVersion: 1)
            return AutomationReply(requestID: r.requestID, outcome: .success(.stateRead(state)))
        }, cleanupSink: { _, _, _ in CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock.instant }, sleepUntil: { await clock.sleep($0) })
        func read() -> AutomationRequest { AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState) }
        var tasks: [Task<AutomationReply, Never>] = []
        for _ in 0..<AutomationLimits.replayEntries { let request = read(); tasks.append(Task { await controller.handle(request) }) }
        try await waitUntil("stuck readers not registered") { gate.waits.count == AutomationLimits.replayEntries }
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        let overflowTask = Task { await controller.handle(read()) }
        final class Box { var reply: AutomationReply? }
        let box = Box(); let observer = Task { box.reply = await overflowTask.value }
        await drain()
        guard box.reply?.outcome == .failure(AutomationError(code: .replayWindowFull)) else { overflowTask.cancel(); throw Failure(label: "cancelled stuck readers must retain budget") }
        released = true; gate.release(true); _ = await observer.value; await drain()
        let resumed = await controller.handle(read())
        guard case .success(.stateRead) = resumed.outcome else { throw Failure(label: "reader budget not recovered") }
        controller.shutdown(); await drain(); clock.advance(100); await drain()
        return 2
    }
    private static func runCancelInsideSink() async throws -> Int {
        let profile = UUID(), token = String(repeating: "A", count: 43), clock = VirtualClock(), counts = Counts()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let view = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        _ = machine.bind(target: target, viewport: view, at: 0)
        var caller: Task<AutomationReply, Never>?
        let controller = RunnerAutomationController(machine: machine, permissionReader: { true }, targetReader: { target }, actionSink: { request, _ in
            counts.sink += 1; caller?.cancel()
            return AutomationReply(requestID: request.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        }, cleanupSink: { _, _, _ in counts.cleanup += 1; return CleanupReceipt(cleaned: false, terminatedOwnedRunner: false) }, now: { clock.instant }, sleepUntil: { await clock.sleep($0) })
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 0, y: 0), viewVersion: 1, count: 1))
        caller = Task { await controller.handle(request) }
        guard let task = caller else { throw Failure(label: "sink cancellation fixture") }
        let reply = await task.value
        controller.shutdown()
        try await waitUntil("sink cancel cleanup") { counts.cleanup == 1 && machine.state == .closed }
        clock.advance(100); await drain()
        guard reply.outcome == .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible)), counts.sink == 1 else { throw Failure(label: "synchronous sink cancellation cannot publish success") }
        return 2
    }
    public static func run() async throws -> Int {
        var total = try await runInitial()
        total += try await runFixture0()
        total += try await runFixture1()
        total += try await runFixture2()
        total += try await runFixture3()
        total += try await runFixture4()
        total += try await runFixture5()
        total += try await runFixture6()
        total += try await runFixture7()
        total += try await runFixture8()
        total += try await runFixture9()
        total += try await runFixture10()
        total += try await runFixture11()
        total += try await runFixture12()
        total += try await runFixture13()
        total += try await runFixture14()
        total += try await runFixture15()
        total += try await runFixture16()
        total += try await runFixture17()
        total += try await runFixture18()
        total += try await runFixture19()
        total += try await runFixture20()
        total += try await runCleanupLifecycle()
        total += try await runQueuedCancellation()
        total += try await runStoppingFastPath()
        total += try await runEarlySleeper()
        total += try await runRetainedReaderBudget()
        total += try await runCancelInsideSink()
        return total
    }
}
