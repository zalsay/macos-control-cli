import XCTest
@testable import SafarierCore

private actor PrepareDeadlineCounter {
    var dispatched = 0
    var preparations = 0
    func markDispatch() { dispatched += 1 }
    func markPreparation() { preparations += 1 }
    func count() -> Int { dispatched }
    func preparationCount() -> Int { preparations }
}

final class RegisteredPrepareDeadlineTests: XCTestCase {
    func testHandshakeAndPreparationShareFrameDeadlineAndDoNotDispatchAfterTimeout() async throws {
        let pair = try AutomationChannel.makePair()
        let channel = try AutomationChannel(adopting: pair.child)
        defer { pair.parent.close(); channel.close() }
        let profile = UUID(), counter = PrepareDeadlineCounter()
        let server = AutomationRunnerServer(profileID: profile, channel: channel, idleSeconds: 2, handler: { _ in
            await counter.markDispatch()
            return .failure(AutomationError(code: .backendUnavailable))
        }, shutdown: {})
        let running = Task.detached { () -> Int32 in
            do {
                let deadline = try FrameDeadline(lifetimeStart: DispatchTime.now().uptimeNanoseconds)
                let pending = try await server.beginV1Handshake(deadline: deadline)
                // Each phase fits a frame independently, but their combined time
                // exceeds the original cutoff. Keep this valid as limits change.
                let phaseDelay = AutomationLimits.frameSeconds * 0.65
                try await Task.sleep(for: .seconds(phaseDelay))
                let handoff = try await server.sendV1Ready(pending, deadline: deadline)
                return await server.serveV1Handoff(handoff, prepare: {
                    await counter.markPreparation()
                    try? await Task.sleep(for: .seconds(phaseDelay))
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
        let preparations = await counter.preparationCount()
        XCTAssertEqual(preparations, 1, "timeout must occur during preparation, not before the handoff")
        XCTAssertEqual(count, 0)
    }
}
