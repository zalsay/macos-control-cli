#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_MANAGER_ROUTING_TESTS
import Darwin
import XCTest
import SafarierCore
@testable import Safarier

final class RegisteredAutomaticCloseTests: XCTestCase {
    private actor Endpoint: AutomationManagerEndpoint {
        enum Mode { case normal, late, drainFailure, inFlight, budget }
        nonisolated let registeredInteractive = true
        nonisolated let pid: Int32 = 4321
        nonisolated let runnerInstanceID = UUID(), ownershipID = UUID()
        nonisolated let absoluteLifetimeDeadline: Double?
        private let profile: UUID
        private let mode: Mode
        private let token = String(repeating: "A", count: 43)
        private let window = UUID(), page = UUID()
        private(set) var closes = 0
        private(set) var clicks = 0
        private(set) var drains = 0
        private(set) var navigations = 0, releases = 0
        private(set) var navigationTimeout: Double?
        private(set) var proofCalls: [(sentAt: Double, timeout: Double)] = []
        init(_ profile: UUID, mode: Mode = .normal, lifetimeOffset: Double = 3.4) {
            self.profile = profile; self.mode = mode
            self.absoluteLifetimeDeadline = ProcessInfo.processInfo.systemUptime + lifetimeOffset
        }
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: runnerInstanceID, windowID: window, pageID: page)
            let result: AutomationResult
            switch request.action {
            case .openSession:
                let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
                result = .sessionOpened(sessionID: token, target: target, viewport: view)
            case .closeSession:
                guard request.sessionID == token else { throw AutomationError(code: .sessionNotFound) }
                closes += 1
                proofCalls.append((ProcessInfo.processInfo.systemUptime, timeoutSeconds))
                if mode == .late {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.global().asyncAfter(deadline: .now() + 2.3) { c.resume() } }
                }
                result = .sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false, retainedBrowser: RetainedBrowserCleanup(target: target, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)))
            case .click where mode == .inFlight:
                clicks += 1
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { c.resume() } }
                result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
            case .click where mode == .budget:
                clicks += 1
                result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
            case .navigate where mode == .budget:
                navigations += 1
                result = .navigationSubmitted(viewVersion: 2)
            case .navigateByInput where mode == .budget:
                navigations += 1; navigationTimeout = timeoutSeconds
                result = .navigationFinished(viewVersion: 2)
            case .releaseControl where mode == .budget:
                releases += 1
                throw AutomationError(code: .backendUnavailable)
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? {
            drains += 1
            if mode == .drainFailure { throw AutomationError(code: .timeout) }
            return nil
        }
    }

    @MainActor func testRegisteredLifetimeDoesNotTriggerAutomaticClose() async throws {
        let profile = Profile(name: "registered lifetime", mode: .ephemeral)
        let endpoint = Endpoint(profile.id, mode: .budget, lifetimeOffset: 0.3)
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let opened = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.sessionOpened(let token, _, _)) = opened.outcome else { return XCTFail("open failed") }
        try await Task.sleep(nanoseconds: 500_000_000)
        let input = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1)), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.nativeDelivered) = input.outcome else { return XCTFail("old lifetime must not reject input") }
        let closes = await endpoint.closes
        XCTAssertEqual(closes, 0)
        let closed = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.sessionClosed(let receipt)) = closed.outcome else { return XCTFail("explicit close failed") }
        XCTAssertTrue(receipt.retainedBrowser?.confirmed == true)
    }
    @MainActor func testExplicitCloseDoesNotConfirmFailedDrain() async throws {
        let profile = Profile(name: "registered drain failure", mode: .ephemeral)
        let endpoint = Endpoint(profile.id, mode: .drainFailure)
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let opened = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.sessionOpened(let token, _, _)) = opened.outcome else { return XCTFail("open failed") }
        let closed = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.sessionClosed(let receipt)) = closed.outcome else { return XCTFail("close failed") }
        XCTAssertNil(receipt.retainedBrowser)
        XCTAssertFalse(receipt.cleaned)
    }
}
#endif
