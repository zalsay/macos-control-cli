#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_MANAGER_ROUTING_TESTS
import XCTest
import Darwin
import SafarierCore
@testable import Safarier

@MainActor final class RegisteredManagerRecoveryTests: XCTestCase {
    private actor Endpoint: AutomationManagerEndpoint {
        nonisolated let registeredInteractive = true
        nonisolated let pid: Int32, runnerInstanceID: UUID, ownershipID: UUID
        let owner: OwnedRunnerProcess, target: AutomationTargetIdentity
        let token = String(repeating: "A", count: 43), transfer = UUID()
        var prepareBusy = false, commitBusy = false
        var snapshotDelay = false
        var prepared = 0, committed = 0, closed = 0, read = 0
        init(owner: OwnedRunnerProcess, target: AutomationTargetIdentity) {
            self.owner = owner; self.target = target
            pid = owner.pid; ownershipID = owner.ownershipID; runnerInstanceID = target.runnerInstanceID
        }
        func failNextRelease(commit: Bool) { prepareBusy = !commit; commitBusy = commit }
        func delaySnapshot() { snapshotDelay = true }
        func counts() -> [Int] { [prepared, committed, closed, read] }
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            let result: AutomationResult
            switch request.action {
            case .openSession:
                result = .sessionOpened(sessionID: token, target: target, viewport: AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1))
            case .releaseControl:
                prepared += 1
                if prepareBusy { prepareBusy = false; return AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .sessionBusy))) }
                result = .controlReleasePrepared(ControlReleasePreparation(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true))
            case .commitControlRelease(let id):
                committed += 1
                guard id == transfer else { throw AutomationError(code: .invalidRequest) }
                if commitBusy { commitBusy = false; return AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .sessionBusy))) }
                result = .controlReleased(ControlReleaseReceipt(target: target, transferID: id, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))
            case .getState:
                read += 1
                result = .stateRead(AutomationState(target: target, url: nil, loading: false, sessionState: .ready, viewVersion: 1))
            case .screenshot:
                if snapshotDelay { try? await Task.sleep(for: .milliseconds(200)) }
                result = .snapshotWritten(path: "/fixture", viewport: AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1))
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }
        func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess {
            guard receipt.target == target, receipt.transferID == transfer else { throw AutomationError(code: .invalidRequest) }
            return owner
        }
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? { closed += 1; return nil }
    }
    private func run(commit: Bool) async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        let profile = Profile(name: "registered-release-recovery", mode: .persistent)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let endpoint = Endpoint(owner: owner, target: target)
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ request: AutomationRequest) async -> AutomationReply { await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid()) }
        guard case .success(.sessionOpened(let token, _, _)) = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))).outcome else { return XCTFail("open") }
        await endpoint.failNextRelease(commit: commit)
        let first = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl)
        let failure = await send(first)
        XCTAssertEqual(failure.outcome, .failure(AutomationError(code: .sessionBusy)), "preserve a known rejection")
        let replay = await send(first)
        XCTAssertEqual(replay, failure, "the same request ID must not execute again")
        let before = await endpoint.counts()
        XCTAssertEqual(before, commit ? [1, 1, 0, 0] : [1, 0, 0, 0])
        if !commit {
            let state = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState))
            guard case .success(.stateRead) = state.outcome else { return XCTFail("state after rejected prepare") }
        }
        let retry = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.controlReleased) = retry.outcome else { return XCTFail("explicit release retry: \(retry.outcome)") }
        let after = await endpoint.counts()
        XCTAssertEqual(after, commit ? [1, 2, 0, 0] : [2, 1, 0, 1], "resume the original transfer without repeating preparation")
    }
    func testRejectedPrepareAllowsStateAndExplicitReleaseRetry() async throws { try await run(commit: false) }
    func testRejectedCommitResumesExactPreparationOnExplicitRelease() async throws { try await run(commit: true) }
    func testReadDeadlineDoesNotCloseSessionAndLateResultDoesNotReplaceTimeout() async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        let profile = Profile(name: "registered-read-recovery", mode: .persistent)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let endpoint = Endpoint(owner: owner, target: target), clock = AutomationManagerCases.Clock()
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in endpoint }, admission: { true }, now: { clock.read() }, sleepUntil: { deadline in
            try await Task.sleep(for: .milliseconds(30)); clock.advance(deadline)
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ request: AutomationRequest) async -> AutomationReply { await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid()) }
        guard case .success(.sessionOpened(let token, _, _)) = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))).outcome else { return XCTFail("open") }
        await endpoint.delaySnapshot()
        let read = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        let timeout = await send(read)
        XCTAssertEqual(timeout.outcome, .failure(AutomationError(code: .timeout)))
        let state = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState))
        guard case .success(.stateRead) = state.outcome else { return XCTFail("state after timeout") }
        try await Task.sleep(for: .milliseconds(250))
        let replay = await send(read)
        XCTAssertEqual(replay, timeout, "late result must not replace the original timeout")
        let released = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.controlReleased) = released.outcome else { return XCTFail("release after timeout") }
        let counts = await endpoint.counts()
        XCTAssertEqual(counts[2], 0)
    }
}
#endif
