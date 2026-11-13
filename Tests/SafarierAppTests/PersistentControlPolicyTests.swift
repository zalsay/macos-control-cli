import Foundation
import XCTest
import Darwin
import SafarierCore
@testable import Safarier

final class PersistentControlPolicyTests: XCTestCase {
    private actor RefusingEndpoint: AutomationManagerEndpoint {
        nonisolated let pid: Int32 = 4321
        nonisolated let runnerInstanceID = UUID()
        nonisolated let ownershipID = UUID()
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .interactionRequired)))
        }
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? {
            ProcessExit(pid: pid, status: 0, uncaughtSignal: false)
        }
    }
    @MainActor func testRunnerRefusalIsNotReportedAsInvalidRequest() async {
        let profile = Profile(name: "fixture", mode: .persistent)
        let endpoint = RefusingEndpoint()
        let manager = AutomationManager(profileReader: { _ in profile }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let result = await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid())
        XCTAssertEqual(result.outcome, .failure(AutomationError(code: .interactionRequired)))
        manager.shutdown()
    }
    @MainActor func testRevokingPermissionStartsCleanupAndRejectsFurtherActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        var profile = Profile(name: "fixture", mode: .persistent)
        try workspace.profiles.insert(profile)
        let endpoint = AutomationManagerCases.FakeEndpoint(profileID: profile.id)
        let manager = AutomationManager(profileReader: { try workspace.profiles.record(id: $0) }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let opened = await manager.handle(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)), role: .manager, proof: proof, currentUID: geteuid())
        guard case .success(.sessionOpened(let token, _, _)) = opened.outcome else { return XCTFail("open failed") }
        profile.allowsAgentAccess = false
        try workspace.profiles.update(profile)
        manager.profilePermissionsChanged(allowedProfileIDs: [])
        let action = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .getState)
        let result = await manager.handle(action, role: .manager, proof: proof, currentUID: geteuid())
        guard case .failure = result.outcome else { return XCTFail("action accepted after revocation") }
        for _ in 0..<100 {
            if await endpoint.counts().1 > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let counts = await endpoint.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        manager.shutdown()
    }
    @MainActor func testExplicitlyDeniedProfileCannotOpen() async throws {
        let source = Profile(name: "fixture", mode: .persistent)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        json["allowsAgentAccess"] = false
        let profile = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        let endpoint = AutomationManagerCases.FakeEndpoint(profileID: profile.id)
        let manager = AutomationManager(profileReader: { _ in profile }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let result = await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid())
        XCTAssertEqual(result.outcome, .failure(AutomationError(code: .profileNotAllowed)))
        let counts = await endpoint.counts()
        XCTAssertEqual(counts.0, 0)
        manager.shutdown()
    }
    @MainActor func testLegacyFalsePersistentProfileCanOpenWithoutChangingIdentity() async throws {
        let profile = Profile(name:"isolated-fixture", mode:.persistent, allowsBackgroundAutomation:false)
        let endpoint = AutomationManagerCases.FakeEndpoint(profileID:profile.id)
        let manager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds:UInt64(max(0,deadline-ProcessInfo.processInfo.systemUptime)*1_000_000_000))
        })
        let proof=AutomationScriptCallerProof(effectiveUID:geteuid(),pid:123,auditToken:Data(repeating:7,count:MemoryLayout<audit_token_t>.size))
        let request=AutomationRequest(version:1,requestID:UUID(),sessionID:nil,action:.openSession(profileID:profile.id))
        let result=await manager.handle(request,role:.manager,proof:proof,currentUID:geteuid())
        guard case .success(.sessionOpened(_,let target,_)) = result.outcome else { return XCTFail("legacy persistent profile rejected: \(result.outcome)") }
        XCTAssertEqual(target.profileID,profile.id)
        manager.shutdown()
    }
}
