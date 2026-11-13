import XCTest
@testable import SafarierCore

private actor PrepareDeadlineCounter {
    var dispatched = 0
    func markDispatch() { dispatched += 1 }
    func count() -> Int { dispatched }
}

final class RegisteredPrepareDeadlineTests: XCTestCase {
    func testHandshakeAndPreparationShareFrameDeadlineAndDoNotDispatchAfterTimeout() async throws {
        let pair = try AutomationChannel.makePair()
        let channel = try AutomationChannel(adopting: pair.child)
        defer { pair.parent.close(); channel.close() }
        let profile = UUID(), counter = PrepareDeadlineCounter()
        let server = AutomationRunnerServer(profileID: profile, channel: channel, handler: { _ in
            await counter.markDispatch()
            return .failure(AutomationError(code: .backendUnavailable))
        }, shutdown: {})
        let running = Task.detached { () -> Int32 in
            do {
                let deadline = try FrameDeadline(lifetimeStart: DispatchTime.now().uptimeNanoseconds)
                let pending = try await server.beginV1Handshake(deadline: deadline)
                try await Task.sleep(for: .milliseconds(1600))
                let handoff = try await server.sendV1Ready(pending, deadline: deadline)
                return await server.serveV1Handoff(handoff, prepare: {
                    try? await Task.sleep(for: .milliseconds(2000))
                })
            } catch { return 1 }
        }
        let nonce = try AutomationSessionToken.generate()
        try await pair.parent.send(AutomationHandshakeCodec.makeChallenge(profileID: profile, nonce: nonce))
        let response = try await pair.parent.receive()
        XCTAssertNotNil(response)
        try await pair.parent.send(AutomationCodec.encodeRequest(AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .commitControlRelease(transferID: UUID()))))
        let status = await running.value
        XCTAssertEqual(status, 1)
        let count = await counter.count()
        XCTAssertEqual(count, 0)
    }
}
