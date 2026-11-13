import Foundation
import Darwin
@testable import SafarierCore

public enum AutomationScriptCases {
    public struct Failure: Error { let label: String }
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Data] = []
        private var calls = 0
        func append(_ data: Data) { lock.lock(); values.append(data); lock.unlock() }
        func called() { lock.lock(); calls += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
        var handlerCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var first: Data? { lock.lock(); defer { lock.unlock() }; return values.first }
    }
    public static func run() async throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws { checks += 1; if !value() { throw Failure(label: label) } }
        let uid = geteuid()
        let proof = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: Data(repeating: 42, count: MemoryLayout<audit_token_t>.size))
        let id = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let request = AutomationRequest(version: 1, requestID: id, sessionID: nil, action: .capabilities)
        let result = await AutomationScriptService.handle(request, role: .manager, proof: proof, currentUID: uid)
        if case .success(.capabilities(let c)) = result.outcome { try check(c.backend == .unavailable && c.role == "manager", "capabilities unavailable") } else { throw Failure(label: "capabilities") }
        let unauthorized = await AutomationScriptService.handle(request, role: .runner, proof: proof, currentUID: uid)
        try check(unauthorized.outcome == .failure(AutomationError(code: .unauthorized)), "runner denied")
        let coordinator = AutomationScriptCoordinator()
        let bytes = try AutomationCodec.encodeRequest(request)
        let reply = await withCheckedContinuation { continuation in
            _ = coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { request in
                await AutomationScriptService.handle(request, role: .manager, proof: proof, currentUID: uid)
            }, completion: { data in continuation.resume(returning: data) })
        }
        try check((try? AutomationCodec.decodeReply(reply)) == result, "coordinator reply")
        try check(coordinator.pendingCount == 0, "pending cleanup")
        try check(!String(reflecting: proof).contains("42") && !String(describing: proof).contains("123"), "proof redaction")
        let badUID = AutomationScriptCallerProof(effectiveUID: uid &+ 1, pid: 123, auditToken: Data(repeating: 0, count: MemoryLayout<audit_token_t>.size))
        let badPID = AutomationScriptCallerProof(effectiveUID: uid, pid: 0, auditToken: Data(repeating: 0, count: MemoryLayout<audit_token_t>.size))
        let badAudit = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: Data(repeating: 0, count: 1))
        for (role, candidate) in [(ExecutableRole.manager, nil), (.manager, badUID), (.manager, badPID), (.manager, badAudit), (.cli, proof), (.runner, proof)] {
            let denial = await AutomationScriptService.handle(request, role: role, proof: candidate, currentUID: uid)
            try check(denial.outcome == .failure(AutomationError(code: .unauthorized)), "proof/role denied")
            let r = Recorder()
            coordinator.start(data: bytes, role: role, proof: candidate, currentUID: uid, timeoutSeconds: 1, handler: { req in r.called(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .timeout))) }, completion: { r.append($0) })
            try check(r.count == 1 && r.handlerCalls == 0, "unauthorized no dispatch")
        }
        let token = String(repeating: "A", count: 43)
        let actions: [AutomationAction] = [.openSession(profileID: id), .getState, .navigate(url: URL(string: "https://example.com/?secret=test")!), .screenshot, .move(point: ViewportPoint(x: 1, y: 2), viewVersion: 1), .mouseDown(point: ViewportPoint(x: 1, y: 2), viewVersion: 1), .mouseUp(point: ViewportPoint(x: 1, y: 2), viewVersion: 1), .click(point: ViewportPoint(x: 1, y: 2), viewVersion: 1, count: 1), .scroll(point: ViewportPoint(x: 1, y: 2), viewVersion: 1, deltaX: 1, deltaY: 1), .insertText("secret"), .key(name: .tab, shift: false), .cancel, .closeSession]
        for action in actions {
            let session: String?; if case .openSession = action { session = nil } else { session = token }
            let actionRequest = AutomationRequest(version: 1, requestID: id, sessionID: session, action: action)
            let denial = await AutomationScriptService.handle(actionRequest, role: .manager, proof: proof, currentUID: uid)
            try check(denial.outcome == .failure(AutomationError(code: .backgroundLaunchUnverified)), "non-capability refused")
        }
        for bad in [Data("{".utf8), Data(repeating: 32, count: 65_537)] {
            let r = Recorder()
            coordinator.start(data: bad, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { req in r.called(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .timeout))) }, completion: { r.append($0) })
            try check(r.count == 1 && r.handlerCalls == 0, "invalid JSON no dispatch")
        }
        for timeout in [0.0, -1.0, Double.nan, Double.infinity] {
            let r = Recorder()
            coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: timeout, handler: { req in r.called(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .timeout))) }, completion: { r.append($0) })
            try check(r.count == 1 && r.handlerCalls == 0 && coordinator.pendingCount == 0, "invalid deadline no dispatch")
        }
        let delayed = Recorder()
        coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 0.03, handler: { req in
            delayed.called(); try? await Task.sleep(nanoseconds: 150_000_000)
            return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled)))
        }, completion: { delayed.append($0) })
        try await Task.sleep(nanoseconds: 250_000_000)
        let timeoutReply = try AutomationCodec.decodeReply(delayed.first!)
        try check(delayed.count == 1 && delayed.handlerCalls == 1 && timeoutReply.outcome == .failure(AutomationError(code: .timeout)), "timeout late reply once")
        try check(coordinator.pendingCount == 0, "timeout cleanup")
        let wrongID = Recorder()
        coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { _ in AutomationReply(requestID: UUID(), outcome: .failure(AutomationError(code: .timeout))) }, completion: { wrongID.append($0) })
        for _ in 0..<100 where wrongID.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let mismatch = try AutomationCodec.decodeReply(wrongID.first!)
        try check(wrongID.count == 1 && mismatch.requestID == id && mismatch.outcome == .failure(AutomationError(code: .indeterminateResult)), "wrong id rejected")
        let reentrant = Recorder()
        coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { req in await AutomationScriptService.handle(req, role: .manager, proof: proof, currentUID: uid) }, completion: { data in reentrant.append(data); coordinator.cancelAll() })
        for _ in 0..<100 where reentrant.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        try check(reentrant.count == 1 && coordinator.pendingCount == 0, "reentrant completion once")
        let cancelled = Recorder()
        let mutation = AutomationRequest(version: 1, requestID: id, sessionID: token, action: .insertText("secret"))
        let mutationBytes = try AutomationCodec.encodeRequest(mutation)
        let handle = coordinator.start(data: mutationBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { req in
            cancelled.called(); try? await Task.sleep(nanoseconds: 150_000_000)
            return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .timeout)))
        }, completion: { cancelled.append($0) })!
        for _ in 0..<100 where cancelled.handlerCalls == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        coordinator.cancel(handle)
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelledReply = try AutomationCodec.decodeReply(cancelled.first!)
        try check(cancelled.count == 1 && cancelledReply.outcome == .failure(AutomationError(code: .cancelled, sideEffects: .possible)), "mutation cancel possible once")
        try check(coordinator.pendingCount == 0, "cancel cleanup")
        enum TestError: Error { case failed }
        let thrown = Recorder()
        coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { _ in throw TestError.failed }, completion: { thrown.append($0) })
        for _ in 0..<100 where thrown.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let thrownReply = try AutomationCodec.decodeReply(thrown.first!)
        try check(thrown.count == 1 && thrownReply.outcome == .failure(AutomationError(code: .indeterminateResult)), "handler error once")
        let nilSuccess = Recorder()
        coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { _ in AutomationReply(requestID: nil, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1))) }, completion: { nilSuccess.append($0) })
        for _ in 0..<100 where nilSuccess.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let nilReply = try AutomationCodec.decodeReply(nilSuccess.first!)
        try check(nilSuccess.count == 1 && nilReply.requestID == id && nilReply.outcome == .failure(AutomationError(code: .indeterminateResult)), "nil success rejected")
        let mutationTimeout = Recorder()
        coordinator.start(data: mutationBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 0.03, handler: { req in
            mutationTimeout.called(); try? await Task.sleep(nanoseconds: 200_000_000)
            return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .timeout)))
        }, completion: { mutationTimeout.append($0) })
        try await Task.sleep(nanoseconds: 150_000_000)
        let mutationTimeoutReply = try AutomationCodec.decodeReply(mutationTimeout.first!)
        try check(mutationTimeout.count == 1 && mutationTimeout.handlerCalls == 1 && mutationTimeoutReply.outcome == .failure(AutomationError(code: .timeout, sideEffects: .possible)), "mutation timeout possible once")
        let mutationError = Recorder()
        coordinator.start(data: mutationBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 1, handler: { _ in throw TestError.failed }, completion: { mutationError.append($0) })
        for _ in 0..<100 where mutationError.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let mutationErrorReply = try AutomationCodec.decodeReply(mutationError.first!)
        try check(mutationError.count == 1 && mutationErrorReply.outcome == .failure(AutomationError(code: .indeterminateResult, sideEffects: .possible)), "mutation error possible once")
        let recorders = (0..<12).map { _ in Recorder() }
        for recorder in recorders {
            coordinator.start(data: mutationBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 0.03, handler: { req in
                recorder.called(); try? await Task.sleep(nanoseconds: 50_000_000)
                return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .timeout)))
            }, completion: { recorder.append($0) })
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        coordinator.cancelAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        for recorder in recorders { try check(recorder.count == 1, "each cancel timeout late completes once") }
        try check(coordinator.pendingCount == 0, "multi cancel cleanup")
        return checks
    }
}
