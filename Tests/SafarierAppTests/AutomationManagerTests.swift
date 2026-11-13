import Foundation
import XCTest
import Darwin
import SafarierCore
@testable import Safarier

final class AutomationManagerTests: XCTestCase {
    #if SAFARIER_CONTROL_TESTING
    @MainActor func testObserveAndInputReuseOpenedSession() async throws {
        let profile = UUID(), token = String(repeating: "A", count: 43)
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        var actions: [String] = []
        let broker = ControlBroker(testSender: { request in
            let result: AutomationResult
            switch request.action {
            case .openSession:
                actions.append("open"); result = .sessionOpened(sessionID: token, target: target, viewport: viewport)
            case .screenshot:
                XCTAssertEqual(request.sessionID, token); actions.append("observe")
                result = .snapshotWritten(path: "/fixture", viewport: viewport)
            case .click:
                XCTAssertEqual(request.sessionID, token); actions.append("click")
                result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
            case .insertText:
                XCTAssertEqual(request.sessionID, token); actions.append("type")
                result = .nativeDelivered(sequence: 2, buttons: 0, viewVersion: 1)
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }, testOCR: { _, _ in SemanticOCRResult(status: "unavailable", items: [], truncated: false) })
        func request(_ operation: ControlOperation) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: operation))
            let reply = try JSONDecoder().decode(ControlBrokerReply.self, from: data)
            XCTAssertEqual(reply.status, "ok")
            if let ack { broker.acknowledgement(ack, received: true) }
            return reply
        }
        let opened = try await request(.connect(profileID: profile))
        let connection = try XCTUnwrap(opened.connection)
        let observed = try await request(.observe(connection: connection))
        let frame = try XCTUnwrap(observed.frame)
        _ = try await request(.click(connection: connection, frame: frame, x: 10, y: 10, count: 1))
        _ = try await request(.type(connection: connection, frame: frame, text: "fixture"))
        _ = try await request(.observe(connection: connection))
        XCTAssertEqual(actions, ["open", "observe", "click", "type", "observe"])
    }
    @MainActor func testReleaseAcknowledgementGatesDaemonStop() async throws {
        let profile = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let receipt = ControlReleaseReceipt(target: target, transferID: UUID(), inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)
        func makeBroker() -> ControlBroker {
            ControlBroker(testSender: { request in
                switch request.action {
                case .openSession: return AutomationReply(requestID: request.requestID, outcome: .success(.sessionOpened(sessionID: String(repeating: "A", count: 43), target: target, viewport: viewport)))
                case .releaseControl: return AutomationReply(requestID: request.requestID, outcome: .success(.controlReleased(receipt)))
                default: throw AutomationError(code: .invalidRequest)
                }
            })
        }
        func setup(_ broker: ControlBroker) async throws -> UUID {
            let connect = ControlRequest(requestID: UUID(), operation: .connect(profileID: profile))
            let (data, ack) = await broker.handle(connect)
            let response = try JSONDecoder().decode(ControlBrokerReply.self, from: data)
            guard let connection = response.connection, let ack else { throw AutomationError(code: .invalidRequest) }
            broker.acknowledgement(ack, received: true)
            let release = ControlRequest(requestID: UUID(), operation: .release(connection: connection))
            let (released, releaseAck) = await broker.handle(release)
            XCTAssertEqual(try JSONDecoder().decode(ControlBrokerReply.self, from: released).status, "ok")
            guard let releaseAck else { throw AutomationError(code: .invalidRequest) }
            return releaseAck
        }
        func stop(_ broker: ControlBroker) async throws -> ControlBrokerReply {
            let (data, _) = await broker.handle(ControlRequest(requestID: UUID(), operation: .daemonStop))
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        let acknowledged = makeBroker(), ack = try await setup(acknowledged)
        let before = try await stop(acknowledged)
        XCTAssertEqual(before.error, "SESSION_BUSY")
        acknowledged.acknowledgement(ack, received: true)
        let after = try await stop(acknowledged)
        XCTAssertEqual(after.status, "ok")
        let lost = makeBroker(), lostAck = try await setup(lost)
        lost.acknowledgement(lostAck, received: false)
        let failed = try await stop(lost)
        XCTAssertEqual(failed.error, "SESSION_BUSY")
    }
    #endif
    @MainActor func testReleaseFailureReplayAndIDConflict() async throws {
        let profile = Profile(name: "fixture", mode: .ephemeral, allowsBackgroundAutomation: true)
        let endpoint = AutomationManagerCases.FakeEndpoint(profileID: profile.id)
        let manager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        })
        let uid = geteuid()
        let proof = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let opened = await manager.handle(open, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let token, _, _)) = opened.outcome else { return XCTFail("open") }
        let release = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl)
        let first = await manager.handle(release, role: .manager, proof: proof, currentUID: uid)
        let replay = await manager.handle(release, role: .manager, proof: proof, currentUID: uid)
        let conflict = AutomationRequest(version: 1, requestID: release.requestID, sessionID: token, action: .getState)
        let conflictReply = await manager.handle(conflict, role: .manager, proof: proof, currentUID: uid)
        // Release is a prepare/commit protocol. The fixture intentionally does
        // not implement the prepare reply, so Manager must report the result as
        // indeterminate after the request was forwarded.
        XCTAssertEqual(first.outcome, .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible)))
        XCTAssertEqual(replay, first)
        XCTAssertEqual(conflictReply.outcome, .failure(AutomationError(code: .requestIDReused)))
        let counts = await endpoint.counts()
        XCTAssertEqual(counts.0, 2)
    }
    @MainActor func testCases() async throws {
        let count = try await AutomationManagerCases.run()
        XCTAssertGreaterThan(count, 0)
    }
}
