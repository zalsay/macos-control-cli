import XCTest
@testable import SafarierCore

final class RegisteredRequestRecoveryTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)
    private func setup() throws -> (AutomationSessionMachine, AutomationTargetIdentity) {
        let target = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let machine = try AutomationSessionMachine.open(profileID: target.profileID, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0, registeredInteractive: true).get()
        let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        _ = machine.bind(target: target, viewport: view, at: 0)
        return (machine, target)
    }
    private func request(_ action: AutomationAction) -> AutomationRequest {
        AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: action)
    }
    func testReadTimeoutKeepsSessionAndIgnoresLateCompletion() throws {
        for action: AutomationAction in [.getState, .screenshot] {
            let (machine, target) = try setup(), read = request(action)
            guard case .dispatch(let ticket, _) = machine.begin(read, permission: true, target: target, at: 1).first else { return XCTFail("read") }
            let effects = machine.tick(at: 11)
            let timeout = AutomationReply(requestID: read.requestID, outcome: .failure(AutomationError(code: .timeout)))
            XCTAssertEqual(effects, [.completion(ticket, timeout)])
            XCTAssertEqual(machine.state, .ready)
            XCTAssertEqual(machine.begin(read, permission: true, target: target, at: 12), [.reply(timeout)])
            let next = request(.screenshot)
            guard case .dispatch(let nextTicket, _) = machine.begin(next, permission: true, target: target, at: 12).first else { return XCTFail("next observe") }
            XCTAssertTrue(machine.complete(ticket: ticket, reply: timeout, at: 13).isEmpty)
            XCTAssertEqual(machine.currentTicket, nextTicket, "late read must not complete the next request")
            _ = machine.complete(ticket: nextTicket, reply: AutomationReply(requestID: next.requestID, outcome: .failure(AutomationError(code: .backendUnavailable))), at: 13)
            guard case .dispatch = machine.begin(request(.releaseControl), permission: true, target: target, at: 14).first else { return XCTFail("release after timeout") }
        }
    }
    func testPrepareBusyWithoutEffectsCanBeExplicitlyRetried() throws {
        let (machine, target) = try setup(), release = request(.releaseControl)
        guard case .dispatch(let ticket, _) = machine.begin(release, permission: true, target: target, at: 1).first else { return XCTFail("prepare") }
        let busy = AutomationReply(requestID: release.requestID, outcome: .failure(AutomationError(code: .sessionBusy)))
        XCTAssertEqual(machine.complete(ticket: ticket, reply: busy, at: 2), [.completion(ticket, busy)])
        XCTAssertEqual(machine.state, .ready)
        XCTAssertTrue(machine.tick(at: 30).isEmpty, "failed preparation must not leave a handshake deadline")
        guard case .dispatch = machine.begin(request(.releaseControl), permission: true, target: target, at: 31).first else { return XCTFail("retry prepare") }
    }
    func testNewRequestCanRetireExpiredReadBeforeTimerFires() throws {
        let (machine, target) = try setup(), read = request(.screenshot)
        _ = machine.begin(read, permission: true, target: target, at: 1)
        let release = request(.releaseControl)
        let effects = machine.begin(release, permission: true, target: target, at: 11)
        XCTAssertTrue(effects.contains { if case .dispatch(_, let dispatched) = $0 { return dispatched == release }; return false })
    }
    func testReadTimeoutDoesNotSwallowPermissionRevocation() throws {
        let (machine, target) = try setup()
        _ = machine.begin(request(.screenshot), permission: true, target: target, at: 1)
        _ = machine.event(.permissionRevoked, at: 11)
        XCTAssertEqual(machine.state, .stopping)
    }
    func testCommitBusyRetainsExactPreparationForExplicitRetry() throws {
        let (machine, target) = try setup(), release = request(.releaseControl), transfer = UUID()
        guard case .dispatch(let ticket, _) = machine.begin(release, permission: true, target: target, at: 1).first else { return XCTFail("prepare") }
        let prepared = ControlReleasePreparation(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true)
        _ = machine.complete(ticket: ticket, reply: AutomationReply(requestID: release.requestID, outcome: .success(.controlReleasePrepared(prepared))), at: 2)
        let commit = request(.commitControlRelease(transferID: transfer))
        guard case .dispatch(let commitTicket, _) = machine.begin(commit, permission: true, target: target, at: 3).first else { return XCTFail("commit") }
        let busy = AutomationReply(requestID: commit.requestID, outcome: .failure(AutomationError(code: .sessionBusy)))
        XCTAssertEqual(machine.complete(ticket: commitTicket, reply: busy, at: 4), [.completion(commitTicket, busy)])
        XCTAssertEqual(machine.state, .ready)
        let wrong = machine.begin(request(.commitControlRelease(transferID: UUID())), permission: true, target: target, at: 5)
        XCTAssertTrue(wrong.contains { if case .reply(let reply) = $0, case .failure = reply.outcome { return true }; return false })
        guard case .dispatch = machine.begin(request(.commitControlRelease(transferID: transfer)), permission: true, target: target, at: 6).first else { return XCTFail("retry exact commit") }
    }
    func testReleaseWithPossibleNativeEffectsStillRequiresCleanup() throws {
        let (machine, target) = try setup(), release = request(.releaseControl)
        guard case .dispatch(let ticket, _) = machine.begin(release, permission: true, target: target, at: 1).first else { return XCTFail("prepare") }
        _ = machine.complete(ticket: ticket, reply: AutomationReply(requestID: release.requestID, outcome: .failure(AutomationError(code: .targetChanged, sideEffects: .possible))), at: 2)
        XCTAssertEqual(machine.state, .stopping)
    }
}
