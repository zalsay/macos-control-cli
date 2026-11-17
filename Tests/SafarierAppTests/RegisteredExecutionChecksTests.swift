import XCTest
import SafarierCore
@testable import Safarier

final class RegisteredExecutionChecksTests: XCTestCase {
    @MainActor private func run(release: Bool, sinkFails: Bool = false) async throws {
        let profile = UUID(), token = String(repeating: "A", count: 43)
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let machine = try AutomationSessionMachine.open(profileID: profile, allowsBackgroundAutomation: true, humanProfileRunning: false, token: token, at: 0, registeredInteractive: true).get()
        let view = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        _ = machine.bind(target: target, viewport: view, at: 0)
        let counts = RunnerAutomationControllerCases.Counts(), transfer = UUID()
        let controller = RunnerAutomationController(machine: machine,
            permissionReader: { counts.permissions += 1; return false },
            targetReader: { counts.targets += 1; throw AutomationError(code: .targetChanged) },
            actionSink: { request, _ in
                counts.sink += 1
                if sinkFails { throw AutomationError(code: .targetChanged) }
                let result: AutomationResult
                switch request.action {
                case .releaseControl: result = .controlReleasePrepared(ControlReleasePreparation(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true))
                case .commitControlRelease: result = .controlReleased(ControlReleaseReceipt(target: target, transferID: transfer, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))
                default: result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
                }
                return AutomationReply(requestID: request.requestID, outcome: .success(result))
            }, cleanupSink: { _, _, _ in CleanupReceipt(cleaned: true, terminatedOwnedRunner: false) },
            now: { 0 }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        defer { controller.shutdown() }
        let wrong = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "B", count: 43), action: .getState)
        let refused = await controller.handle(wrong)
        XCTAssertEqual(refused.outcome, .failure(AutomationError(code: .sessionNotFound)))
        XCTAssertEqual(counts.sink, 0)
        let action: AutomationAction = release ? .releaseControl : .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1)
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: action)
        let result = await controller.handle(request)
        if sinkFails {
            XCTAssertEqual(result.outcome, .failure(AutomationError(code: .targetChanged)))
        } else {
            guard case .success = result.outcome else { return XCTFail("registered execution must reach sink: \(result)") }
            let replay = await controller.handle(request)
            XCTAssertEqual(replay, result)
            XCTAssertEqual(counts.sink, 1)
            if release {
                let commit = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .commitControlRelease(transferID: transfer))
                let committed = await controller.handle(commit)
                guard case .success(.controlReleased) = committed.outcome else { return XCTFail("commit must reach sink") }
            }
        }
        XCTAssertEqual(counts.sink, release && !sinkFails ? 2 : 1)
        XCTAssertEqual(counts.permissions, 0)
        XCTAssertEqual(counts.targets, 0)
    }
    @MainActor func testRegisteredInputUsesEstablishedBindingAndReplaysOnce() async throws { try await run(release: false) }
    @MainActor func testBothReleasePhasesBypassRedundantReaders() async throws { try await run(release: true) }
    @MainActor func testActualSinkFailureIsPreserved() async throws { try await run(release: false, sinkFails: true) }
}
