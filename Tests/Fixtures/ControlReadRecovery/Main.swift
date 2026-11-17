import Foundation

@main enum Main {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func request(_ action: AutomationAction) -> AutomationRequest { AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "A", count: 43), action: action) }
    static let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
    static func response(_ id: UUID) -> AutomationReply { AutomationReply(requestID: id, outcome: .success(.snapshotWritten(path: "/fixture", viewport: view))) }
    static func send(_ client: AutomationRunnerClient, _ request: AutomationRequest, timeout: Double = 0.2) -> Task<Result<AutomationReply, Error>, Never> {
        Task { do { return .success(try await client.request(request, timeoutSeconds: timeout)) } catch { return .failure(error) } }
    }
    static func ready(_ client: AutomationRunnerClient, _ id: UUID) async throws {
        for _ in 0..<1000 { if await client.fixtureReady(id) { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw Failure(message: "request did not finish sending")
    }
    static func expectFailure(_ result: Result<AutomationReply, Error>, _ code: AutomationErrorCode) throws {
        guard case .failure(let error as AutomationError) = result else { throw Failure(message: "expected caller error") }
        try check(error.code == code && error.sideEffects == .none, "incorrect read error or side effects")
    }
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let mode = CommandLine.arguments[1]
        let registered = mode != "legacy"
        let delay: Duration = ["validation-race", "early-reply"].contains(mode) ? .milliseconds(300) : .zero
        let client = AutomationRunnerClient.fixture(registered: registered, validationDelay: delay, sendDelay: mode == "early-reply" ? .milliseconds(50) : .zero)
        let target = await client.fixtureTarget()
        if mode == "release" {
            let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: target.profileID))
            let opening = send(client, open, timeout: 2)
            try await ready(client, open.requestID)
            let accepted = await client.fixtureDeliver(AutomationReply(requestID: open.requestID, outcome: .success(.sessionOpened(sessionID: String(repeating: "A", count: 43), target: target, viewport: view))))
            try check(accepted, "open reply rejected")
            _ = await opening.value
        }
        let first = request(mode == "input" ? .insertText("fixture") : .screenshot)
        let caller = send(client, first)
        if mode == "early-reply" {
            for _ in 0..<1000 { if await client.fixtureBytesSent(first.requestID) { break }; try await Task.sleep(for: .milliseconds(1)) }
        } else { try await ready(client, first.requestID) }
        if mode == "cancel" { caller.cancel() }
        if ["validation-race", "early-reply"].contains(mode) {
            let accepted = await client.fixtureDeliver(response(first.requestID))
            try check(accepted, "validation crossing a read deadline closed the reader")
        }
        let result = await caller.value
        if mode == "legacy" || mode == "input" {
            try check(await client.fixtureClosed(), "nonregistered or native-input timeout must still close")
            print("PASS", mode); return
        }
        try expectFailure(result, mode == "cancel" ? .cancelled : .timeout)
        try check(await !client.fixtureClosed(), "read timeout/cancel closed channel")
        if mode == "release" {
            let transfer = UUID()
            let receipt = ControlReleaseReceipt(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)
            let stages: [(AutomationAction, AutomationResult)] = [
                (.releaseControl, .controlReleasePrepared(ControlReleasePreparation(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true))),
                (.commitControlRelease(transferID: transfer), .controlReleased(receipt))
            ]
            for (action, value) in stages {
                let command = request(action), pending = send(client, command, timeout: 2)
                try await ready(client, command.requestID)
                try check(await client.fixtureDeliver(AutomationReply(requestID: command.requestID, outcome: .success(value))), "release reply rejected")
                guard case .success = await pending.value else { throw Failure(message: "release caller failed") }
            }
            _ = try await client.takeValidatedReleasedOwner(matching: receipt)
            try check(await client.fixtureClosed(), "validated handoff did not complete")
            try check(await !client.fixturePending(first.requestID), "retired read blocked handoff cleanup")
            print("PASS", mode); return
        }
        if mode == "unknown" || mode == "wrong-kind" {
            let reply = mode == "unknown" ? response(UUID()) : AutomationReply(requestID: first.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
            let accepted = await client.fixtureDeliver(reply)
            let closed = await client.fixtureClosed()
            try check(!accepted && closed, "invalid late reply was accepted")
            print("PASS", mode); return
        }
        let next = request(.screenshot), nextCaller = send(client, next, timeout: 2)
        try await ready(client, next.requestID)
        if !["validation-race", "early-reply"].contains(mode) {
            try check(await client.fixtureDeliver(response(first.requestID)), "late correlated read closed reader")
            try check(await client.fixturePending(next.requestID), "late read consumed the next request")
        }
        try check(await client.fixtureDeliver(response(next.requestID)), "next read could not complete")
        guard case .success(let nextReply) = await nextCaller.value else { throw Failure(message: "next caller failed") }
        try check(nextReply == response(next.requestID), "next caller received the wrong result")
        await client.close()
        print("PASS", mode)
    }
}
