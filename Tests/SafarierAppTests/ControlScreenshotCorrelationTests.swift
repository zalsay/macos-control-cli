#if SAFARIER_CONTROL_TESTING
import XCTest
import Foundation
import SafarierCore
@testable import Safarier

@MainActor final class ControlScreenshotCorrelationTests: XCTestCase {
    func testClickTargetReportsScreenshotChildBeforeExchange() async throws {
        let profile = UUID(), parent = UUID()
        let identity = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        var links: [(UUID, UUID)] = [], screenshotID: UUID?
        let broker = ControlBroker(testSender: { request in
            switch request.action {
            case .openSession:
                return AutomationReply(requestID: request.requestID, outcome: .success(.sessionOpened(sessionID: String(repeating: "A", count: 43), target: identity, viewport: viewport)))
            case .screenshot:
                screenshotID = request.requestID
                XCTAssertEqual(links.count, 1)
                XCTAssertEqual(links.first?.0, parent)
                XCTAssertEqual(links.first?.1, request.requestID)
                throw AutomationError(code: .backendUnavailable)
            default: throw AutomationError(code: .invalidRequest)
            }
        }, testConfig: { ControlDecisionConfig(endpoint: URL(string: "https://example.test")!, model: "fixture", key: "fixture") }, testChildDiagnostic: { parent, child in
            links.append((parent, child))
        })
        let (opened, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: .connect(profileID: profile)))
        let connection = try XCTUnwrap(JSONDecoder().decode(ControlBrokerReply.self, from: opened).connection)
        broker.acknowledgement(try XCTUnwrap(ack), received: true)
        let (reply, _) = await broker.handle(ControlRequest(requestID: parent, operation: .clickTarget(connection: connection, target: "private")))
        XCTAssertEqual(try JSONDecoder().decode(ControlBrokerReply.self, from: reply).error, "BACKEND_UNAVAILABLE")
        XCTAssertNotNil(screenshotID)
        XCTAssertNotEqual(screenshotID, parent)
    }
}
#endif
