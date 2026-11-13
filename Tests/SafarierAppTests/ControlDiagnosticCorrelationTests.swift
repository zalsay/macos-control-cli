#if SAFARIER_CONTROL_TESTING
import Foundation
import XCTest
import SafarierCore
@testable import Safarier

final class ControlDiagnosticCorrelationTests: XCTestCase {
    @MainActor func testSenderFailureClassificationDoesNotExposeErrorDetails() {
        XCTAssertEqual(ControlAppleEventClient.failureLabel(AutomationError(code: .invalidRequest)), "INVALID_REQUEST")
        XCTAssertEqual(ControlAppleEventClient.failureLabel(ControlAppleEventClient.Failure.unavailable), "sender_unavailable")
        XCTAssertEqual(ControlAppleEventClient.failureLabel(ControlAppleEventClient.Failure.indeterminate), "sender_indeterminate")
        XCTAssertEqual(ControlAppleEventClient.failureLabel(CancellationError()), "cancellation_error")
        XCTAssertEqual(ControlAppleEventClient.failureLabel(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "secret"))), "decoding_error")
        XCTAssertEqual(ControlAppleEventClient.failureLabel(EncodingError.invalidValue("secret", .init(codingPath: [], debugDescription: "secret"))), "encoding_error")
        XCTAssertEqual(ControlAppleEventClient.failureLabel(NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "secret"])), "ns_cocoa")
        XCTAssertEqual(ControlAppleEventClient.failureLabel(NSError(domain: "secret", code: 1)), "other")
    }
    @MainActor func testBrokerPreservesRequestIDsAcrossConnectObserveClickTypeAndClose() async throws {
        let profile = UUID(), token = String(repeating: "A", count: 43)
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        var forwarded: [UUID] = []
        let broker = ControlBroker(testSender: { request in
            forwarded.append(request.requestID)
            let result: AutomationResult
            switch request.action {
            case .openSession: result = .sessionOpened(sessionID: token, target: target, viewport: viewport)
            case .screenshot: result = .snapshotWritten(path: "/fixture", viewport: viewport)
            case .click, .insertText: result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
            case .closeSession: throw AutomationError(code: .backendUnavailable)
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }, testOCR: { _, _ in SemanticOCRResult(status: "unavailable", items: [], truncated: false) })
        var issued: [UUID] = []
        func send(_ operation: ControlOperation) async throws -> ControlBrokerReply {
            let id = UUID(); issued.append(id)
            let (data, ack) = await broker.handle(ControlRequest(requestID: id, operation: operation))
            let reply = try JSONDecoder().decode(ControlBrokerReply.self, from: data)
            XCTAssertEqual(reply.requestID, id)
            if let ack { broker.acknowledgement(ack, received: true) }
            return reply
        }
        let opened = try await send(.connect(profileID: profile))
        let connection = try XCTUnwrap(opened.connection)
        let observed = try await send(.observe(connection: connection))
        let frame = try XCTUnwrap(observed.frame)
        let clicked = try await send(.click(connection: connection, frame: frame, x: 1, y: 1, count: 1))
        let typed = try await send(.type(connection: connection, frame: frame, text: "private"))
        let closed = try await send(.disconnect(connection: connection))
        XCTAssertEqual(clicked.status, "ok")
        XCTAssertEqual(typed.status, "ok")
        XCTAssertEqual(closed.error, "BACKEND_UNAVAILABLE")
        XCTAssertEqual(forwarded, issued)
    }
}
#endif
