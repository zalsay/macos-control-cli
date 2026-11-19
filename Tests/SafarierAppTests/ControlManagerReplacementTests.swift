#if SAFARIER_CONTROL_TESTING
import Foundation
import XCTest
import SafarierCore
@testable import Safarier

@MainActor final class ControlManagerReplacementTests: XCTestCase {
    func testOnlyExplicitConnectRebindsAndRetiresOldConnections() async throws {
        let profile = UUID(), oldToken = try AutomationSessionToken.generate(), newToken = try AutomationSessionToken.generate()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        var oldCalls: [AutomationAction] = [], newCalls: [AutomationAction] = [], oldExited = false, refreshes = 0
        func opened(_ request: AutomationRequest, _ token: String) -> AutomationReply {
            AutomationReply(requestID: request.requestID, outcome: .success(.sessionOpened(sessionID: token, target: target, viewport: viewport)))
        }
        let broker = ControlBroker(testSender: { request in
            oldCalls.append(request.action)
            guard !oldExited else { throw ControlAppleEventClient.Failure.unavailable }
            return opened(request, oldToken)
        }, testRefreshOnConnect: {
            refreshes += 1
            guard oldExited else { return nil }
            return { request in
                newCalls.append(request.action)
                XCTAssertNil(request.sessionID)
                return opened(request, newToken)
            }
        })
        func send(_ operation: ControlOperation) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: operation))
            if let ack { broker.acknowledgement(ack, received: true) }
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        let first = try await send(.connect(profileID: profile))
        let previous = try XCTUnwrap(first.connection)
        oldExited = true
        _ = try await send(.state(connection: previous))
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(newCalls.isEmpty)
        let second = try await send(.connect(profileID: profile))
        XCTAssertNotEqual(try XCTUnwrap(second.connection), previous)
        let stale = try await send(.state(connection: previous))
        XCTAssertEqual(stale.error, "SESSION_NOT_FOUND")
        XCTAssertEqual(oldCalls, [.openSession(profileID: profile), .getState])
        XCTAssertEqual(newCalls, [.openSession(profileID: profile)])
    }
}
#endif
