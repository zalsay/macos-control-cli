import XCTest
@testable import SafarierCore

final class NavigationSubmissionTests: XCTestCase {
    func testSubmittedReplyRoundTripsAndAllowsObservationBeforeLoadFinishes() throws {
        let profile = UUID(), instance = UUID(), id = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let token = try AutomationSessionToken.generate()
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
        _ = machine.bind(target: target, viewport: view, at: 0)
        let request = AutomationRequest(version: 1, requestID: id, sessionID: token, action: .navigate(url: URL(string: "https://example.com/search?q=fixture")!))
        _ = machine.begin(request, permission: true, target: target, at: 1)
        let ticket = try XCTUnwrap(machine.currentTicket)
        let payload = Data("{\"version\":1,\"requestID\":\"\(id.uuidString)\",\"status\":\"ok\",\"effect\":\"navigationSubmitted\",\"result\":{\"viewVersion\":2}}".utf8)
        let submitted = try AutomationCodec.decodeReply(payload)
        XCTAssertEqual(try AutomationCodec.decodeReply(AutomationCodec.encode(submitted)), submitted)
        let completed = machine.complete(ticket: ticket, reply: submitted, at: 1.1)
        XCTAssertEqual(completed.count, 1)
        XCTAssertNil(machine.currentTicket)
        XCTAssertEqual(machine.state, .ready)
        let observe = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .screenshot)
        let effects = machine.begin(observe, permission: true, target: target, at: 1.2)
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(machine.currentTicket?.requestID, observe.requestID)
    }
    func testSubmittedReplyCannotCompleteWaitNavigationOrUseWrongVersion() throws {
        for (action, resultVersion): (AutomationAction, UInt64) in [
            (.navigateByInput(input: .enter, viewVersion: 1), 2),
            (.navigate(url: URL(string: "https://example.com/result")!), 1)
        ] {
            let profile = UUID(), instance = UUID()
            let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
            let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
            let token = try AutomationSessionToken.generate()
            let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0).get()
            _ = machine.bind(target: target, viewport: view, at: 0)
            let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: action)
            _ = machine.begin(request, permission: true, target: target, at: 1)
            let ticket = try XCTUnwrap(machine.currentTicket)
            _ = machine.complete(ticket: ticket, reply: AutomationReply(requestID: request.requestID, outcome: .success(.navigationSubmitted(viewVersion: resultVersion))), at: 1.1)
            XCTAssertEqual(machine.state, .stopping)
        }
    }

}
