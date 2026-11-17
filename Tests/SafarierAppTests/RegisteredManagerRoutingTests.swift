#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_MANAGER_ROUTING_TESTS
import XCTest
import Darwin
import SafarierCore
@testable import Safarier

final class RegisteredManagerRoutingTests: XCTestCase {
    private actor Endpoint: AutomationManagerEndpoint {
        nonisolated let registeredInteractive = true
        nonisolated let pid: Int32
        nonisolated let runnerInstanceID: UUID
        nonisolated let ownershipID: UUID
        nonisolated let absoluteLifetimeDeadline: Double?
        let owner: OwnedRunnerProcess
        let target: AutomationTargetIdentity
        let token: String
        let inputDelay: UInt64
        var releaseCount = 0, closeCount = 0, inputCount = 0
        init(owner: OwnedRunnerProcess, target: AutomationTargetIdentity, absoluteLifetimeDeadline: Double? = nil, inputDelay: UInt64 = 0) throws {
            self.owner = owner; self.target = target; self.token = try AutomationSessionToken.generate()
            self.absoluteLifetimeDeadline = absoluteLifetimeDeadline; self.inputDelay = inputDelay
            pid = owner.pid; runnerInstanceID = target.runnerInstanceID; ownershipID = owner.ownershipID
        }
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            let result: AutomationResult
            switch request.action {
            case .openSession:
                let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
                result = .sessionOpened(sessionID: token, target: target, viewport: viewport)
            case .releaseControl:
                result = .controlReleasePrepared(ControlReleasePreparation(target: target, transferID: transferID, inputReleased: true, artifactsCleaned: true, browserRetained: true))
            case .commitControlRelease(let id):
                guard id == transferID else { throw AutomationError(code: .invalidRequest) }
                result = .controlReleased(ControlReleaseReceipt(target: target, transferID: id, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))
            case .click:
                inputCount += 1
                if inputDelay > 0 { try await Task.sleep(nanoseconds: inputDelay) }
                result = .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }
        private let transferID = UUID()
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? { closeCount += 1; return nil }
        func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess {
            guard receipt.target == target, receipt.transferID == transferID else { throw AutomationError(code: .invalidRequest) }
            releaseCount += 1; return owner
        }
    }
    @MainActor func testRegisteredInputDoesNotDependOnLifetimeBudget() async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        let profile = Profile(name: "budget release", mode: .persistent)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let clock = AutomationManagerCases.Clock(), base = ProcessInfo.processInfo.systemUptime
        clock.advance(base)
        let lifetime = base + 30
        let endpoint = try Endpoint(owner: owner, target: target, absoluteLifetimeDeadline: lifetime)
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in throw AutomationError(code: .profileAlreadyRunning) }, admission: { true }, now: { clock.read() }, sleepUntil: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ request: AutomationRequest) async -> AutomationReply { await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid()) }
        guard case .success(.sessionOpened(let token, _, _)) = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))).outcome else { return XCTFail("open") }
        clock.advance(lifetime - AutomationLimits.cleanupSeconds - 1 - 9)
        let input = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1)))
        guard case .success(.nativeDelivered) = input.outcome else { return XCTFail("input must not be rejected by old lifetime") }
        let count = await endpoint.inputCount
        XCTAssertEqual(count, 1)
        let released = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.controlReleased(let receipt)) = released.outcome else { return XCTFail("release after input") }
        XCTAssertTrue(receipt.inputReleased && receipt.artifactsCleaned && receipt.browserRetained && receipt.manualInteractionEnabled)
    }
    @MainActor func testReleaseWaitsForInFlightInputBeforeHandoff() async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        let profile = Profile(name: "release during input", mode: .persistent)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let endpoint = try Endpoint(owner: owner, target: target, inputDelay: 300_000_000)
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in throw AutomationError(code: .profileAlreadyRunning) }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ request: AutomationRequest) async -> AutomationReply { await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid()) }
        guard case .success(.sessionOpened(let token, _, _)) = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))).outcome else { return XCTFail("open") }
        let task = Task { await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .click(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, count: 1))) }
        while await endpoint.inputCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let release = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
        guard case .success(.nativeDelivered) = await task.value.outcome else { return XCTFail("input receipt lost") }
        guard case .success(.controlReleased(let receipt)) = release.outcome else { return XCTFail("release must wait for input") }
        XCTAssertTrue(receipt.inputReleased && receipt.artifactsCleaned && receipt.browserRetained && receipt.manualInteractionEnabled)
    }
    @MainActor func testRegisteredManagerCanReconnectPastFixtureOpenCapacity() async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        let profile = Profile(name: "many registered sessions", mode: .persistent)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in throw AutomationError(code: .profileAlreadyRunning) }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in try Endpoint(owner: owner, target: target) }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ request: AutomationRequest) async -> AutomationReply { await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid()) }
        var first: AutomationRequest?
        for index in 0..<260 {
            let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
            if first == nil { first = open }
            let opened = await send(open)
            guard case .success(.sessionOpened(let token, _, _)) = opened.outcome else { return XCTFail("open \(index): \(opened.outcome)") }
            let released = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .releaseControl))
            guard case .success(.controlReleased) = released.outcome else { return XCTFail("release \(index): \(released.outcome)") }
        }
        let replay = await send(first!)
        guard case .failure(let error) = replay.outcome else { return XCTFail("old open request cannot start a new session") }
        XCTAssertEqual(error.code, .sessionExpired)
    }
    @MainActor func testReleasedRegisteredRunnerCanReconnectWithoutClosingOwner() async throws {
        let pair = try AutomationChannel.makePair()
        let owner = try FoundationProcessSpawner().spawnOwned(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], logURL: nil, standardInput: pair.child)
        try pair.child.close()
        defer { pair.parent.close() }
        let profile = Profile(name: "registered fixture", mode: .persistent)
        let target = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        var endpoints: [Endpoint] = []
        let manager = AutomationManager(profileReader: { $0 == profile.id ? profile : nil }, humanRunning: { _ in true }, runnerFactory: { _ in throw AutomationError(code: .profileAlreadyRunning) }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
        })
        manager.injectedOwnedRegistrationProof = { true }
        manager.setRegisteredConnector { _ in let endpoint = try Endpoint(owner: owner, target: target); endpoints.append(endpoint); return endpoint }
        let proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        func send(_ request: AutomationRequest) async -> AutomationReply { await manager.handle(request, role: .manager, proof: proof, currentUID: geteuid()) }
        let first = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)))
        guard case .success(.sessionOpened(let firstToken, let firstTarget, _)) = first.outcome else { return XCTFail("first open") }
        let release = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: firstToken, action: .releaseControl))
        guard case .success(.controlReleased(let receipt)) = release.outcome else { return XCTFail("release") }
        XCTAssertEqual(receipt.target, target)
        let old = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: firstToken, action: .getState))
        XCTAssertEqual(old.outcome, .failure(AutomationError(code: .sessionExpired)))
        let second = await send(AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id)))
        guard case .success(.sessionOpened(let secondToken, let secondTarget, _)) = second.outcome else { return XCTFail("second open") }
        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertEqual(firstTarget, secondTarget)
        XCTAssertTrue(owner.isRunning)
        let closeCount = await endpoints[0].closeCount
        let releaseCount = await endpoints[0].releaseCount
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(releaseCount, 1)
        manager.shutdown()
    }
}
#endif
