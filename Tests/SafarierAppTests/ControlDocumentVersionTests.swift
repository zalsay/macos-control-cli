#if SAFARIER_CONTROL_TESTING
import XCTest
import Foundation
import SafarierCore
@testable import Safarier

@MainActor final class ControlDocumentVersionTests: XCTestCase {
    func testDocumentChangesDoNotRejectExplicitInputOrRetainedFrames() async throws {
        let profile = UUID(), token = String(repeating: "A", count: 43)
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        func viewport(_ version: UInt64) -> AutomationViewport { AutomationViewport(viewportWidthPoints: 10, viewportHeightPoints: 10, pixelWidth: 10, pixelHeight: 10, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: version) }
        var document: UInt64 = 1, versions: [UInt64?] = []
        let broker = ControlBroker(testSender: { request in
            let result: AutomationResult
            switch request.action {
            case .openSession: result = .sessionOpened(sessionID: token, target: target, viewport: viewport(1))
            case .screenshot: result = .snapshotWritten(path: "/fixture", viewport: viewport(document))
            case .insertText, .key:
                versions.append(request.expectedViewVersion)
                result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: document)
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }, testOCR: { _, _ in SemanticOCRResult(status: "unavailable", items: [], truncated: false) })
        func send(_ operation: ControlOperation) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: operation))
            if let ack { broker.acknowledgement(ack, received: true) }
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        let opened = try await send(.connect(profileID: profile))
        let connection = try XCTUnwrap(opened.connection)
        let first = try await send(.observe(connection: connection))
        let oldFrame = try XCTUnwrap(first.frame)
        document = 2
        let oldText = try await send(.type(connection: connection, frame: oldFrame, text: "x"))
        XCTAssertEqual(oldText.status, "ok")
        XCTAssertEqual(oldText.effectVerified, false)
        let fresh = try await send(.observe(connection: connection))
        XCTAssertEqual(fresh.viewport?.viewVersion, 2)
        let newFrame = try XCTUnwrap(fresh.frame)
        let oldKey = try await send(.press(connection: connection, frame: oldFrame, key: .enter, shift: false))
        XCTAssertEqual(oldKey.status, "ok")
        let newKey = try await send(.press(connection: connection, frame: newFrame, key: .enter, shift: false))
        XCTAssertEqual(newKey.status, "ok")
        XCTAssertEqual(versions, [nil, nil, nil])
    }
}
#endif
