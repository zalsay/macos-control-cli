import Foundation
import XCTest
import SafarierCore
@testable import Safarier
final class RunnerAutomationServiceTests: XCTestCase {
    @MainActor func testOpeningPreservesInteractionRequired() async throws {
        let id = UUID(), instance = UUID()
        let service = RunnerAutomationService(profileID: id, runnerInstanceID: instance, permissionReader: { true }, pageFactory: {
            throw AutomationError(code: .interactionRequired)
        }, snapshotFactory: { throw AutomationError(code: .backendUnavailable) })
        let reply = await service.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: id)))
        XCTAssertEqual(reply.outcome, .failure(AutomationError(code: .interactionRequired)))
    }
    @MainActor func testLoadingRejectionIsRecoverable() async throws {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".safarier-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let count = try await RunnerAutomationServiceCases.runLoadingRejection(base: base)
        XCTAssertEqual(count, 5)
    }
    @MainActor func testDocumentChangeKeepsSessionAndRejectsStaleInputs() async throws {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".safarier-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let count = try await RunnerAutomationServiceCases.runDocumentChanges(base: base)
        XCTAssertEqual(count, 6)
    }
    @MainActor func testReleaseAfterDocumentChangesDuringPermission() async throws {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".safarier-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let count = try await RunnerAutomationServiceCases.runReleasePreflightRace(base: base)
        XCTAssertEqual(count, 2)
    }
    @MainActor func testCases() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_SERVICE_FIXTURE"] ?? "")
        guard !base.path.isEmpty else { throw XCTSkip("private fixture not configured") }
        let count = try await RunnerAutomationServiceCases.run(base: base)
        XCTAssertGreaterThan(count, 0)
    }
}
