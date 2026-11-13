#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Foundation

final class RegisteredPrepareTrace {
    enum Phase: String { case identity, profile, plan, service, commit }
    enum Result: String { case ok, error }
    private var pending: (Phase, UInt64)?
    private let emit: (Phase, Result, UInt64) -> Void

    init(emit: @escaping (Phase, Result, UInt64) -> Void = { phase, result, elapsed in
        fputs("REGISTERED_PREPARE_DIAG phase=\(phase.rawValue) result=\(result.rawValue) elapsed_us=\(elapsed)\n", stderr)
    }) { self.emit = emit }

    func begin(_ phase: Phase) { pending = (phase, DispatchTime.now().uptimeNanoseconds) }
    func success() { finish(.ok) }
    func failureIfPending() { finish(.error) }
    private func finish(_ result: Result) {
        guard let (phase, start) = pending else { return }
        pending = nil
        let now = DispatchTime.now().uptimeNanoseconds
        emit(phase, result, (now >= start ? now - start : 0) / 1_000)
    }
}
#endif
