import Foundation
import Darwin
import SafarierCore
#if !MANAGER_STANDALONE
import XCTest
@testable import Safarier
#endif

// Manager aggregation tests only: injected endpoint is not Binder/peer evidence.
public enum AutomationManagerCloseProofCases {
    struct Failure: Error { let label: String }
    enum Mode { case positive, notClean, wrongID, wrongKind, forgedTermination, thrown, late, duplicate }
    actor Endpoint: AutomationManagerEndpoint {
        nonisolated let pid: Int32 = 4321
        nonisolated let runnerInstanceID = UUID()
        nonisolated let ownershipID = UUID()
        private let profileID: UUID
        private let mode: Mode
        private let token = String(repeating: "A", count: 43)
        private let window = UUID(), page = UUID()
        private var closeRPCs = 0, closes = 0
        private var rpcTimeout: Double?, exitTimeout: Double?
        init(profileID: UUID, mode: Mode) { self.profileID = profileID; self.mode = mode }
        func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
            switch request.action {
            case .openSession:
                let target = AutomationTargetIdentity(profileID: profileID, runnerInstanceID: runnerInstanceID, windowID: window, pageID: page)
                let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
                return AutomationReply(requestID: request.requestID, outcome: .success(.sessionOpened(sessionID: token, target: target, viewport: viewport)))
            case .closeSession, .cancel:
                guard request.sessionID == token else { throw AutomationError(code: .sessionNotFound) }
                closeRPCs += 1; rpcTimeout = timeoutSeconds
                if mode == .thrown { throw AutomationError(code: .runnerExited) }
                if mode == .late {
                    // Intentionally ignores task cancellation; exercises late completion, not polling.
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2.3) { continuation.resume() }
                    }
                }
                let id = mode == .wrongID ? UUID() : request.requestID
                let outcome: AutomationOutcome
                if mode == .wrongKind { outcome = .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)) }
                else { outcome = .success(.sessionClosed(CleanupReceipt(cleaned: mode != .notClean, terminatedOwnedRunner: mode == .forgedTermination))) }
                return AutomationReply(requestID: id, outcome: outcome)
            default: throw AutomationError(code: .invalidRequest)
            }
        }
        func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? {
            closes += 1; exitTimeout = timeoutSeconds
            if mode == .notClean { return ProcessExit(pid: pid, status: 0, uncaughtSignal: false) }
            return nil
        }
        func observation() -> (Int, Int, Double?, Double?) { (closeRPCs, closes, rpcTimeout, exitTimeout) }
    }
    @MainActor public static func run(_ label: String) async throws {
        let mode: Mode
        switch label {
        case "positive": mode = .positive
        case "false_exit": mode = .notClean
        case "wrong_id": mode = .wrongID
        case "wrong_kind": mode = .wrongKind
        case "forged_exit": mode = .forgedTermination
        case "throw": mode = .thrown
        case "late": mode = .late
        case "duplicate": mode = .duplicate
        default: throw Failure(label: "unknown_case")
        }
        let uid = geteuid()
        let proof = AutomationScriptCallerProof(effectiveUID: uid, pid: 123, auditToken: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
        let profile = Profile(name: "fixture", mode: .ephemeral, allowsBackgroundAutomation: true)
        let endpoint = Endpoint(profileID: profile.id, mode: mode)
        let manager = AutomationManager(profileReader: { id in id == profile.id ? profile : nil }, humanRunning: { _ in false }, runnerFactory: { _ in endpoint }, admission: { true }, now: { ProcessInfo.processInfo.systemUptime }, sleepUntil: { deadline in
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        })
        let open = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .openSession(profileID: profile.id))
        let opened = await manager.handle(open, role: .manager, proof: proof, currentUID: uid)
        guard case .success(.sessionOpened(let token, _, _)) = opened.outcome else { throw Failure(label: label + ".open") }
        let close = AutomationRequest(version: 1, requestID: UUID(), sessionID: token, action: .closeSession)
        let started = ProcessInfo.processInfo.systemUptime
        let result: AutomationReply
        if mode == .duplicate {
            async let first = manager.handle(close, role: .manager, proof: proof, currentUID: uid)
            async let second = manager.handle(close, role: .manager, proof: proof, currentUID: uid)
            let (a, b) = await (first, second)
            guard a == b else { throw Failure(label: label + ".concurrent_close") }
            result = a
        } else {
            result = await manager.handle(close, role: .manager, proof: proof, currentUID: uid)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard case .success(.sessionClosed(let receipt)) = result.outcome else { throw Failure(label: label + ".reply") }
        switch mode {
        case .positive, .duplicate:
            guard receipt.cleaned, !receipt.terminatedOwnedRunner else { throw Failure(label: label + ".expected_real_clean_proof") }
        case .notClean:
            guard !receipt.cleaned, receipt.terminatedOwnedRunner else { throw Failure(label: label + ".exit_is_not_clean") }
        default:
            guard !receipt.cleaned, !receipt.terminatedOwnedRunner else { throw Failure(label: label + ".reject_untrusted_proof") }
        }
        if mode == .late {
            guard elapsed < AutomationLimits.cleanupSeconds + 0.6 else { throw Failure(label: label + ".one_budget") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if mode == .duplicate || mode == .late {
            let repeated = await manager.handle(close, role: .manager, proof: proof, currentUID: uid)
            guard repeated == result else { throw Failure(label: label + ".stable_replay") }
        }
        let counts = await endpoint.observation()
        guard counts.0 == 1, counts.1 == 1 else { throw Failure(label: label + ".one_rpc_one_owned_close") }
        guard let rpcTimeout = counts.2, rpcTimeout > 0, rpcTimeout <= AutomationLimits.cleanupSeconds,
              let exitTimeout = counts.3, exitTimeout >= 0, exitTimeout <= AutomationLimits.cleanupSeconds else { throw Failure(label: label + ".bounded_timeouts") }
    }
}

#if !MANAGER_STANDALONE
final class AutomationManagerCloseProofTests: XCTestCase {
    @MainActor func testCases() async throws {
        for label in ["positive", "false_exit", "wrong_id", "wrong_kind", "forged_exit", "throw", "late", "duplicate"] {
            try await AutomationManagerCloseProofCases.run(label)
        }
    }
}
#endif
