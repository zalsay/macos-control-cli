#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_WHEEL_OBSERVER_PROBE
import AppKit
import WebKit
import SafarierCore
import SafarierObjCSupport
import Darwin

/// One observation-only handshake; no callback is a wheel ACK or cleanup proof.
@MainActor
final class BoundWheelObserverProbe {
    private let webView: BrowserWebView
    private let context: RunnerBinderContext
    private let witness: @MainActor () throws -> Void
    private var expected = 0
    private var pending: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var failed = false

    init(webView: BrowserWebView, context: RunnerBinderContext, witness: @escaping @MainActor () throws -> Void) {
        self.webView = webView; self.context = context; self.witness = witness
    }

    /// Only called after Core has verified the parent/child inventory and context.
    static func configure(_ configuration: WKWebViewConfiguration, fixture: URL) throws {
        guard fixture.isFileURL, fixture.lastPathComponent == "control-fixture.html",
              fixture.deletingLastPathComponent().lastPathComponent == "Resources" else {
            throw AutomationError(code: .targetChanged)
        }
        let contents = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let plugin = contents.appendingPathComponent("PlugIns/SafarierWheelObserver.bundle", isDirectory: true)
        guard SFRWheelObserverConfigure(configuration, plugin) == .OK else { throw AutomationError(code: .backendUnavailable) }
        fputs("WHEEL_OBSERVER_PROBE phase=configured\n", stderr)
    }

    private func finish(_ result: Result<Void, Error>) {
        timer?.cancel(); timer = nil
        if let continuation { self.continuation = nil; continuation.resume(with: result) }
        else if pending == nil { pending = result }
        else { failed = true }
    }

    private func receive(_ event: Int) {
        if event == 2 { fputs("WHEEL_OBSERVER_PROBE phase=observed_not_ack\n", stderr); return }
        guard !failed, expected != 0, event == expected else {
            failed = true; finish(.failure(AutomationError(code: .targetChanged))); return
        }
        expected = 0
        finish(.success(()))
    }

    private func prepare(_ event: Int) throws {
        guard !failed, expected == 0, continuation == nil, pending == nil else { throw AutomationError(code: .targetChanged) }
        expected = event
    }

    private func wait(until deadline: ContinuousClock.Instant) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
                if let pending { self.pending = nil; value.resume(with: pending); return }
                if Task.isCancelled { value.resume(throwing: AutomationError(code: .cancelled)); return }
                continuation = value
                timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    guard let self else { return }
                    self.failed = true; self.finish(.failure(AutomationError(code: .timeout)))
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.failed = true; self.finish(.failure(AutomationError(code: .cancelled)))
            }
        })
    }

    private func validate(_ deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline, !failed else { throw AutomationError(code: .timeout) }
        try witness()
        try await context.validate()
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline, !failed else { throw AutomationError(code: .timeout) }
        try witness()
    }

    func run(epoch: UInt64) async throws {
        guard epoch != UInt64.max else { throw AutomationError(code: .targetChanged) }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let payload = nonce + ":" + String(format: "%016llx", epoch + 1)
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.cleanupSeconds)
        do {
            try await validate(deadline)
            try prepare(1)
            guard SFRWheelObserverBegin(webView, payload, { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event) }
            }) == .OK else { throw AutomationError(code: .backendUnavailable) }
            try await wait(until: deadline)
            try await validate(deadline)
            try prepare(3)
            guard SFRWheelObserverCancel(webView) == .OK else { throw AutomationError(code: .backendUnavailable) }
            try await wait(until: deadline)
            try await validate(deadline)
            guard SFRWheelObserverDetach(webView) == .OK else { throw AutomationError(code: .backendUnavailable) }
            try await validate(deadline)
            fputs("WHEEL_OBSERVER_PROBE phase=arm_cancel_complete monitor_callback_not_required=true\n", stderr)
        } catch {
            timer?.cancel(); timer = nil
            SFRWheelObserverAbandon()
            fputs("WHEEL_OBSERVER_PROBE phase=failed client_detach_unconfirmed=true\n", stderr)
            throw error
        }
    }
}
#endif
