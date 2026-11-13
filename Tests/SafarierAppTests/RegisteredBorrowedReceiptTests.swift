import Foundation
import XCTest
import SafarierCore
@testable import Safarier
#if SAFARIER_REGISTERED_TAB_TESTS
import AppKit
import WebKit
@testable import SafarierWebKit
#endif

@MainActor private final class BorrowedReceiptPage: RunnerAutomationPage {
    let identity: AutomationTargetIdentity
    let detachResult: Bool
    var detached = 0, destroyed = 0, quiesced = 0
    var detachCompleted = false
    var onBlocked: ((BackgroundUIRequest) -> Void)?
    let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
    init(_ identity: AutomationTargetIdentity, detachResult: Bool) { self.identity = identity; self.detachResult = detachResult }
    func viewport() throws -> AutomationViewport { view }
    func readState(sessionState: AutomationSessionState, expectedViewport: AutomationViewport) throws -> AutomationState { AutomationState(target: identity, url: nil, loading: false, sessionState: sessionState, viewVersion: expectedViewport.viewVersion) }
    func perform(_ action: AutomationAction, expectedViewport: AutomationViewport) async throws -> AutomationResult { throw AutomationError(code: .uiPolicyUnavailable) }
    func captureSnapshot(expectedViewport: AutomationViewport) async throws -> RunnerAutomationPageSnapshot { throw AutomationError(code: .uiPolicyUnavailable) }
    func quiesceInput() { quiesced += 1 }
    func prepareControlRelease() async throws {}
    func commitControlRelease() throws {}
    func finishControlRelease() throws {}
    func destroy() async -> Bool { destroyed += 1; return true }
    func detachBorrowedControl() async -> Bool { detached += 1; await Task.yield(); detachCompleted = true; return detachResult }
}

