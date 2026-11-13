#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_MANAGER_ROUTING_TESTS
import XCTest
import Darwin
import SafarierCore
@testable import Safarier

final class RegisteredManagerRoutingTests: XCTestCase {
    private actor Endpoint: AutomationManagerEndpoint {
        nonisolated let registeredInteractive = true
        nonisolated let pid: Int32
        nonisolated let runnerInstanceID: UUID
        nonisolated let ownershipID: UUID
        let owner: OwnedRunnerProcess
        let target: AutomationTargetIdentity
        let token: String
        var releaseCount = 0, closeCount = 0
        init(owner: OwnedRunnerProcess, target: AutomationTargetIdentity) throws {
            self.owner = owner; self.target = target; self.token = try AutomationSessionToken.generate()
            pid = owner.pid; runnerInstanceID = target.runnerInstanceID; ownershipID = owner.ownershipID
        }
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            let result: AutomationResult
            switch request.action {
            case .openSession:
                let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
                result = .sessionOpened(sessionID: token, target: target, viewport: viewport)
            case .releaseControl:
                result = .controlReleasePrepared(ControlReleasePreparation(target: target, transferID: transferID, inputReleased: true, artifactsCleaned: true, browserRetained: true))
            case .commitControlRelease(let id):
                guard id == transferID else { throw AutomationError(code: .invalidRequest) }
                result = .controlReleased(ControlReleaseReceipt(target: target, transferID: id, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }
        private let transferID = UUID()
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? { closeCount += 1; return nil }
        func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess {
            guard receipt.target == target, receipt.transferID == transferID else { throw AutomationError(code: .invalidRequest) }
            releaseCount += 1; return owner
        }
    }
    @MainActor func testReleasedRegisteredRunnerCanReconnectWithoutClosingOwner() async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        let profile = Profile(name: "registered fixture", mode: .persistent)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        var endpoints: [Endpoint] = []
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in throw AutomationError(code: .profileAlreadyRunning) }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in let endpoint = try Endpoint(owner: owner, target: target); endpoints.append(endpoint); return endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ request: AutomationRequest) async -> AutomationReply { await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid()) }
        let first = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)))
        guard case .success(.sessionOpened(let firstToken, let firstTarget, _)) = first.outcome else { return XCTFail("first open") }
        let release = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: firstToken, action: .releaseControl))
        guard case .success(.controlReleased(let receipt)) = release.outcome else { return XCTFail("release") }
        XCTAssertEqual(receipt.target, target)
        let old = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: firstToken, action: .getState))
        XCTAssertEqual(old.outcome, .failure(AutomationError(code: .sessionExpired)))
        let second = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)))
        guard case .success(.sessionOpened(let secondToken, let secondTarget, _)) = second.outcome else { return XCTFail("second open") }
        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertEqual(firstTarget, secondTarget)
        XCTAssertTrue(owner.isRunning)
        let closeCount = await endpoints[0].closeCount
        let releaseCount = await endpoints[0].releaseCount
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(releaseCount, 1)
        manager.shutdown()
    }
}
#endif
