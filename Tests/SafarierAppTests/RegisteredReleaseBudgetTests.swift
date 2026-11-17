#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_MANAGER_ROUTING_TESTS
import XCTest
import Darwin
import SafarierCore
@testable import Safarier

final class RegisteredReleaseBudgetTests: XCTestCase {
    private actor Endpoint: AutomationManagerEndpoint {
        nonisolated let registeredInteractive = true
        nonisolated let pid: Int32, runnerInstanceID: UUID, ownershipID: UUID
        let owner: OwnedRunnerProcess, target: AutomationTargetIdentity
        let clock: AutomationManagerCases.Clock
        let token = String(repeating: "A", count: 43), transfer = UUID()
        let failCommit: Bool
        var budgets: [Double] = []
        var closed = 0, handedOff = 0, ordinary = 0
        init(owner: OwnedRunnerProcess, target: AutomationTargetIdentity, clock: AutomationManagerCases.Clock, failCommit: Bool) {
            self.owner = owner; self.target = target; self.clock = clock; self.failCommit = failCommit
            pid = owner.pid; runnerInstanceID = target.runnerInstanceID; ownershipID = owner.ownershipID
        }
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            let value: AutomationResult
            switch request.action {
            case .openSession:
                value = .sessionOpened(sessionID: token, target: target, viewport: AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1))
            case .releaseControl:
                budgets.append(timeoutSeconds)
                guard timeoutSeconds > 8 else { throw AutomationError(code: .timeout) }
                clock.advance(clock.read() + 8)
                value = .controlReleasePrepared(ControlReleasePreparation(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true))
            case .commitControlRelease(let id):
                budgets.append(timeoutSeconds)
                guard !failCommit, id == transfer, timeoutSeconds > 8 else { throw AutomationError(code: .timeout) }
                clock.advance(clock.read() + 8)
                value = .controlReleased(ControlReleaseReceipt(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))
            default: ordinary += 1; throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(value))
        }
        func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess {
            guard receipt.target == target, receipt.transferID == transfer else { throw AutomationError(code: .invalidRequest) }
            clock.advance(clock.read() + 3)
            handedOff += 1
            return owner
        }
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? { closed += 1; return nil }
    }
    @MainActor private func run(failCommit: Bool, switchOff: Bool = false) async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        var profile = Profile(name: "release-budget", mode: .ephemeral)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let clock = AutomationManagerCases.Clock()
        let endpoint = Endpoint(owner: owner, target: target, clock: clock, failCommit: failCommit)
        var profileReads = 0, profileAvailable = true
        let manager = AutomationManager(profileReader: { profileReads += 1; return profileAvailable && $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in endpoint }, admission: { true }, now: { clock.read() }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ action: AutomationAction, token: String?) async -> AutomationReply {
            await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: action), role: .manager, proof: proof, currentUID: geteuid())
        }
        guard case .success(.sessionOpened(let token, _, _)) = await send(.openSession(profileID: profile.id), token: nil).outcome else { return XCTFail("open") }
        if switchOff {
            profile.allowsAgentAccess = false
            let denied = await send(.click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1), token: token)
            XCTAssertEqual(denied.outcome, .failure(AutomationError(code: .profileNotAllowed)))
            let forwarded = await endpoint.ordinary
            XCTAssertEqual(forwarded, 0)
            return
        }
        let readsAfterOpen = profileReads
        profileAvailable = false
        let result = await send(.releaseControl, token: token)
        XCTAssertEqual(profileReads, readsAfterOpen, "returning control must not reread the profile")
        if failCommit {
            guard case .failure = result.outcome else { return XCTFail("failed commit must not claim release") }
            let handoffs = await endpoint.handedOff
            XCTAssertEqual(handoffs, 0)
        } else {
            guard case .success(.controlReleased(let receipt)) = result.outcome else { return XCTFail("two valid 8s phases and a 3s drain must complete") }
            XCTAssertTrue(receipt.inputReleased && receipt.artifactsCleaned && receipt.browserRetained && receipt.manualInteractionEnabled)
            let budgets = await endpoint.budgets, handoffs = await endpoint.handedOff
            XCTAssertEqual(budgets.count, 2)
            XCTAssertTrue(budgets.allSatisfy { $0 > 8 && $0 <= 10 }, "each phase remains individually bounded")
            XCTAssertEqual(handoffs, 1)
        }
    }
    @MainActor func testManagerStillEnforcesAgentSwitchBeforeInput() async throws { try await run(failCommit: false, switchOff: true) }
    @MainActor func testEachReleasePhaseHasItsOwnBudgetAndDrainCanFinish() async throws { try await run(failCommit: false) }
    @MainActor func testCommitFailureCannotBeReportedAsSuccessfulRelease() async throws { try await run(failCommit: true) }
}
#endif