final class RegisteredBorrowedReceiptTests: XCTestCase {
    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_REGISTERED_TAB_TESTS
    @MainActor func testTwoTabReleaseFinalizationRequiresExactReceiptAndCleanup() async throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        guard let fixture = ProcessInfo.processInfo.environment["RUNNER_RELEASE_FIXTURE"] else { throw XCTSkip("private fixture missing") }
        let base = URL(fileURLWithPath: fixture).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = Profile(name: "release-two-tab", mode: .ephemeral)
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(), report: PrivacyCapabilityReport(), executionPolicy: .interactive)
        let session = BrowserSession(profile: profile, output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics())
        let first = session.makeRegisteredTestController(), selected = session.makeRegisteredTestController()
        first.window.setFrameOrigin(NSPoint(x: -100000, y: -100000)); selected.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        first.window.addTabbedWindow(selected.window, ordered: .above)
        let group = try XCTUnwrap(first.window.tabGroup); group.selectedWindow = selected.window
        XCTAssertEqual(session.openControllers.count, 2)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: selected.registeredWindowID, pageID: selected.registeredPageID)
        let page = BorrowedReceiptPage(target, detachResult: true)
        let service = RunnerAutomationService(profileID: profile.id, runnerInstanceID: target.runnerInstanceID, permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) }, pageOwnership: .borrowed)
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)))
        guard case let .success(.sessionOpened(token, _, _)) = open.outcome else { return XCTFail("open") }
        let prepare = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case let .success(.controlReleasePrepared(proof)) = prepare.outcome else { return XCTFail("prepare") }
        let commit = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: proof.transferID)))
        guard case let .success(.controlReleased(receipt)) = commit.outcome else { return XCTFail("commit") }
        func altered(_ target: AutomationTargetIdentity, _ transfer: UUID, _ cleaned: Bool) -> ControlReleaseReceipt {
            ControlReleaseReceipt(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: cleaned, browserRetained: true, manualInteractionEnabled: true)
        }
        let wrongTarget = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: target.runnerInstanceID, windowID: first.registeredWindowID, pageID: first.registeredPageID)
        let wrongProfile = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: target.runnerInstanceID, windowID: target.windowID, pageID: target.pageID)
        XCTAssertFalse(BoundRunnerServiceSlot.finishRegisteredRelease(session: session, receipt: altered(wrongProfile, receipt.transferID, true), service: service))
        XCTAssertFalse(BoundRunnerServiceSlot.finishRegisteredRelease(session: session, receipt: altered(wrongTarget, receipt.transferID, true), service: service))
        XCTAssertFalse(BoundRunnerServiceSlot.finishRegisteredRelease(session: session, receipt: altered(target, UUID(), true), service: service))
        XCTAssertFalse(BoundRunnerServiceSlot.finishRegisteredRelease(session: session, receipt: altered(target, receipt.transferID, false), service: service))
        XCTAssertTrue(BoundRunnerServiceSlot.finishRegisteredRelease(session: session, receipt: receipt, service: service))
        XCTAssertFalse(BoundRunnerServiceSlot.finishRegisteredRelease(session: session, receipt: receipt, service: service))
        XCTAssertTrue(group.selectedWindow === selected.window)
        XCTAssertEqual(page.detached, 0); XCTAssertEqual(page.destroyed, 0)
    }
    #endif
    @MainActor func testBorrowedCloseAndCancelReturnOnlyProvenReceipt() async throws {
        for action in [AutomationAction.closeSession, .cancel] {
            for succeeds in [true, false] {
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let base = root.appendingPathComponent(".build", isDirectory: true).appendingPathComponent("sf-borrowed-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: base) }
                let profile = UUID(), instance = UUID()
                let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: instance, windowID: UUID(), pageID: UUID())
                let page = BorrowedReceiptPage(target, detachResult: succeeds)
                let service = RunnerAutomationService(profileID: profile, runnerInstanceID: instance,
                    permissionReader: { true }, pageFactory: { page },
                    snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) }, pageOwnership: .borrowed)
                let opened = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile)))
                guard case let .success(.sessionOpened(token, _, _)) = opened.outcome else { XCTFail("open failed"); continue }
                let closed = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: action))
                guard case let .success(.sessionClosed(receipt)) = closed.outcome else { XCTFail("missing close receipt"); continue }
                XCTAssertFalse(receipt.cleaned); XCTAssertFalse(receipt.terminatedOwnedRunner)
                XCTAssertEqual(receipt.retainedBrowser?.target, succeeds ? target : nil)
                XCTAssertEqual(receipt.retainedBrowser?.confirmed, succeeds ? true : nil)
                XCTAssertEqual(page.detached, 1); XCTAssertEqual(page.destroyed, 0)
            }
        }
    }
    @MainActor func testDrainWaitsForAsyncDetachBeforeVerifier() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").appendingPathComponent("sf-drain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let target = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let page = BorrowedReceiptPage(target, detachResult: true)
        let service = RunnerAutomationService(profileID: target.profileID, runnerInstanceID: target.runnerInstanceID,
            permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) },
            cleanupVerifier: { page.detachCompleted }, pageOwnership: .borrowed)
        let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: target.profileID)))
        guard case .success(.sessionOpened) = open.outcome else { return XCTFail("open failed") }
        let drained = await service.shutdownAndDrain()
        XCTAssertTrue(drained)
        XCTAssertTrue(page.detachCompleted)
        XCTAssertEqual(page.detached, 1)
        XCTAssertEqual(page.destroyed, 0)
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    @MainActor func testReleasedServiceDrainsWithoutQuiescingAndNextServiceReusesTarget() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").appendingPathComponent("sf-release-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let target = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let page = BorrowedReceiptPage(target, detachResult: true)
        for _ in 0..<2 {
            let service = RunnerAutomationService(profileID: target.profileID, runnerInstanceID: target.runnerInstanceID,
                permissionReader: { true }, pageFactory: { page }, snapshotFactory: { try AutomationSnapshotStore(baseDirectory: base) }, pageOwnership: .borrowed)
            let open = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: target.profileID)))
            guard case let .success(.sessionOpened(token, actual, _)) = open.outcome else { return XCTFail("open") }
            XCTAssertEqual(actual, target)
            let prepare = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
            guard case let .success(.controlReleasePrepared(proof)) = prepare.outcome else { return XCTFail("prepare") }
            let commit = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: proof.transferID)))
            guard case let .success(.controlReleased(receipt)) = commit.outcome else { return XCTFail("commit") }
            XCTAssertTrue(service.finishControlRelease(receipt))
            let before = page.quiesced
            let drained = await service.shutdownAndDrain()
            XCTAssertTrue(drained)
            XCTAssertEqual(page.quiesced, before)
            XCTAssertEqual(page.detached, 0)
            XCTAssertEqual(page.destroyed, 0)
        }
    }
    #endif

}
