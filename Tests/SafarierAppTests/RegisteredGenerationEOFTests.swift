import XCTest
@testable import SafarierCore

/// Exercises the actual V1 handoff/response/EOF path without a signed App context.
/// Registered identity validation itself still requires the packaged Binder fixture.
final class RegisteredGenerationEOFTests: XCTestCase {
    func testReleaseReplyThenClientCloseReturnsZeroFromHandoff() async throws {
        let pair = try AutomationChannel.makePair()
        let channel = try AutomationChannel(adopting: pair.child)
        defer { pair.parent.close(); channel.close() }
        let profile = UUID(), instance = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
        let server = AutomationRunnerServer(profileID: profile, runnerInstanceID: instance, channel: channel, idleSeconds: 2, handler: { _ in
            .success(.controlReleased(ControlReleaseReceipt(target: target, transferID: UUID(), inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)))
        }, shutdown: {})
        let running = Task.detached { () -> Int32 in
            do {
                let deadline = try FrameDeadline(lifetimeStart: DispatchTime.now().uptimeNanoseconds)
                let pending = try await server.beginV1Handshake(deadline: deadline)
                let handoff = try await server.sendV1Ready(pending, deadline: deadline)
                return await server.serveV1Handoff(handoff, prepare: {})
            } catch { return 1 }
        }
        let nonce = try AutomationSessionToken.generate()
        try await pair.parent.send(AutomationHandshakeCodec.makeChallenge(profileID: profile, nonce: nonce))
        let hello = try await pair.parent.receive()
        XCTAssertNotNil(hello)
        try await pair.parent.send(AutomationCodec.encodeRequest(AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(), action: .commitControlRelease(transferID: UUID()))))
        guard let data = try await pair.parent.receive(), case let .success(.controlReleased(receipt)) = try AutomationCodec.decodeReply(data).outcome else { return XCTFail("missing receipt") }
        XCTAssertEqual(receipt.target, target)
        XCTAssertTrue(receipt.inputReleased && receipt.artifactsCleaned && receipt.browserRetained && receipt.manualInteractionEnabled)
        pair.parent.close()
        let status = await running.value
        XCTAssertEqual(status, 0)
    }
}
