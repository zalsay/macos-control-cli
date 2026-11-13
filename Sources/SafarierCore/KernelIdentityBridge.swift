import Foundation
import Darwin
import BinderIdentity
import OSLog

enum IdentityBridgeError: Error { case rejected, unsupportedParentAuthority, collector(String, Int32) }

// Fixed classifications only: never render arbitrary errors or associated paths.
package enum RootIdentityDiagnostic {
    package static func classification(_ error: Error) -> String {
        if let error = error as? AutomationChannel.ChannelError {
            switch error {
            case .closed: return "channel_closed"
            case .invalidSocket: return "channel_invalidSocket"
            case .invalidFrameLength: return "channel_invalidFrameLength"
            case .sendBackpressure: return "channel_sendBackpressure"
            case .truncatedFrame: return "channel_truncatedFrame"
            case .readerConflict: return "channel_readerConflict"
            case .systemCall(let code): return "channel_systemCall_\(code)"
            }
        }
        if let error = error as? IdentityBridgeError {
            switch error {
            case .rejected: return "identity_rejected"
            case .unsupportedParentAuthority: return "parent_authority"
            case .collector(let operation, let code):
                let fixed = ["metadata", "static", "self", "resource", "peer", "bundle"].contains(operation) ? operation : "unknown"
                return "collector_" + fixed + "_" + String(code)
            }
        }
        if let error = error as? HarnessError {
            switch error {
            case .identityNotReady: return "identity_not_ready"
            case .invalidClock: return "invalid_clock"
            case .deadline: return "deadline"
            case .eof: return "eof"
            case .invalidMode: return "invalid_mode"
            case .environment: return "environment"
            }
        }
        if let error = error as? RepositoryBindingProvider.Failure {
            switch error {
            case .invalidExecutablePath: return "repository_invalidExecutablePath"
            case .invalidArguments: return "repository_invalidArguments"
            case .directoryChanged: return "repository_directoryChanged"
            case .unsafeLock: return "repository_unsafeLock"
            case .lockUnavailable: return "repository_lockUnavailable"
            case .lockLost: return "repository_lockLost"
            case .unsafeRepository: return "repository_unsafeRepository"
            case .repositoryTooLarge: return "repository_repositoryTooLarge"
            case .snapshotFailed: return "repository_snapshotFailed"
            case .repositoryChanged: return "repository_repositoryChanged"
            case .decodingFailed: return "repository_decodingFailed"
            case .duplicateID: return "repository_duplicateID"
            case .missingProfile: return "repository_missingProfile"
            case .profileDenied: return "repository_profileDenied"
            case .deadline: return "repository_deadline"
            case .closed: return "repository_closed"
            }
        }
        if let fixed = fixtureContextFailureDiagnostic(error) { return fixed }
        if let error = error as? AutomationError { return "automation_" + error.code.rawValue }
        if error is CancellationError { return "cancelled" }
        return "other"
    }
    package static func emit(_ message: String, monotonicNanoseconds: UInt64? = nil) {
        let message = message + " pid=\(getpid()) monotonic_ns=\(monotonicNanoseconds ?? DispatchTime.now().uptimeNanoseconds)"
        fputs(message + "\n", stderr)
        Logger(subsystem: "sh.safarier", category: "registered-root").notice("\(message, privacy: .public)")
    }
}

// Actual C observations only. No synthetic verifier, identity claim from wire,
// path from argv/environment, or exported raw audit token.
final class KernelIdentityBridge {
    private var selfPin: BIImagePin
    private var peerPin: BIImagePin
    let role: BoundBundleRole
    let mainExecutablePath: String
    let runnerExecutablePath: String
    private let bundle: BundleResourcePin
    private let selfExpected: BIProcess
    let executablePath: String
    private var selfBaseline: BIEvidence
    private var peerBaseline: BIEvidence?

