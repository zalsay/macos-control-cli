import Foundation
import Darwin
import SafarierCore
final class Record: @unchecked Sendable {
    private let lock = NSLock(); private var replies: [Data] = []; private var calls = 0
    func reply(_ data: Data) { lock.lock(); replies.append(data); lock.unlock() }
    func called() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
    var handlerCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var first: Data? { lock.lock(); defer { lock.unlock() }; return replies.first }
}
@main struct Main {
    static func main() async throws {
        let mode = CommandLine.arguments[1], uid = geteuid()
        let proof = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: Data(repeating: 42, count: MemoryLayout<audit_token_t>.size))
        let action: AutomationAction = mode == "late" ? .insertText("test") : .capabilities
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: mode == "late" ? String(repeating: "A", count: 43) : nil, action: action)
        let bytes = try AutomationCodec.encodeRequest(request), coordinator = AutomationScriptCoordinator(), record = Record()
        if mode == "prestart" || mode == "cancel" { setenv("STAGE9_DELAY_WORKER", "1", 1) }
        if mode == "timerstart" { setenv("STAGE9_DELAY_TIMER_START", "1", 1) }
        else { setenv("STAGE9_DELAY_TIMER", "1", 1) }
        let began = DispatchTime.now().uptimeNanoseconds
        let handle = coordinator.start(data: bytes, role: .manager, proof: proof, currentUID: uid, timeoutSeconds: mode == "timerstart" ? 0.12 : 0.02, handler: { request in
            record.called()
            if mode == "late" { try? await Task.sleep(nanoseconds: 40_000_000) }
            if mode == "timerstart" { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            return AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .cancelled)))
        }, completion: { record.reply($0) })!
        if mode == "cancel" { coordinator.cancel(handle) }
        for _ in 0..<300 where record.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let data = record.first else { fatalError("missing reply") }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        let expected = AutomationError(code: mode == "cancel" ? .cancelled : .timeout, sideEffects: mode == "late" ? .possible : .none)
        guard try AutomationCodec.decodeReply(data).outcome == .failure(expected) else { fatalError("\(mode) incorrect result") }
        if mode == "prestart" || mode == "cancel" { guard record.handlerCalls == 0 else { fatalError("\(mode) ran handler") } }
        if mode == "timerstart" { guard elapsed >= 0.19 && elapsed < 0.29 else { fatalError("timer restarted full timeout: \(elapsed)") } }
        if mode == "late" { guard record.handlerCalls == 1 else { fatalError("late handler missing") } }
        try await Task.sleep(nanoseconds: 180_000_000)
        guard record.count == 1, coordinator.pendingCount == 0 else { fatalError("\(mode) completion not once") }
        print("PASS \(mode), reply elapsed \(elapsed)s, once")
    }
}
