#if SAFARIER_CONTROL_TESTING
import Foundation
import XCTest
import SafarierCore
@testable import Safarier

@MainActor final class ControlUncertaintyAdmissionTests: XCTestCase {
    // A lost ACK or rejected reply must not prevent the next explicit request
    // reaching Manager. The real broker still validates each new reply.
    @MainActor private final class Fixture {
        let profile = UUID()
        let token = String(repeating: "A", count: 43)
        lazy var target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        var nextStateOutcome: AutomationOutcome?
        var nextOpenError: Error?
        var nextStateError: Error?
        var releaseConfirmed = true
        lazy var broker = ControlBroker(testSender: { request in
            let result: AutomationResult
            switch request.action {
            case .openSession:
                if let error = self.nextOpenError { self.nextOpenError = nil; throw error }
                result = .sessionOpened(sessionID: self.token, target: self.target, viewport: self.viewport)
            case .getState:
                if let error = self.nextStateError { self.nextStateError = nil; throw error }
                if let outcome = self.nextStateOutcome {
                    self.nextStateOutcome = nil
                    return AutomationReply(requestID: request.requestID, outcome: outcome)
                }
                result = .stateRead(AutomationState(target: self.target, url: nil, loading: false, sessionState: .ready, viewVersion: 1))
            case .screenshot: result = .snapshotWritten(path: "/fixture", viewport: self.viewport)
            case .insertText: result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
            case .releaseControl:
                result = .controlReleased(ControlReleaseReceipt(target: self.target, transferID: UUID(), inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: self.releaseConfirmed))
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }, testOCR: { _, _ in SemanticOCRResult(status: "unavailable", items: [], truncated: false) })

        func send(_ operation: ControlOperation, received: Bool = true) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: operation))
            if let ack { broker.acknowledgement(ack, received: received) }
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        func connect(received: Bool = true) async throws -> UUID {
            let reply = try await send(.connect(profileID: profile), received: received)
            return try XCTUnwrap(reply.connection)
        }
        func assertCanReadTypeAndRelease(_ connection: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
            let state = try await send(.state(connection: connection))
            XCTAssertEqual(state.state?.target, target, file: file, line: line)
            let observation = try await send(.observe(connection: connection))
            let frame = try XCTUnwrap(observation.frame, file: file, line: line)
            let typed = try await send(.type(connection: connection, frame: frame, text: "fixture"))
            XCTAssertEqual(typed.sequence, 1, file: file, line: line)
            let released = try await send(.release(connection: connection))
            XCTAssertEqual(released.status, "ok", file: file, line: line)
            XCTAssertEqual(released.controlReleased?.target, target, file: file, line: line)
        }
    }

    func testLostConnectAcknowledgementAllowsReadInputAndRelease() async throws {
        let fixture = Fixture()
        let connection = try await fixture.connect(received: false)
        try await fixture.assertCanReadTypeAndRelease(connection)
    }

    func testLostObservationAcknowledgementAllowsNextExplicitRequest() async throws {
        let fixture = Fixture(), connection = try await fixture.connect()
        let observed = try await fixture.send(.observe(connection: connection), received: false)
        XCTAssertNotNil(observed.frame)
        try await fixture.assertCanReadTypeAndRelease(connection)
    }

    func testIndeterminateAndTransportErrorsDoNotBlockNextExplicitRequest() async throws {
        for error: Error in [AutomationError(code: .indeterminateResult, sideEffects: .possible),
                            AutomationError(code: .timeout, sideEffects: .delivered),
                            ControlAppleEventClient.Failure.indeterminate] {
            let fixture = Fixture(), connection = try await fixture.connect()
            fixture.nextStateError = error
            let failed = try await fixture.send(.state(connection: connection))
            XCTAssertEqual(failed.status, "error")
            try await fixture.assertCanReadTypeAndRelease(connection)
        }
    }

    func testRejectedReplyDoesNotDisableNextRequestOrWeakenTargetValidation() async throws {
        let fixture = Fixture(), connection = try await fixture.connect()
        let wrong = AutomationTargetIdentity(profileID: fixture.profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        for outcome in [AutomationOutcome.success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)),
                        .success(.stateRead(AutomationState(target: wrong, url: nil, loading: false, sessionState: .ready, viewVersion: 1)))] {
            fixture.nextStateOutcome = outcome
            let rejected = try await fixture.send(.state(connection: connection))
            XCTAssertEqual(rejected.status, "error")
            XCTAssertNil(rejected.state)
            let recovered = try await fixture.send(.state(connection: connection))
            XCTAssertEqual(recovered.state?.target, fixture.target)
        }
        try await fixture.assertCanReadTypeAndRelease(connection)
    }

    func testUnconfirmedReleaseStillFailsButDoesNotBlockState() async throws {
        let fixture = Fixture(), connection = try await fixture.connect()
        fixture.releaseConfirmed = false
        let rejected = try await fixture.send(.release(connection: connection))
        XCTAssertEqual(rejected.error, "INVALID_REPLY")
        XCTAssertNil(rejected.controlReleased)
        let state = try await fixture.send(.state(connection: connection))
        XCTAssertEqual(state.state?.target, fixture.target)
    }

    func testFailedConnectDoesNotBlockNextExplicitConnect() async throws {
        let fixture = Fixture()
        fixture.nextOpenError = AutomationError(code: .indeterminateResult, sideEffects: .possible)
        let failed = try await fixture.send(.connect(profileID: fixture.profile))
        XCTAssertEqual(failed.error, "INDETERMINATE_RESULT")
        let connection = try await fixture.connect()
        try await fixture.assertCanReadTypeAndRelease(connection)
    }

    func testLostConnectAcknowledgementDoesNotBlockAnotherConnect() async throws {
        let fixture = Fixture()
        _ = try await fixture.connect(received: false)
        let connection = try await fixture.connect()
        let state = try await fixture.send(.state(connection: connection))
        XCTAssertEqual(state.state?.target, fixture.target)
    }

    func testOutstandingAcknowledgementDoesNotBlockNextExplicitCommand() async throws {
        let fixture = Fixture()
        let (data, ack) = await fixture.broker.handle(ControlRequest(requestID: UUID(), operation: .connect(profileID: fixture.profile)))
        let opened = try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        let connection = try XCTUnwrap(opened.connection)
        let waiting = try await fixture.send(.state(connection: connection))
        XCTAssertEqual(waiting.status, "ok")
        fixture.broker.acknowledgement(try XCTUnwrap(ack), received: true)
        try await fixture.assertCanReadTypeAndRelease(connection)
    }
}
#endif
