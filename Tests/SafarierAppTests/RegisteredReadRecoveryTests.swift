import XCTest
import SafarierCore
@testable import Safarier

@MainActor final class RegisteredReadRecoveryTests: XCTestCase {
    private func run(cancel: Bool) async throws {
        let target = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43), clock = RunnerAutomationControllerCases.VirtualClock()
        let gate = RunnerAutomationControllerCases.Gate<Void>(), counts = RunnerAutomationControllerCases.Counts()
        let machine = try AutomationSessionMachine.open(profileID: target.profileID, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0, registeredInteractive: true).get()
        let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        _ = machine.bind(target: target, viewport: view, at: 0)
        let controller = RunnerAutomationController(machine: machine, permissionReader: { true }, targetReader: { target }, actionSink: { request, _ in
            counts.sink += 1
            if counts.sink == 1 { await gate.wait() }
            return AutomationReply(requestID: request.requestID, outcome: .success(.snapshotWritten(path: "/fixture", viewport: view)))
        }, cleanupSink: { _, _, _ in counts.cleanup += 1; return CleanupReceipt(cleaned: true, terminatedOwnedRunner: false) }, now: { clock.instant }, sleepUntil: { if $0 > clock.instant { await clock.sleep($0) } })
        let first = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        let task = Task { await controller.handle(first) }
        try await RunnerAutomationControllerCases.waitUntil("first snapshot") { !gate.waits.isEmpty && clock.waits.contains { $0.deadline == 10 } }
        if cancel { task.cancel() } else { clock.advance(10) }
        let failed = await task.value
        XCTAssertEqual(failed.outcome, .failure(AutomationError(code: cancel ? .cancelled : .timeout)))
        XCTAssertEqual(machine.state, .ready)
        XCTAssertEqual(counts.cleanup, 0)
        let next = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        let snapshot = await controller.handle(next)
        XCTAssertEqual(snapshot.outcome, .success(.snapshotWritten(path: "/fixture", viewport: view)))
        gate.release(())
        await RunnerAutomationControllerCases.drain()
        XCTAssertEqual(machine.state, .ready)
        XCTAssertEqual(counts.sink, 2, "no automatic retry of either snapshot")
        controller.shutdown()
        clock.advance(1000)
        await RunnerAutomationControllerCases.drain()
    }
    func testTimedOutSnapshotAllowsNextReadAndIgnoresLateSink() async throws { try await run(cancel: false) }
    func testCancelledSnapshotAllowsNextReadAndIgnoresLateSink() async throws { try await run(cancel: true) }
}
