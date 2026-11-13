#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_MANAGER_ROUTING_TESTS
import Darwin
import XCTest
import SafarierCore
@testable import Safarier

final class RegisteredAutomaticCloseTests: XCTestCase {
    private actor Endpoint: AutomationManagerEndpoint {
        enum Mode { case normal, late, drainFailure, inFlight }
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

    @MainActor private func run(_ mode: Endpoint.Mode) async throws {
        let profile = Profile(name: "automatic fixture", mode: .ephemeral)
        let endpoint = Endpoint(profile.id, mode: mode, lifetimeOffset: mode == .late ? 1.5 : 3.4)
        let automaticAt = try XCTUnwrap(endpoint.absoluteLifetimeDeadline) - AutomationLimits.cleanupSeconds - 1
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            if mode == .inFlight && abs(deadline - automaticAt) < 0.05 {
                let testDeadline = ProcessInfo.processInfo.systemUptime + 2
                while await endpoint.clicks == 0 {
                    guard ProcessInfo.processInfo.systemUptime < testDeadline else { throw AutomationError(code: .timeout) }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let opened = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.sessionOpened(let token, let target, _)) = opened.outcome else { return XCTFail("open failed") }
        let pending: Task<AutomationReply, Never>?
        if mode == .inFlight {
            let click = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
            pending = Task { await manager.handle(click, role: .manager, proof: proof, currentUID: geteuid()) }
        } else { pending = nil }
        try await Task.sleep(nanoseconds: mode == .late ? 2_800_000_000 : 800_000_000)
        let automaticCount = await endpoint.closes
        XCTAssertEqual(automaticCount, 1, "expiry must request cleanup before the lifetime ends")
        let result = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession), role: .manager, proof: proof, currentUID: geteuid())
        let count = await endpoint.closes
        XCTAssertEqual(count, 1)
        guard case let .success(.sessionClosed(receipt)) = result.outcome else { return XCTFail("missing receipt") }
        if mode == .normal || mode == .inFlight {
            XCTAssertEqual(receipt.retainedBrowser?.target, target)
            XCTAssertEqual(receipt.retainedBrowser?.confirmed, true)
        } else {
            XCTAssertNil(receipt.retainedBrowser)
            XCTAssertFalse(receipt.cleaned)
        }
        if let pending {
            let result = await pending.value
            guard case .failure = result.outcome else { return XCTFail("in-flight action incorrectly completed") }
            let clicks = await endpoint.clicks
            XCTAssertEqual(clicks, 1, "automatic cleanup must not replay input")
        }
    }
    @MainActor func testAutomaticDeadlineObtainsBorrowedReceipt() async throws { try await run(.normal) }
    @MainActor func testLateReceiptCannotConfirmCleanup() async throws { try await run(.late) }
    @MainActor func testDrainFailureCannotConfirmCleanup() async throws { try await run(.drainFailure) }
    @MainActor func testInFlightActionIsCancelledWithoutReplaying() async throws { try await run(.inFlight) }

