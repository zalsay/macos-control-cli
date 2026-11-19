import Darwin
import Foundation
import BinderIdentity
import CryptoKit

/// Minted only by the authenticated registration server for a replacement Manager.
public struct RegisteredControllerIdentity: @unchecked Sendable {
    let process: BIProcess
    fileprivate init(process: BIProcess) { self.process = process }
}

#if SAFARIER_BOUND_LOCAL_CANDIDATE
/// Long-lived registration is not a control grant. Every received socket must
/// still go through the normal per-generation Binder handshake and deadline.
enum RegistrationFrame {
    static func nonce(_ epoch: UUID) -> String {
        Data(SHA256.hash(data: Data(("safarier-control-generation-v1:" + epoch.uuidString).utf8)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func make(_ kind: String, _ epoch: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": kind, "epoch": epoch.uuidString], options: [.sortedKeys])
    }
    static func read(_ data: Data, kind: String) throws -> UUID {
        let value = try AutomationJSONBoundary.object(data)
        try AutomationJSONBoundary.exact(value, ["kind", "epoch"])
        guard value["kind"] as? String == kind, let raw = value["epoch"] as? String,
              let epoch = UUID(uuidString: raw), raw == epoch.uuidString else { throw AutomationError(code: .invalidRequest) }
        return epoch
    }
    static func deadline() throws -> FrameDeadline { try FrameDeadline(lifetimeStart: DispatchTime.now().uptimeNanoseconds) }
    static func descriptorTimeout(_ deadline: FrameDeadline) throws -> Double {
        min(try deadline.remaining(), RegistrationDescriptorTransfer.maximumTimeout)
    }
}

/// Never evict accepted epochs or admit an old generation nonce again.
/// Production roots have no count limit; explicit capacities remain available to callers.
struct RegistrationEpochHistory {
    private var accepted = Set<UUID>()
    private let capacity: Int?
    init(capacity: Int? = nil) { self.capacity = capacity }
    mutating func accept(_ epoch: UUID) -> Bool {
        guard capacity.map({ $0 > 0 && accepted.count < $0 }) ?? true, !accepted.contains(epoch) else { return false }
        accepted.insert(epoch)
        return true
    }
}

/// An authenticated Manager-to-Runner root. Closing it does not terminate a browser.
public actor RegisteredRunnerChannel {
    private let owner: RunnerControlPeer
    private let rendezvous: String?
    private let recoveredSpec: RunnerLaunchSpec?
    private let channel: AutomationChannel
    private let reader: AutomationChannel.ReaderLease
    private let inspector: FileHandle
    private let bridge: KernelIdentityBridge
    private let birth: BIProcess
    public nonisolated let profileID: UUID
    public nonisolated let runnerInstanceID: UUID
    private var pendingEpoch: UUID?
    private var closed = false

    private init(owner: RunnerControlPeer, channel: AutomationChannel, reader: AutomationChannel.ReaderLease,
                 inspector: FileHandle, bridge: KernelIdentityBridge, birth: BIProcess, profileID: UUID, runnerInstanceID: UUID, rendezvous: String?, recoveredSpec: RunnerLaunchSpec?) {
        self.rendezvous = rendezvous; self.recoveredSpec = recoveredSpec
        self.owner = owner; self.channel = channel; self.reader = reader; self.inspector = inspector
        self.bridge = bridge; self.birth = birth; self.profileID = profileID; self.runnerInstanceID = runnerInstanceID
    }
    deinit { channel.close(); try? inspector.close() }

    public static func establish(owner: OwnedRunnerProcess, channel: AutomationChannel, profileID: UUID) async throws -> RegisteredRunnerChannel {
        try await establish(owner: RunnerControlPeer(child: owner), channel: channel, profileID: profileID, rendezvous: nil)
    }

    public static func reconnect(workspace: SafarierWorkspace, profileID: UUID) async throws -> RegisteredRunnerChannel {
        guard let pid = workspace.runnerPID(profileID) else { throw AutomationError(code: .profileAlreadyRunning) }
        let d = try RegistrationFrame.deadline()
        let bridge = try KernelIdentityBridge(deadline: d)
        guard bridge.role == .main else { throw IdentityBridgeError.rejected }
        let birth = try bridge.registrationPeerMetadata(pid, deadline: d)
        let endpoint = try RegisteredRunnerRendezvous(workspace: workspace, profileID: profileID, pid: pid,
                                                       birth: birth.birth_sec, micros: birth.birth_usec)
        let channel = try endpoint.connect()
        return try await establish(owner: RunnerControlPeer(reconnectCandidatePID: pid), channel: channel,
                                   profileID: profileID, rendezvous: endpoint.path, discoveredBirth: birth)
    }

    private static func establish(owner: RunnerControlPeer, channel: AutomationChannel, profileID: UUID,
                                  rendezvous: String?, discoveredBirth: BIProcess? = nil) async throws -> RegisteredRunnerChannel {
        channel.labelRegistration(.rootManager)
        enum Stage: String { case reader, prepared, bridge, role, childBirth, peer, challenge, response, responseValidation, selfCheck, resources, childRecheck, birthMatch, peerRecheck }
        var stage = Stage.reader
        var inspector: FileHandle?
        do {
            let fd = try channel.duplicateInspector(); inspector = fd
            let reader = try channel.claimExclusiveReader()
            stage = .prepared
            guard let prepared = try await AutomationChannelDeadline.run(channel: channel, seconds: AutomationLimits.startupSeconds, operation: { try await reader.receive() }) else { throw HarnessError.eof }
            _ = try RegistrationFrame.read(prepared, kind: "prepared")
            let d = try RegistrationFrame.deadline()
            stage = .bridge
            let bridge = try KernelIdentityBridge(deadline: d)
            stage = .role
            guard bridge.role == .main else { throw IdentityBridgeError.rejected }
            stage = .childBirth
            let birth = try owner.metadata(using: bridge, deadline: d)
            if let discoveredBirth, !KernelIdentityBridge.sameProcessIdentity(discoveredBirth, birth) { throw IdentityBridgeError.rejected }
            stage = .peer
            try bridge.checkPeer(fd: fd.fileDescriptor, expected: birth, deadline: d, rendezvous: rendezvous)
            stage = .challenge
            let nonce = try AutomationSessionToken.generate()
            let challenge = try AutomationHandshakeCodec.makeChallenge(profileID: profileID, nonce: nonce)
            try await d.run(channel: channel) { try await channel.send(challenge) }
            stage = .response
            guard let response = try await d.run(channel: channel, operation: { try await reader.receive() }) else { throw HarnessError.eof }
            stage = .responseValidation
            let ready = try AutomationHandshakeCodec.readResponse(response, expectedProfileID: profileID, expectedNonce: nonce, expectedPID: owner.pid)
            stage = .selfCheck
            try bridge.checkSelf(deadline: d)
            stage = .resources
            try bridge.checkResources(deadline: d)
            stage = .childRecheck
            let after = try owner.metadata(using: bridge, deadline: d)
            stage = .birthMatch
            guard KernelIdentityBridge.sameProcessIdentity(birth, after) else { throw IdentityBridgeError.rejected }
            stage = .peerRecheck
            try bridge.checkPeer(fd: fd.fileDescriptor, expected: birth, deadline: d, rendezvous: rendezvous)
            let recoveredSpec: RunnerLaunchSpec?
            if rendezvous != nil {
                guard let info = try await d.run(channel: channel, operation: { try await reader.receive() }) else { throw HarnessError.eof }
                recoveredSpec = try RegistrationLaunchInfo.parse(info, profileID: profileID)
                try bridge.checkPeer(fd: fd.fileDescriptor, expected: birth, deadline: d, rendezvous: rendezvous)
            } else { recoveredSpec = nil }
            return RegisteredRunnerChannel(owner: owner, channel: channel, reader: reader, inspector: fd, bridge: bridge,
                                           birth: birth, profileID: profileID, runnerInstanceID: ready.runnerInstanceID,
                                           rendezvous: rendezvous, recoveredSpec: recoveredSpec)
        } catch {
            RootIdentityDiagnostic.emit("ROOT_DIAG side=manager stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            channel.close(); try? inspector?.close(); throw error
        }
    }
    private func check(_ d: FrameDeadline) throws {
        enum Stage: String { case owner, selfCheck, resources, birth, birthMatch, peer }
        var stage = Stage.owner
        do {
            guard !closed, owner.isRunning else { throw IdentityBridgeError.rejected }
            stage = .selfCheck
            try bridge.checkSelf(deadline: d)
            stage = .resources
            try bridge.checkResources(deadline: d)
            stage = .birth
            let now = try owner.metadata(using: bridge, deadline: d)
            stage = .birthMatch
            guard KernelIdentityBridge.sameProcessIdentity(birth, now) else { throw IdentityBridgeError.rejected }
            stage = .peer
            try bridge.checkPeer(fd: inspector.fileDescriptor, expected: birth, deadline: d, rendezvous: rendezvous)
        } catch {
            RootIdentityDiagnostic.emit("GENERATION_CHECK_DIAG side=manager stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            throw error
        }
    }
    public func openGeneration() async throws -> (epoch: UUID, channel: AutomationChannel) {
        // A failed drain permanently closes the root while retaining its epoch.
        // Report that terminal state before considering an in-progress generation.
        guard !closed else { throw AutomationError(code: .backendUnavailable) }
        guard pendingEpoch == nil else { throw AutomationError(code: .sessionBusy) }
        enum Stage: String { case deadline, initialCheck, pair, frame, send, descriptor, ack, childClose, afterAckCheck }
        var stage = Stage.deadline
        do {
            let d = try RegistrationFrame.deadline()
            stage = .initialCheck
            try check(d)
            let epoch = UUID(); pendingEpoch = epoch
            stage = .pair
            let pair = try AutomationChannel.makePair()
            pair.parent.labelRegistration(.generationManager)
            do {
                stage = .frame
                let frame = try RegistrationFrame.make("generation", epoch)
                stage = .send
                try await d.run(channel: channel) { try await self.channel.send(frame) }
                stage = .descriptor
                try await channel.sendRegisteredDescriptor(pair.child, timeout: try RegistrationFrame.descriptorTimeout(d))
                stage = .ack
                guard let ack = try await d.run(channel: channel, operation: { try await self.reader.receive() }),
                      try RegistrationFrame.read(ack, kind: "accepted") == epoch else { throw AutomationError(code: .invalidRequest) }
                // Keep the original endpoint alive until the Runner has adopted
                // the transferred descriptor, not merely until sendmsg returns.
                stage = .childClose
                try pair.child.close()
                stage = .afterAckCheck
                try check(d)
                return (epoch, pair.parent)
            } catch { pair.parent.close(); try? pair.child.close(); throw error }
        } catch {
            RootIdentityDiagnostic.emit("GENERATION_OPEN_DIAG side=manager stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            closed = true; channel.close(); throw error
        }
    }
    /// Creates a fresh original Binder context only after root registration and
    /// descriptor acknowledgement. No old context or authorization is reused.
    public func openRecoveredClient(workspace: SafarierWorkspace) async throws -> (epoch: UUID, client: AutomationRunnerClient) {
        guard let recoveredSpec else { throw AutomationError(code: .invalidRequest) }
        return try await openClient(workspace: workspace, spec: recoveredSpec, environment: recoveredSpec.environment(inheriting: [:]))
    }
    public func openClient(workspace: SafarierWorkspace, spec: RunnerLaunchSpec, environment: [String: String]) async throws -> (epoch: UUID, client: AutomationRunnerClient) {
        guard spec.registeredInteractive, spec.profileID == profileID else { throw AutomationError(code: .invalidRequest) }
        // The Runner starts its own lifetime after receiving the generation;
        // starting here makes the controller cutoff a conservative bound.
        let start = DispatchTime.now().uptimeNanoseconds
        enum Stage: String { case openGeneration, prepare, captureBirth, match, attach, startClient, instanceMatch }
        var stage = Stage.openGeneration
        let opened: (epoch: UUID, channel: AutomationChannel)
        do { opened = try await openGeneration() }
        catch {
            RootIdentityDiagnostic.emit("GENERATION_DIAG side=manager stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            throw error
        }
        do {
            stage = .prepare
            let (cutoff, overflow) = start.addingReportingOverflow(UInt64(AutomationLimits.startupSeconds * 1_000_000_000))
            guard !overflow else { throw HarnessError.invalidClock }
            let context = try await ControllerGenerationContext.prepare(channel: opened.channel, workspace: workspace,
                expectedSpec: spec, actualArgs: spec.arguments(), environment: environment,
                lifetimeStart: start, startupCutoff: cutoff, registrationNonce: RegistrationFrame.nonce(opened.epoch))
            do {
                stage = .captureBirth
                let current = try owner.metadata(using: bridge, deadline: RegistrationFrame.deadline())
                stage = .match
                guard KernelIdentityBridge.sameProcessIdentity(current, birth) else { throw IdentityBridgeError.rejected }
                stage = .attach
                try await context.attachControlPeerOnce(owner, birth: birth)
                stage = .startClient
                let client = try await AutomationRunnerClient.startFixture(context: context, startupCutoff: cutoff)
                stage = .instanceMatch
                guard client.runnerInstanceID == runnerInstanceID else { await client.close(); throw IdentityBridgeError.rejected }
                return (opened.epoch, client)
            } catch { await context.safeClose(); throw error }
        } catch {
            RootIdentityDiagnostic.emit("GENERATION_DIAG side=manager stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            opened.channel.close(); closed = true; channel.close(); throw error
        }
    }
    /// Called after the generation has independently drained its input and replies.
    public func confirmDrained(epoch: UUID, timeoutSeconds: Double = AutomationLimits.cleanupSeconds) async throws {
        do {
            guard pendingEpoch == epoch else { throw AutomationError(code: .invalidRequest) }
            let d = try RegistrationFrame.deadline()
            guard timeoutSeconds > 0, timeoutSeconds <= AutomationLimits.cleanupSeconds else { throw AutomationError(code: .invalidRequest) }
            guard let frame = try await AutomationChannelDeadline.run(channel: channel, seconds: timeoutSeconds, operation: { try await self.reader.receive() }),
                  try RegistrationFrame.read(frame, kind: "drained") == epoch else { throw AutomationError(code: .invalidRequest) }
            try check(d); pendingEpoch = nil
        } catch { closed = true; channel.close(); throw error }
    }
}

/// Only non-secret launch inputs from the authenticated live Runner.
private struct RegistrationLaunchInfo: Codable {
    let arguments: [String]
    let timeZone: String?
    static func encode(_ spec: RunnerLaunchSpec) throws -> Data {
        try JSONEncoder().encode(Self(arguments: spec.arguments(), timeZone: spec.timeZoneIdentifier))
    }
    static func parse(_ data: Data, profileID: UUID) throws -> RunnerLaunchSpec {
        let info = try JSONDecoder().decode(Self.self, from: data)
        let spec = try RunnerLaunchSpec.parse(info.arguments, environment: info.timeZone.map { ["TZ": $0] } ?? [:])
        guard spec.profileID == profileID, spec.registeredInteractive, spec.arguments() == info.arguments else {
            throw AutomationError(code: .invalidRequest)
        }
        return spec
    }
}

/// Runner side. A new root is possible only after the previous generation drained.
public enum RegisteredRunnerServer {
    public enum GenerationExit: Sendable {
        case drained, drainedCloseRoot, unconfirmed
    }
    public typealias Generation = @Sendable (UUID, AutomationChannel, RegisteredControllerIdentity?) async -> GenerationExit

    public static func serve(channel: AutomationChannel, spec: RunnerLaunchSpec, runnerInstanceID: UUID, originalLock: ProfileLock,
                             workspace: SafarierWorkspace, generation: @escaping Generation) async -> Bool {
        var epochs = RegistrationEpochHistory()
        guard await serveRoot(channel: channel, spec: spec, runnerInstanceID: runnerInstanceID, originalLock: originalLock,
                              workspace: workspace, rendezvous: nil, epochs: &epochs, generation: generation) else { return false }
        // The inherited root is the only path while the original Manager lives.
        // A replacement Manager can discover us only after reparenting.
        do {
            // A normal quit may close descriptors before launchd reaps the old
            // Manager. Wait off the UI thread; never accept while it is the parent.
            while getppid() != 1 { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
            let d = try RegistrationFrame.deadline()
            let bridge = try KernelIdentityBridge(deadline: d), birth = bridge.ownRegistrationBirth()
            guard bridge.role == .runner, birth.ppid == 1 else { throw IdentityBridgeError.rejected }
            let endpoint = try RegisteredRunnerRendezvous(workspace: workspace, profileID: spec.profileID, pid: birth.pid,
                                                           birth: birth.birth_sec, micros: birth.birth_usec)
            let listener = try endpoint.listen()
            while !Task.isCancelled {
                let next = try await listener.accept()
                guard await serveRoot(channel: next, spec: spec, runnerInstanceID: runnerInstanceID, originalLock: originalLock,
                                      workspace: workspace, rendezvous: endpoint.path, epochs: &epochs, generation: generation) else { return false }
            }
            return true
        } catch {
            RootIdentityDiagnostic.emit("ROOT_DIAG side=runner stage=rendezvous error=\(RootIdentityDiagnostic.classification(error))")
            return false
        }
    }

    private static func serveRoot(channel: AutomationChannel, spec: RunnerLaunchSpec, runnerInstanceID: UUID, originalLock: ProfileLock,
                                  workspace: SafarierWorkspace, rendezvous: String?, epochs: inout RegistrationEpochHistory,
                                  generation: @escaping Generation) async -> Bool {
        let profileID = spec.profileID
        channel.labelRegistration(.rootRunner)
        var rootAuthenticated = false
        var generationDrained = true
        enum Stage: String { case bridge, role, parent, reader, lock, prepared, challenge, selfCheck, resources, parentRecheck, peer, lockCheck, response, generation }
        var stage = Stage.bridge
        var inspector: FileHandle?
        do {
            let first = try RegistrationFrame.deadline()
            let bridge = try KernelIdentityBridge(deadline: first)
            stage = .role
            guard bridge.role == .runner else { throw IdentityBridgeError.rejected }
            stage = .parent
            let fd = try channel.duplicateInspector(); inspector = fd
            let parent: BIProcess
            if let rendezvous {
                guard getppid() == 1 else { throw IdentityBridgeError.rejected }
                parent = try bridge.registrationPeerMetadata(bridge.registrationPeerPID(fd: fd.fileDescriptor), deadline: first)
                try bridge.checkPeer(fd: fd.fileDescriptor, expected: parent, deadline: first, rendezvous: rendezvous)
            } else { parent = try bridge.actualParentMetadata(deadline: first) }
            func checkController(_ d: FrameDeadline) throws {
                if rendezvous == nil { try bridge.checkActualParent(parent, deadline: d) }
                try bridge.checkPeer(fd: fd.fileDescriptor, expected: parent, deadline: d, rendezvous: rendezvous)
            }
            stage = .reader
            let reader = try channel.claimExclusiveReader()
            stage = .lock
            let loan = try originalLock.borrow(profileID: profileID, directory: workspace.locksDirectory)
            defer { loan.finish() }
            stage = .prepared
            let prepared = try RegistrationFrame.make("prepared", UUID())
            try await first.run(channel: channel) { try await channel.send(prepared) }
            stage = .challenge
            guard let hello = try await first.run(channel: channel, operation: { try await reader.receive() }) else { throw HarnessError.eof }
            let challenge = try AutomationHandshakeCodec.readChallenge(hello, expectedProfileID: profileID)
            stage = .selfCheck
            try bridge.checkSelf(deadline: first)
            stage = .resources
            try bridge.checkResources(deadline: first)
            stage = .parentRecheck
            stage = .peer
            try checkController(first)
            stage = .lockCheck
            guard loan.check() else { throw IdentityBridgeError.rejected }
            loan.finish()
            stage = .response
            let ready = try AutomationHandshakeCodec.makeResponse(challenge, runnerInstanceID: runnerInstanceID, runnerPID: getpid())
            try await first.run(channel: channel) { try await channel.send(ready) }
            rootAuthenticated = true
            if rendezvous != nil {
                let info = try RegistrationLaunchInfo.encode(spec)
                try await first.run(channel: channel) { try await channel.send(info) }
            }
            let replacement = rendezvous.map { _ in RegisteredControllerIdentity(process: parent) }
            stage = .generation
            while let request = try await reader.receive() {
                let d = try RegistrationFrame.deadline()
                let epoch = try RegistrationFrame.read(request, kind: "generation")
                try bridge.checkSelf(deadline: d); try bridge.checkResources(deadline: d)
                try checkController(d)
                guard epochs.accept(epoch) else { throw AutomationError(code: .invalidRequest) }
                let raw = try await reader.receiveRegisteredDescriptor(timeout: try RegistrationFrame.descriptorTimeout(d))
                let generationChannel: AutomationChannel
                do { generationChannel = try AutomationChannel(adopting: raw); generationChannel.labelRegistration(.generationRunner) }
                catch { try? raw.close(); throw error }
                let ack = try RegistrationFrame.make("accepted", epoch)
                try await d.run(channel: channel) { try await channel.send(ack) }
                generationDrained = false
                let finished = await generation(epoch, generationChannel, replacement)
                generationChannel.close()
                switch finished {
                case .unconfirmed: throw AutomationError(code: .backendUnavailable)
                case .drainedCloseRoot:
                    channel.close(); try? fd.close(); return true
                case .drained: generationDrained = true
                }
                let finish = try RegistrationFrame.deadline()
                try checkController(finish)
                let drained = try RegistrationFrame.make("drained", epoch)
                try await finish.run(channel: channel) { try await channel.send(drained) }
            }
            channel.close(); try? fd.close(); return true
        } catch {
            RootIdentityDiagnostic.emit("ROOT_DIAG side=runner stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            channel.close(); try? inspector?.close()
            return generationDrained && (rootAuthenticated || rendezvous != nil)
        }
    }
}
#endif
