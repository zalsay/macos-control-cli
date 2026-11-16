#if SAFARIER_CONTROL_TESTING
import Foundation
import XCTest
import SafarierCore
@testable import Safarier

@MainActor final class ControlNavigationSubmissionTests: XCTestCase {
    func testSubmissionInvalidatesOldFrameAndAllowsObserveAndRelease() async throws {
        let profile = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        func viewport(_ version: UInt64) -> AutomationViewport {
            AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: version)
        }
        var version: UInt64 = 1
        var inputs = 0
        var navigationError: AutomationError?
        let broker = ControlBroker(testSender: { request in
            let result: AutomationResult
            switch request.action {
            case .openSession: result = .sessionOpened(sessionID: String(repeating: "A", count: 43), target: target, viewport: viewport(1))
            case .navigate:
                if let navigationError { throw navigationError }
                version += 1
                result = .navigationSubmitted(viewVersion: version)
            case .screenshot: result = .snapshotWritten(path: "/fixture", viewport: viewport(version))
            case .insertText: inputs += 1; result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: version)
            case .releaseControl: result = .controlReleased(ControlReleaseReceipt(target: target, transferID: UUID(), inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }, testOCR: { _, _ in SemanticOCRResult(status: "unavailable", items: [], truncated: false) })
        func send(_ operation: ControlOperation) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: operation))
            if let ack { broker.acknowledgement(ack, received: true) }
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        let connected = try await send(.connect(profileID: profile))
        let connection = try XCTUnwrap(connected.connection)
        let before = try await send(.observe(connection: connection))
        let oldFrame = try XCTUnwrap(before.frame)
        let submitted = try await send(.navigate(connection: connection, url: URL(string: "https://example.com/result")!))
        XCTAssertEqual(submitted.status, "ok")
        XCTAssertEqual(submitted.navigationSubmitted, true)
        XCTAssertEqual(submitted.effectVerified, false)
        XCTAssertEqual(submitted.viewVersion, 2)
        let staleInput = try await send(.type(connection: connection, frame: oldFrame, text: "stale"))
        XCTAssertEqual(staleInput.error, "INVALID_FRAME")
        XCTAssertEqual(inputs, 0)
        let observed = try await send(.observe(connection: connection))
        XCTAssertEqual(observed.status, "ok")
        XCTAssertEqual(observed.viewport?.viewVersion, 2)
        XCTAssertNotEqual(observed.frame, oldFrame)
        // A transport error must remain an error rather than a submitted claim.
        navigationError = AutomationError(code: .backendUnavailable, sideEffects: .possible)
        let failed = try await send(.navigate(connection: connection, url: URL(string: "https://example.com/other")!))
        XCTAssertEqual(failed.error, "BACKEND_UNAVAILABLE")
        XCTAssertNil(failed.navigationSubmitted)
        let released = try await send(.release(connection: connection))
        XCTAssertEqual(released.status, "ok")
        XCTAssertEqual(released.controlReleased?.manualInteractionEnabled, true)
    }
}
#endif
