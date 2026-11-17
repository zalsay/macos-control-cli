import XCTest
@testable import SafarierCore

final class RegisteredExecutionLifetimeTests: XCTestCase {
    func testRegisteredFrameUsesOperationDeadlineAfterOriginalGeneration() throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let start = now - 100_000_000_000
        let deadline = try FrameDeadline(lifetimeStart: start, registeredInteractive: true)
        XCTAssertGreaterThan(try deadline.remaining(), 0)
        XCTAssertThrowsError(try FrameDeadline(lifetimeStart: start))
    }

    func testRegisteredSessionSurvivesIdleAndReplaysCompletedInput() throws {
        let profile = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0, registeredInteractive: true).get()
        XCTAssertTrue(machine.bind(target: target, viewport: view, at: 0).isEmpty)
        let input = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .navigateByInput(input: .enter, viewVersion: 1))
        guard case .dispatch(let ticket, _) = machine.begin(input, permission: true, target: target, at: 120).first else { return XCTFail("idle should not close registered control") }
        let receipt = AutomationReply(requestID: input.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        XCTAssertTrue(machine.complete(ticket: ticket, reply: receipt, at: 121).contains { if case .completion(_, let actual) = $0 { return actual == receipt }; return false })
        XCTAssertTrue(machine.begin(input, permission: true, target: target, at: 240).contains { if case .reply(let actual) = $0 { return actual == receipt }; return false })
        XCTAssertEqual(machine.state, .ready)
    }
    func testRegisteredSnapshotsSurviveTimeAndRotateAfter32() throws {
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(".build/automation-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let base = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let clock = AutomationSnapshotCases.Clock()
        let store = try AutomationSnapshotStore(baseDirectory: base, clock: { clock.get() })
        store.useRegisteredSessionLifetime()
        let view = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let png = Data([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,0,0,0,0])
        var paths: [URL] = []
        for index in 0..<33 {
            clock.set(Double(index * 30))
            paths.append(try store.write(png: png, viewport: view))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0].path))
        XCTAssertTrue(paths.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(store.close().cleaned)
    }
    func testRegisteredReplayRetainsAllRequestIDsPastFixtureCapacity() {
        var replay = AutomationReplayCache(startedAt: 0, expiresWhenIdle: false)
        var first: AutomationRequest?
        for _ in 0..<300 {
            let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "A", count: 43), action: .getState)
            if first == nil { first = request }
            XCTAssertEqual(replay.begin(request, at: 1), .reserved)
            let reply = AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .timeout)))
            XCTAssertTrue(replay.complete(request, reply: reply, at: 1))
        }
        if case .replay = replay.begin(first!, at: 600) {} else { XCTFail("first request must retain its receipt") }
    }
    func testRegisteredGeometryEventDuringInputDoesNotRevokeReceipt() throws {
        let profile = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let updated = AutomationViewport(viewportWidthPoints: 110, viewportHeightPoints: 80, pixelWidth: 220, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 2)
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0, registeredInteractive: true).get()
        _ = machine.bind(target: target, viewport: view, at: 0)
        let input = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))
        guard case .dispatch(let ticket, _) = machine.begin(input, permission: true, target: target, at: 1).first else { return XCTFail("dispatch") }
        XCTAssertTrue(machine.event(.geometryChanged(target: target, viewport: updated), at: 1.1).isEmpty)
        let receipt = AutomationReply(requestID: input.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        XCTAssertTrue(machine.complete(ticket: ticket, reply: receipt, at: 2).contains { if case .completion(_, let actual) = $0 { return actual == receipt }; return false })
        XCTAssertTrue(machine.synchronizeViewport(target: target, viewport: updated))
        XCTAssertEqual(machine.state, .ready)
    }
    func testRegisteredReleaseCanDrainHeldInputAfterLongIdle() throws {
        let profile = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let token = String(repeating: "A", count: 43)
        let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0, registeredInteractive: true).get()
        _ = machine.bind(target: target, viewport: view, at: 0)
        let down = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .mouseDown(point: ViewportPoint(x: 1, y: 1), viewVersion: 1))
        guard case .dispatch(let downTicket, _) = machine.begin(down, permission: true, target: target, at: 1).first else { return XCTFail("down dispatch") }
        _ = machine.complete(ticket: downTicket, reply: AutomationReply(requestID: down.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 1, viewVersion: 1))), at: 2)
        XCTAssertTrue(machine.tick(at: 30).isEmpty)
        let release = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl)
        guard case .dispatch(let releaseTicket, _) = machine.begin(release, permission: true, target: target, at: 31).first else { return XCTFail("held release dispatch") }
        let transfer = UUID()
        let prepared = ControlReleasePreparation(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true)
        let result = AutomationReply(requestID: release.requestID, outcome: .success(.controlReleasePrepared(prepared)))
        XCTAssertTrue(machine.complete(ticket: releaseTicket, reply: result, at: 32).contains { if case .completion(_, let actual) = $0 { return actual == result }; return false })
        XCTAssertEqual(machine.state, .ready)
        let commit = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: transfer))
        guard case .dispatch = machine.begin(commit, permission: true, target: target, at: 33).first else { return XCTFail("commit dispatch") }
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func testRegisteredEpochHistoryRetainsOldIDsBeyondFormerCapacity() {
        var history = RegistrationEpochHistory()
        let first = UUID()
        XCTAssertTrue(history.accept(first))
        for _ in 0..<4096 { XCTAssertTrue(history.accept(UUID())) }
        XCTAssertFalse(history.accept(first))
    }
    #endif
}