    @MainActor func testLateAutomaticTimerObtainsProofWithinRemainingBudget() async throws {
        let profile = Profile(name: "late timer fixture", mode: .ephemeral)
        let endpoint = Endpoint(profile.id, lifetimeOffset: 6.5)
        let automaticAt = try XCTUnwrap(endpoint.absoluteLifetimeDeadline) - AutomationLimits.cleanupSeconds - 1
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            let deliberateDelay = abs(deadline - automaticAt) < 0.05 ? 1.2 : 0
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline + deliberateDelay - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let opened = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.sessionOpened(let token, let target, _)) = opened.outcome else { return XCTFail("open failed") }
        try await Task.sleep(nanoseconds: 3_300_000_000)
        let closes = await endpoint.closes, drains = await endpoint.drains
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(drains, 1)
        let calls = await endpoint.proofCalls
        if let call = calls.first {
            XCTAssertLessThanOrEqual(call.timeout, AutomationLimits.cleanupSeconds)
            XCTAssertLessThanOrEqual(call.sentAt + call.timeout, try XCTUnwrap(endpoint.absoluteLifetimeDeadline) + 0.05)
        } else { XCTFail("missing automatic closeSession request") }
        let result = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession), role: .manager, proof: proof, currentUID: geteuid())
        guard case let .success(.sessionClosed(receipt)) = result.outcome else { return XCTFail("missing receipt") }
        XCTAssertEqual(receipt.retainedBrowser?.target, target)
        XCTAssertEqual(receipt.retainedBrowser?.confirmed, true)
        XCTAssertFalse(receipt.cleaned)
    }

    @MainActor func testAutomaticCloseRejectsAfterCutoffAndLateProof() async throws {
        for scenario in ["afterCutoff", "lateProof"] {
            let profile = Profile(name: "cutoff fixture", mode: .ephemeral)
            let endpoint = Endpoint(profile.id, mode: scenario == "lateProof" ? .late : .normal, lifetimeOffset: 6.5)
            let automaticAt = try XCTUnwrap(endpoint.absoluteLifetimeDeadline) - AutomationLimits.cleanupSeconds - 1
            let delay = scenario == "afterCutoff" ? 5.25 : 4.5
            let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
                let extra = abs(deadline - automaticAt) < 0.05 ? delay : 0
                try await Task.sleep(nanoseconds: UInt64(max(0, deadline + extra - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
            })
            manager.injectedOwnedRegistrationProof = { true }
            manager.setRegisteredConnector { _ in endpoint }
            let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
            let opened = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)), role: .manager, proof: proof, currentUID: geteuid())
            guard case .success(.sessionOpened(let token, _, _)) = opened.outcome else { return XCTFail("open failed: \(scenario)") }
            try await Task.sleep(nanoseconds: 8_800_000_000)
            let closes = await endpoint.closes, drains = await endpoint.drains
            XCTAssertEqual(closes, scenario == "afterCutoff" ? 0 : 1, scenario)
            XCTAssertEqual(drains, 1, scenario)
            let result = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession), role: .manager, proof: proof, currentUID: geteuid())
            guard case let .success(.sessionClosed(receipt)) = result.outcome else { return XCTFail("missing receipt: \(scenario)") }
            XCTAssertNil(receipt.retainedBrowser, scenario)
            XCTAssertFalse(receipt.cleaned, scenario)
        }
    }

    #if SAFARIER_CONTROL_TESTING
    @MainActor func testBrokerDisconnectAfterAutomaticClose() async throws {
        for scenario in ["confirmed", "drainFailure"] {
            let profile = Profile(name: "broker automatic fixture", mode: .ephemeral)
            let endpoint = Endpoint(profile.id, mode: scenario == "drainFailure" ? .drainFailure : .normal)
            let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
                try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
            })
            manager.injectedOwnedRegistrationProof = { true }
            manager.setRegisteredConnector { _ in endpoint }
            let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
            var target: AutomationTargetIdentity?
            let broker = ControlBroker(testSender: { request in
                let reply = await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid())
                if case .success(.sessionOpened(_, let value, _)) = reply.outcome { target = value }
                return reply
            })
            func send(_ op: ControlOperation) async throws -> (ControlBrokerReply, UUID?) {
                let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: op))
                return (try JSONDecoder().decode(ControlBrokerReply.self, from: data), ack)
            }
            let (open, openAck) = try await send(.connect(profileID: profile.id))
            let connection = try XCTUnwrap(open.connection)
            broker.acknowledgement(try XCTUnwrap(openAck), received: true)
            try await Task.sleep(nanoseconds: 800_000_000)
            let count = await endpoint.closes
            XCTAssertEqual(count, 1, scenario)
            let (release, releaseAck) = try await send(.release(connection: connection))
            XCTAssertEqual(release.error, "SESSION_BUSY", scenario)
            broker.acknowledgement(try XCTUnwrap(releaseAck), received: true)
            let (closed, closeAck) = try await send(.disconnect(connection: connection))
            if scenario == "drainFailure" {
                XCTAssertEqual(closed.error, "CLEANUP_UNCONFIRMED")
                XCTAssertNil(closed.retainedBrowser)
            } else {
                XCTAssertEqual(closed.status, "ok", scenario)
                let expected = RetainedBrowserCleanup(target: try XCTUnwrap(target), inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)
                XCTAssertEqual(closed.retainedBrowser, expected)
                XCTAssertEqual(closed.cleaned, false)
                XCTAssertEqual(closed.terminatedOwnedRunner, false)
            }
            if scenario == "confirmed" {
                let pending = try XCTUnwrap(closeAck)
                let (before, _) = try await send(.daemonStop)
                XCTAssertEqual(before.error, "SESSION_BUSY", scenario)
                broker.acknowledgement(pending, received: true)
            } else { XCTAssertNil(closeAck) }
            let (after, _) = try await send(.daemonStop)
            if scenario == "confirmed" { XCTAssertEqual(after.status, "ok") }
            else { XCTAssertEqual(after.error, "SESSION_BUSY", scenario) }
        }
    }
    #endif
}
#endif
