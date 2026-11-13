import Foundation

/// Fixed labels and durations only. Does not inspect identities, paths or content.
final class BinderValidationTrace {
    enum Checkpoint: String { case first, second }
    enum Stage: String { case initial, selfIdentity, resources, parentFirst, peer, parentSecond, repository, final }
    private let checkpoint: Checkpoint
    private let clock: () -> UInt64
    private let sink: (Checkpoint, Stage, UInt64, Bool) -> Void
    private var pending: (Stage, UInt64)?

    init(checkpoint: Checkpoint, clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sink: @escaping (Checkpoint, Stage, UInt64, Bool) -> Void = { checkpoint, stage, nanos, success in
             fputs("BINDER_CHECK_DIAG checkpoint=\(checkpoint.rawValue) stage=\(stage.rawValue) elapsed_us=\(nanos / 1_000) result=\(success ? "ok" : "error")\n", stderr)
         }) {
        self.checkpoint = checkpoint; self.clock = clock; self.sink = sink
    }
    func begin(_ stage: Stage) { pending = (stage, clock()) }
    func success() { finish(true) }
    func failureIfPending() { finish(false) }
    private func finish(_ success: Bool) {
        guard let (stage, start) = pending else { return }
        pending = nil
        let now = clock()
        sink(checkpoint, stage, now >= start ? now - start : 0, success)
    }
}
