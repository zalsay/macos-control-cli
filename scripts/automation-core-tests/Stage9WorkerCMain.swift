import Foundation
import Darwin
import SafarierCore

actor Gate {
    var waiting: [CheckedContinuation<Void, Never>] = []
    var opened = false
    func wait() async { if opened { return }; await withCheckedContinuation { waiting.append($0) } }
    func release() { opened = true; let all = waiting; waiting.removeAll(); for c in all { c.resume() } }
    var count: Int { waiting.count }
}
final class Recorder: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Data] = []
    func add(_ d: Data) { lock.lock(); values.append(d); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var last: Data? { lock.lock(); defer { lock.unlock() }; return values.last }
}
@main struct Main {
    static func main() async throws {
        let uid = geteuid(), proof = AutomationScriptCallerProof(effectiveUID: geteuid(), pid: 123, auditToken: Data(repeating: 42, count: MemoryLayout<audit_token_t>.size))
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
        let bytes = try AutomationCodec.encodeRequest(request), gate = Gate(), recorder = Recorder(), coordinator = AutomationScriptCoordinator()
        let control = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "A", count: 43), action: .cancel)
        let close = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "A", count: 43), action: .closeSession)
        let controlBytes = try AutomationCodec.encodeRequest(control), closeBytes = try AutomationCodec.encodeRequest(close)
        for _ in 0..<254 {
            guard coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await gate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { recorder.add($0) }) != nil else { fatalError("early rejection") }
        }
        for _ in 0..<1000 { if await gate.count == 254 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        guard await gate.count == 254 else { fatalError("workers did not start") }
        let full = coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await gate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { recorder.add($0) })
        guard full == nil, let fullReply = recorder.last, try AutomationCodec.decodeReply(fullReply).outcome == .failure(AutomationError(code: .replayWindowFull)) else { fatalError("254 ordinary capacity must reject") }
        coordinator.cancelAll()
        guard coordinator.pendingCount == 0, recorder.count == 255 else { fatalError("cancel completion") }
        let rejected = coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await gate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { recorder.add($0) })
        guard rejected == nil, let data = recorder.last, try AutomationCodec.decodeReply(data).outcome == .failure(AutomationError(code: .replayWindowFull)) else { fatalError("orphan ordinary capacity must reject") }
        let quick = Recorder()
        guard coordinator.start(data: controlBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { quick.add($0) }) != nil else { fatalError("control blocked by orphan normal workers") }
        for _ in 0..<1000 where quick.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        guard quick.count == 1 else { fatalError("control did not return") }
        let controlGate = Gate()
        guard coordinator.start(data: controlBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await controlGate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { recorder.add($0) }) != nil else { fatalError("first reserved control") }
        var second: UUID?
        for _ in 0..<1000 {
            second = coordinator.start(data: closeBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await controlGate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { _ in })
            if second != nil { break }; try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard second != nil else { fatalError("second reserved control") }
        let third = Recorder()
        guard coordinator.start(data: controlBytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await controlGate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { third.add($0) }) == nil,
              let thirdReply = third.last, try AutomationCodec.decodeReply(thirdReply).outcome == .failure(AutomationError(code: .replayWindowFull)) else { fatalError("third control must reject at 256") }
        await controlGate.release()
        await gate.release()
        var released = false
        for _ in 0..<1000 { let h = coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { _ in }); if h != nil { released = true; print("PASS 254 ordinary + two reserved controls, orphan capacity and release"); break }; try await Task.sleep(nanoseconds: 1_000_000) }
        guard released else { fatalError("capacity not released") }
        let parallel = AutomationScriptCoordinator(), parallelGate = Gate(), parallelResults = Recorder()
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<64 { group.addTask {
                parallel.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await parallelGate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { parallelResults.add($0) }) != nil
            } }
            var total = 0; for await ok in group { if ok { total += 1 } }; return total
        }
        guard accepted == 64 else { fatalError("64 concurrent admissions") }
        parallel.cancelAll(); guard parallelResults.count == 64, parallel.pendingCount == 0 else { fatalError("64 concurrent cancel") }
        await parallelGate.release()
        let immediate = AutomationScriptCoordinator(), immediateGate = Gate(), immediateResults = Recorder()
        for _ in 0..<128 {
            guard let h = immediate.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: 30, handler: { req in await immediateGate.wait(); return AutomationReply(requestID: req.requestID, outcome: .failure(AutomationError(code: .cancelled))) }, completion: { immediateResults.add($0) }) else { fatalError("immediate admission") }
            immediate.cancel(h)
        }
        guard immediate.pendingCount == 0, immediateResults.count == 128 else { fatalError("128 immediate cancels") }
        await immediateGate.release()
        print("PASS 64 concurrent and 128 immediate cancels")
    }
}