    private enum CollectorPhase: String { case metadata, staticPin = "static", selfCapture = "self", resource, peer }
    private static func checked(_ deadline: FrameDeadline, _ phase: CollectorPhase, _ operation: (UInt64, UnsafeMutablePointer<BIDiagnostic>) -> BIError) throws {
        try Task.checkCancellation()
        let remaining = try deadline.remaining()
        let ms = min(2999, Int((remaining * 1000).rounded(.down)))
        guard ms > 0 else { throw HarnessError.deadline }
        let cDeadline = bi_deadline_after_ms(UInt32(ms))
        guard cDeadline != 0 else { throw HarnessError.deadline }
        var diagnostic = BIDiagnostic()
        let result = operation(cDeadline, &diagnostic)
        _ = try deadline.remaining()
        try Task.checkCancellation()
        guard result == BI_OK else {
            RootIdentityDiagnostic.emit("IDENTITY_DIAG collector=\(phase.rawValue) result=\(result.rawValue)")
            if result == BI_CHANGED || (phase == .peer && result == BI_INVALID && diagnostic.stage != BI_STAGE_NONE) {
                RootIdentityDiagnostic.emit("phase=collector-diagnostic operation=\(phase.rawValue) stage=\(diagnostic.stage.rawValue) fields=\(diagnostic.fields) depth=\(diagnostic.depth)")
            }
            throw IdentityBridgeError.collector(phase.rawValue, Int32(result.rawValue))
        }
    }
    private static func path(_ process: BIProcess) throws -> String {
        var p = process
        return try withUnsafePointer(to: &p.path) { tuple in
            try tuple.withMemoryRebound(to: CChar.self, capacity: 4096) { c in
                guard let s = String(validatingUTF8:c), s.hasPrefix("/") else { throw IdentityBridgeError.rejected }
                return s
            }
        }
    }
    static func sameProcessIdentity(_ a: BIProcess, _ b: BIProcess) -> Bool {
        guard a.pid == b.pid, a.ppid == b.ppid, a.ruid == b.ruid, a.euid == b.euid,
              a.birth_sec == b.birth_sec, a.birth_usec == b.birth_usec,
              let aPath = try? path(a), let bPath = try? path(b) else { return false }
        return aPath == bPath
    }
    init(deadline: FrameDeadline) throws {
        #if !SAFARIER_BOUND_LOCAL_CANDIDATE
        throw IdentityBridgeError.rejected
        #else
        enum InitStage: String { case metadata, role, mainPin, runnerPin, selfCapture, selfMatch, mainBundle, runnerBundle, mainRevalidate, selfRecapture, selfRematch }
        var stage = InitStage.metadata
        var completed = false
        defer { if !completed { RootIdentityDiagnostic.emit("IDENTITY_DIAG phase=initialize stage=\(stage.rawValue) result=failed") } }
        var me = BIProcess()
        try Self.checked(deadline, .metadata) { bi_process_metadata_diagnostic(getpid(),$0,&me,$1) }
        let executable = try Self.path(me)
        stage = .role
        let roles = try BoundBundleRoles(selfExecutablePath: executable)
        var mainPin = BIImagePin(), runnerPin = BIImagePin()
        stage = .mainPin
        try Self.checked(deadline, .staticPin) { d, diag in roles.mainExecutablePath.withCString { bi_static_pin_diagnostic($0,d,&mainPin,diag) } }
        stage = .runnerPin
        try Self.checked(deadline, .staticPin) { d, diag in roles.runnerExecutablePath.withCString { bi_static_pin_diagnostic($0,d,&runnerPin,diag) } }
        var ownPin = roles.role == .main ? mainPin : runnerPin
        var initial = BIEvidence()
        stage = .selfCapture
        try Self.checked(deadline, .selfCapture) { bi_capture_self_diagnostic(&ownPin,$0,&initial,$1) }
        stage = .selfMatch
        guard bi_match(&ownPin,&me,&initial) != 0 else { throw IdentityBridgeError.rejected }
        stage = .mainBundle
        let bundle = try BundleResourcePin.capture(root: roles.outerRoot, contract: .localCandidate, deadline: deadline)
        // Independently validate the helper's own fixed Info, identity and exact namespace.
        stage = .runnerBundle
        let runnerBundle = try BundleResourcePin.capture(root: roles.runnerRoot, contract: .localCandidateRunner, deadline: deadline)
        // Bracket the child capture with the already fixed full parent inventory.
        stage = .mainRevalidate
        try bundle.revalidate(deadline: deadline)
        withExtendedLifetime(runnerBundle) {}
        var post = BIEvidence()
        stage = .selfRecapture
        try Self.checked(deadline, .selfCapture) { bi_capture_self_diagnostic(&ownPin,$0,&post,$1) }
        stage = .selfRematch
        guard bi_match(&ownPin,&me,&post) != 0, bi_evidence_same(&initial,&post) != 0 else { throw IdentityBridgeError.rejected }
        fputs("phase=bundle-self verified=true executablePathMatched=true bundleValidated=true\n",stderr)
        self.selfPin = ownPin; self.peerPin = roles.role == .main ? runnerPin : mainPin
        self.role = roles.role; self.mainExecutablePath = roles.mainExecutablePath; self.runnerExecutablePath = roles.runnerExecutablePath
        self.bundle = bundle
        self.selfExpected = me; self.selfBaseline = initial; self.executablePath = executable
        completed = true
        #endif
    }
    func checkSelf(deadline: FrameDeadline) throws {
        var observation = BIEvidence()
        try Self.checked(deadline, .selfCapture) { bi_capture_self_diagnostic(&selfPin,$0,&observation,$1) }
        var expected = selfExpected
        guard bi_match(&selfPin,&expected,&observation) != 0,
              bi_evidence_same(&selfBaseline,&observation) != 0 else { throw IdentityBridgeError.rejected }
    }
    func checkResources(deadline: FrameDeadline) throws {
        try bundle.revalidate(deadline: deadline)
    }
    func ownedChildMetadata(_ owner: OwnedRunnerProcess, deadline: FrameDeadline) throws -> BIProcess {
        guard role == .main, owner.isRunning else { throw IdentityBridgeError.rejected }
        var result = BIProcess()
        try Self.checked(deadline, .metadata) { bi_process_metadata_diagnostic(owner.pid,$0,&result,$1) }
        guard owner.isRunning, result.pid == owner.pid, result.ppid == getpid(),
              result.ruid == getuid(), result.euid == geteuid(), result.birth_sec != 0,
              try Self.path(result) == runnerExecutablePath else { throw IdentityBridgeError.rejected }
        return result
    }
    func actualParentMetadata(deadline: FrameDeadline) throws -> BIProcess {
        guard role == .runner else { throw IdentityBridgeError.rejected }
        let parent = getppid()
        guard parent > 1 else { throw IdentityBridgeError.rejected }
        var result = BIProcess()
        try Self.checked(deadline, .metadata) { bi_process_metadata_diagnostic(parent,$0,&result,$1) }
        guard getppid() == parent, result.pid == parent,
              result.ruid == getuid(), result.euid == geteuid(), result.birth_sec != 0,
              try Self.path(result) == mainExecutablePath else { throw IdentityBridgeError.rejected }
        return result
    }
    func checkActualParent(_ expected: BIProcess, deadline: FrameDeadline) throws {
        let actual = try actualParentMetadata(deadline: deadline)
        guard actual.pid == expected.pid, actual.ppid == expected.ppid,
              actual.ruid == expected.ruid, actual.euid == expected.euid,
              actual.birth_sec == expected.birth_sec, actual.birth_usec == expected.birth_usec,
              try Self.path(actual) == Self.path(expected) else { throw IdentityBridgeError.rejected }
    }
    // Caller supplies expected metadata from retained-child or actual-parent
    // authority; peer observation alone never establishes ownership.
    func checkPeer(fd: Int32, expected: BIProcess, deadline: FrameDeadline) throws {
        var e = BIEvidence(), expected = expected
        do { try Self.checked(deadline, .peer) { bi_capture_peer_diagnostic(fd,&expected,&peerPin,$0,&e,$1) } }
        catch {
            var peer: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            let ok = getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&peer,&size) == 0 && size == MemoryLayout<Int32>.size
            fputs("phase=peer-reject peerAvailable=\(ok) peerExpected=\(ok && peer == expected.pid) parentExpected=\(getppid() == expected.pid)\n",stderr)
            throw error
        }
        guard bi_match(&peerPin,&expected,&e) != 0 else { throw IdentityBridgeError.rejected }
        if var first = peerBaseline {
            guard bi_evidence_same(&first,&e) != 0 else { throw IdentityBridgeError.rejected }
        } else { peerBaseline = e }
        fputs("phase=bundle-peer verified=true processAndCodeMatched=true stable=true\n",stderr)
    }
}
