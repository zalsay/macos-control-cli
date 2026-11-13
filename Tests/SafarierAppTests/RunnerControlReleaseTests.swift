import XCTest
@testable import Safarier
@testable import SafarierCore

@MainActor
final class RunnerControlReleaseTests: XCTestCase {
    func testCommitPostPermissionCrossesDeadlineWithUnconfirmedBorrowedCleanup() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"], !fixture.isEmpty else { throw XCTSkip("private release fixture not configured") }
        let root = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), instance = UUID()
        let page = Page(AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        let clock = RunnerAutomationControllerCases.VirtualClock()
        let postPermission = RunnerAutomationControllerCases.Gate<Bool>()
        let service = RunnerAutomationService(profileID: profile, runnerInstanceID: instance, permissionReader: {
            if page.committed == 1 { return await postPermission.wait() }
            return true
        }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: root) },
           now: { clock.instant }, sleepUntil: { if $0 > clock.instant { await clock.sleep($0) } }, pageOwnership: .borrowed)
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile)))
        guard case .success(.sessionOpened(let token, _, _)) = open.outcome else { return XCTFail("open") }
        let prepare = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.controlReleasePrepared(let proof)) = prepare.outcome else { return XCTFail("prepare") }
        let commit = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: proof.transferID))
        let pending = Task { await service.handle(commit) }
        try await RunnerAutomationControllerCases.waitUntil("post-commit permission not reached") { postPermission.waits.count == 1 && clock.waits.contains { $0.deadline == AutomationLimits.actionSeconds } }
        XCTAssertEqual(page.committed, 1)
        XCTAssertEqual(page.finalized, 0)
        clock.advance(AutomationLimits.actionSeconds / 2 + 0.1)
        await RunnerAutomationControllerCases.drain()
        XCTAssertEqual(page.detached, 0, "old five-second deadline must not end the release")
        clock.advance(AutomationLimits.actionSeconds)
        let reply = await pending.value
        XCTAssertEqual(reply.outcome, .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible)))
        try await RunnerAutomationControllerCases.waitUntil("borrowed cleanup not attempted") { page.detached == 1 }
        postPermission.release(true)
        await RunnerAutomationControllerCases.drain()
        let drained = await service.shutdownAndDrain()
        XCTAssertFalse(drained, "failed borrowed detach cannot prove cleanup")
        XCTAssertEqual(page.detached, 1)
        XCTAssertEqual(page.destroyed, 0)
        XCTAssertEqual(page.finalized, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        clock.advance(100)
    }

    func testSlowPermissionChecksConsumeSharedReleaseDeadline() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"], !fixture.isEmpty else { throw XCTSkip("private release fixture not configured") }
        let root = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), instance = UUID()
        let page = Page(AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        var slow = false
        let service = RunnerAutomationService(profileID: profile, runnerInstanceID: instance, permissionReader: {
            if slow { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            return true
        }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: root) })
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile)))
        guard case .success(.sessionOpened(let token, _, _)) = open.outcome else { return XCTFail("open") }
        slow = true
        let prepare = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.controlReleasePrepared(let proof)) = prepare.outcome else { return XCTFail("prepare") }
        let commit = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: proof.transferID)))
        guard case .failure = commit.outcome else { return XCTFail("shared deadline should reject a late commit") }
        _ = await service.shutdownAndDrain()
    }
    private final class Page: RunnerAutomationPage {
        let identity: AutomationTargetIdentity
        var onBlocked: ((BackgroundUIRequest) -> Void)?
        var prepared = 0, committed = 0, finalized = 0, destroyed = 0, detached = 0
        var onPrepare: (() -> Void)?
        var onCommit: (() -> Void)?
        let view = AutomationViewport(viewportWidthPoints: 10, viewportHeightPoints: 10, pixelWidth: 10, pixelHeight: 10, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        init(_ target: AutomationTargetIdentity) { identity = target }
        func viewport() throws -> AutomationViewport { view }
        func readState(sessionState: AutomationSessionState, expectedViewport: AutomationViewport) throws -> AutomationState { AutomationState(target: identity, url: nil, loading: false, sessionState: sessionState, viewVersion: 1) }
        func perform(_ action: AutomationAction, expectedViewport: AutomationViewport) async throws -> AutomationResult {
            if case .mouseDown = action { return .nativeDelivered(sequence: 1, buttons: 1, viewVersion: 1) }
            return .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
        }
        func captureSnapshot(expectedViewport: AutomationViewport) async throws -> RunnerAutomationPageSnapshot { throw AutomationError(code: .backendUnavailable) }
        func quiesceInput() {}
        func destroy() async -> Bool { destroyed += 1; return true }
        func detachBorrowedControl() async -> Bool { detached += 1; return false }
        func prepareControlRelease() async throws { prepared += 1; onPrepare?() }
        func commitControlRelease() throws { committed += 1; onCommit?() }
        func finishControlRelease() throws {
            guard prepared == 1, committed == 1, finalized == 0 else { throw AutomationError(code: .targetChanged) }
            finalized += 1
        }
    }
    func testPermissionRevokedDuringCommitCannotPublishReleaseReceipt() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"], !fixture.isEmpty else { throw XCTSkip("private release fixture not configured") }
        let root = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), instance = UUID()
        let page = Page(AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        var allowed = true
        page.onCommit = { allowed = false }
        let service = RunnerAutomationService(profileID: profile, runnerInstanceID: instance, permissionReader: { allowed }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: root) })
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile)))
        guard case .success(.sessionOpened(let token, _, _)) = open.outcome else { return XCTFail("open") }
        let prepare = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.controlReleasePrepared(let proof)) = prepare.outcome else { return XCTFail("prepare") }
        let result = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: proof.transferID)))
        guard case .failure = result.outcome else { return XCTFail("revocation must not publish a release receipt") }
        XCTAssertEqual(page.committed, 1)
        XCTAssertEqual(page.finalized, 0)
        _ = await service.shutdownAndDrain()
    }
    func testHeldInputIsRejectedAndRealCloseStillDestroysPage() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"], !fixture.isEmpty else { throw XCTSkip("private release fixture not configured") }
        let root = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let proofStore = try AutomationSnapshotStore(baseDirectory: root)
        XCTAssertTrue(proofStore.close().cleaned)
        let profile = UUID(), instance = UUID()
        let page = Page(AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        let service = RunnerAutomationService(profileID: profile, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: root) })
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile)))
        guard case .success(.sessionOpened(let token, _, _)) = open.outcome else { if case .failure(let e) = open.outcome { return XCTFail("open: \(e.code.rawValue)") }; return XCTFail("open: unexpected") }
        let down = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .mouseDown(point: ViewportPoint(x: 1, y: 1), viewVersion: 1)))
        guard case .success(.nativeDelivered) = down.outcome else { return XCTFail("mouse down") }
        let release = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .failure = release.outcome else { return XCTFail("held release succeeded") }
        XCTAssertEqual(page.prepared, 0)
        let close = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession))
        guard case .success(.sessionClosed(let receipt)) = close.outcome else { return XCTFail("close") }
        XCTAssertTrue(receipt.cleaned)
        XCTAssertEqual(page.destroyed, 1)
    }
    func testReleaseUsesSamePageAndRejectsWrongTicket() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"], !fixture.isEmpty else { throw XCTSkip("private release fixture not configured") }
        let root = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let proofStore = try AutomationSnapshotStore(baseDirectory: root)
        XCTAssertTrue(proofStore.close().cleaned)
        let profile = UUID(), instance = UUID()
        let page = Page(AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        let service = RunnerAutomationService(profileID: profile, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: root) })
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile)))
        guard case .success(.sessionOpened(let token, let target, _)) = open.outcome else { if case .failure(let e) = open.outcome { return XCTFail("open: \(e.code.rawValue)") }; return XCTFail("open: unexpected") }
        let prepared = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.controlReleasePrepared(let proof)) = prepared.outcome else { return XCTFail("prepare") }
        XCTAssertEqual(proof.target, target); XCTAssertTrue(proof.inputReleased && proof.artifactsCleaned && proof.browserRetained)
        let wrong = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: UUID())))
        guard case .failure = wrong.outcome else { return XCTFail("wrong ticket accepted") }
        XCTAssertEqual(page.committed, 0)
        let commit = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: proof.transferID)))
        guard case .success(.controlReleased(let receipt)) = commit.outcome else { return XCTFail("commit") }
        XCTAssertEqual(receipt.target, target); XCTAssertEqual(receipt.transferID, proof.transferID)
        XCTAssertTrue(receipt.manualInteractionEnabled); XCTAssertEqual(page.prepared, 1); XCTAssertEqual(page.committed, 1)
        let drained = await service.shutdownAndDrain()
        XCTAssertTrue(drained, "unfinalized transfer still performs destructive cleanup")
        XCTAssertEqual(page.destroyed, 1)
    }
    func testPermissionRevocationDuringPreparationDoesNotTransferPage() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"], !fixture.isEmpty else { throw XCTSkip("private release fixture not configured") }
        let root = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), instance = UUID()
        let page = Page(AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        var allowed = true
        page.onPrepare = { allowed = false }
        let service = RunnerAutomationService(profileID: profile, runnerInstanceID: instance, permissionReader: { allowed }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: root) })
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile)))
        guard case .success(.sessionOpened(let token, _, _)) = open.outcome else { return XCTFail("open") }
        let reply = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .failure = reply.outcome else { return XCTFail("revoked permission accepted") }
        let drained = await service.shutdownAndDrain()
        XCTAssertTrue(drained)
        XCTAssertEqual(page.committed, 0)
        XCTAssertEqual(page.destroyed, 1)
    }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func testFinalizedTransferKeepsPageAfterServiceShutdown() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"], !fixture.isEmpty else { throw XCTSkip("private release fixture not configured") }
        let root = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), instance = UUID()
        let page = Page(AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID()))
        let store = try AutomationSnapshotStore(baseDirectory: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        var service: RunnerAutomationService? = RunnerAutomationService(profileID: profile, runnerInstanceID: instance, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { store })
        weak let weakService = service
        guard let open = await service?.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile))),
              case .success(.sessionOpened(let token, _, _)) = open.outcome else { return XCTFail("open") }
        guard let prepare = await service?.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl)),
              case .success(.controlReleasePrepared(let proof)) = prepare.outcome else { return XCTFail("prepare") }
        guard let commit = await service?.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: proof.transferID))),
              case .success(.controlReleased(let receipt)) = commit.outcome else { return XCTFail("commit") }
        let oldToken = await service?.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState))
        guard case .failure = oldToken?.outcome else { return XCTFail("old token accepted") }
        XCTAssertEqual(page.finalized, 0)
        XCTAssertEqual(service?.finishControlRelease(receipt), true)
        XCTAssertEqual(page.finalized, 1)
        XCTAssertTrue(store.close().cleaned)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        service?.shutdown()
        service = nil
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(weakService)
        XCTAssertEqual(page.destroyed, 0)
    }
    #endif
}
