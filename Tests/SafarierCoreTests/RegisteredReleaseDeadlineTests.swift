import XCTest
import Darwin
@testable import SafarierCore

final class RegisteredReleaseDeadlineTests: XCTestCase {
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
    private func prepare(_ machine: AutomationSessionMachine, _ target: AutomationTargetIdentity) throws -> UUID {
        let release = request(.releaseControl), transfer = UUID()
        guard case .dispatch(let ticket, _) = machine.begin(release, permission: true, target: target, at: 1).first else { throw Failure.notDispatched }
        let reply = AutomationReply(requestID: release.requestID, outcome: .success(.controlReleasePrepared(ControlReleasePreparation(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true))))
        XCTAssertTrue(machine.complete(ticket: ticket, reply: reply, at: 9).contains { if case .completion(_, let result) = $0 { return result == reply }; return false })
        return transfer
    }
    func testSlowPrepareLeavesTimeForCommitWithoutExtendingSingleAction() throws {
        let (machine, target) = try setup(), transfer = try prepare(machine, target)
        let commit = request(.commitControlRelease(transferID: transfer))
        guard case .dispatch(let ticket, _) = machine.begin(commit, permission: true, target: target, at: 10).first else { return XCTFail("commit") }
        let reply = AutomationReply(requestID: commit.requestID, outcome: .success(.controlReleased(ControlReleaseReceipt(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))))
        XCTAssertTrue(machine.complete(ticket: ticket, reply: reply, at: 18).contains { if case .completion(_, let result) = $0 { return result == reply }; return false })
        XCTAssertEqual(machine.state, .released)
    }
    func testStalledPrepareStillExpiresAtSingleActionDeadline() throws {
        let (machine, target) = try setup()
        _ = machine.begin(request(.releaseControl), permission: true, target: target, at: 1)
        _ = machine.tick(at: 11)
        XCTAssertEqual(machine.state, .stopping)
    }
    func testStalledCommitStillExpiresAtSingleActionDeadline() throws {
        let (machine, target) = try setup(), transfer = try prepare(machine, target)
        _ = machine.begin(request(.commitControlRelease(transferID: transfer)), permission: true, target: target, at: 9)
        XCTAssertTrue(machine.tick(at: 18).isEmpty)
        _ = machine.tick(at: 19)
        XCTAssertEqual(machine.state, .stopping)
    }
    func testPreparedSessionWithoutCommitHasBoundedLifetime() throws {
        let (machine, target) = try setup()
        _ = try prepare(machine, target)
        XCTAssertTrue(machine.tick(at: 19).isEmpty)
        _ = machine.tick(at: 21)
        XCTAssertEqual(machine.state, .stopping)
    }
    func testOuterCoordinatorAllowsReleaseToCompletePastTenSeconds() async throws {
        let coordinator = AutomationScriptCoordinator()
        let target = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let release = request(.releaseControl)
        let receipt = ControlReleaseReceipt(target: target, transferID: UUID(), inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)
        let expected = AutomationReply(requestID: release.requestID, outcome: .success(.controlReleased(receipt)))
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let data = try AutomationCodec.encodeRequest(release)
        let bytes: Data = await withCheckedContinuation { continuation in
            coordinator.start(data: data, role: .manager, proof: proof, currentUID: geteuid(), timeoutSeconds: release.action.managerTimeoutSeconds, handler: { _ in
                try await Task.sleep(for: .seconds(11))
                return expected
            }, completion: { continuation.resume(returning: $0) })
        }
        XCTAssertEqual(try AutomationCodec.decodeReply(bytes), expected)
        XCTAssertEqual(coordinator.pendingCount, 0)
    }
    private enum Failure: Error { case notDispatched }
}
