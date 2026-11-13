import Foundation
import BinderIdentity
import CryptoKit

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

/// Never evict accepted epochs: reaching the bound closes this root instead of
/// letting an old generation nonce become valid again.
struct RegistrationEpochHistory {
    private var accepted = Set<UUID>()
    private let capacity: Int
    init(capacity: Int = 4096) { self.capacity = capacity }
    mutating func accept(_ epoch: UUID) -> Bool {
        guard capacity > 0, accepted.count < capacity, !accepted.contains(epoch) else { return false }
        accepted.insert(epoch)
        return true
    }
}

/// Owned by the Manager that created the actual Foundation child. Losing this
/// object closes registration but does not terminate a human browser.
public actor RegisteredRunnerChannel {
    private let owner: OwnedRunnerProcess
    private let channel: AutomationChannel
    private let reader: AutomationChannel.ReaderLease
    private let inspector: FileHandle
    private let bridge: KernelIdentityBridge
    private let birth: BIProcess
    public nonisolated let profileID: UUID
    public nonisolated let runnerInstanceID: UUID
    private var pendingEpoch: UUID?
    private var closed = false

    private init(owner: OwnedRunnerProcess, channel: AutomationChannel, reader: AutomationChannel.ReaderLease,
                 inspector: FileHandle, bridge: KernelIdentityBridge, birth: BIProcess, profileID: UUID, runnerInstanceID: UUID) {
        self.owner = owner; self.channel = channel; self.reader = reader; self.inspector = inspector
        self.bridge = bridge; self.birth = birth; self.profileID = profileID; self.runnerInstanceID = runnerInstanceID
    }
    deinit { channel.close(); try? inspector.close() }

    public static func establish(owner: OwnedRunnerProcess, channel: AutomationChannel, profileID: UUID) async throws -> RegisteredRunnerChannel {
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
            let birth = try bridge.ownedChildMetadata(owner, deadline: d)
            stage = .peer
            try bridge.checkPeer(fd: fd.fileDescriptor, expected: birth, deadline: d)
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
            let after = try bridge.ownedChildMetadata(owner, deadline: d)
            stage = .birthMatch
            guard KernelIdentityBridge.sameProcessIdentity(birth, after) else { throw IdentityBridgeError.rejected }
            stage = .peerRecheck
            try bridge.checkPeer(fd: fd.fileDescriptor, expected: birth, deadline: d)
            return RegisteredRunnerChannel(owner: owner, channel: channel, reader: reader, inspector: fd, bridge: bridge, birth: birth, profileID: profileID, runnerInstanceID: ready.runnerInstanceID)
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
            let now = try bridge.ownedChildMetadata(owner, deadline: d)
            stage = .birthMatch
            guard KernelIdentityBridge.sameProcessIdentity(birth, now) else { throw IdentityBridgeError.rejected }
            stage = .peer
            try bridge.checkPeer(fd: inspector.fileDescriptor, expected: birth, deadline: d)
        } catch {
            RootIdentityDiagnostic.emit("GENERATION_CHECK_DIAG side=manager stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            throw error
        }
    }
    public func openGeneration() async throws -> (epoch: UUID, channel: AutomationChannel) {
        guard pendingEpoch == nil else { throw AutomationError(code: .sessionBusy) }
        enum Stage: String { case deadline, initialCheck, pair, frame, send, descriptor, childClose, ack, afterAckCheck }
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
                stage = .childClose
                try pair.child.close()
                stage = .ack
                guard let ack = try await d.run(channel: channel, operation: { try await self.reader.receive() }),
                      try RegistrationFrame.read(ack, kind: "accepted") == epoch else { throw AutomationError(code: .invalidRequest) }
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
                let current = try await context.captureOwnedBirth(owner)
                stage = .match
                guard KernelIdentityBridge.sameProcessIdentity(current, birth) else { throw IdentityBridgeError.rejected }
                stage = .attach
                try await context.attachOwnedChildOnce(owner, birth: birth)
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

/// Runner side. The callback must return true only when the old generation's
/// input and replies are confirmed drained; false permanently closes the root.
public enum RegisteredRunnerServer {
    public static func serve(channel: AutomationChannel, profileID: UUID, runnerInstanceID: UUID, originalLock: ProfileLock,
                             workspace: SafarierWorkspace, generation: @escaping @Sendable (UUID, AutomationChannel) async -> Bool) async -> Bool {
        channel.labelRegistration(.rootRunner)
        enum Stage: String { case bridge, role, parent, reader, lock, prepared, challenge, selfCheck, resources, parentRecheck, peer, lockCheck, response, generation }
        var stage = Stage.bridge
        var inspector: FileHandle?
        do {
            let first = try RegistrationFrame.deadline()
            let bridge = try KernelIdentityBridge(deadline: first)
            stage = .role
            guard bridge.role == .runner else { throw IdentityBridgeError.rejected }
            stage = .parent
            let parent = try bridge.actualParentMetadata(deadline: first)
            stage = .reader
            let fd = try channel.duplicateInspector(); inspector = fd
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
            try bridge.checkActualParent(parent, deadline: first)
            stage = .peer
            try bridge.checkPeer(fd: fd.fileDescriptor, expected: parent, deadline: first)
            stage = .lockCheck
            guard loan.check() else { throw IdentityBridgeError.rejected }
            loan.finish()
            stage = .response
            let ready = try AutomationHandshakeCodec.makeResponse(challenge, runnerInstanceID: runnerInstanceID, runnerPID: getpid())
            try await first.run(channel: channel) { try await channel.send(ready) }
            stage = .generation
            var epochs = RegistrationEpochHistory()
            while let request = try await reader.receive() {
                let d = try RegistrationFrame.deadline()
                let epoch = try RegistrationFrame.read(request, kind: "generation")
                try bridge.checkSelf(deadline: d); try bridge.checkResources(deadline: d)
                try bridge.checkActualParent(parent, deadline: d)
                try bridge.checkPeer(fd: fd.fileDescriptor, expected: parent, deadline: d)
                guard epochs.accept(epoch) else { throw AutomationError(code: .invalidRequest) }
                let raw = try await reader.receiveRegisteredDescriptor(timeout: try RegistrationFrame.descriptorTimeout(d))
                let generationChannel: AutomationChannel
                do { generationChannel = try AutomationChannel(adopting: raw); generationChannel.labelRegistration(.generationRunner) }
                catch { try? raw.close(); throw error }
                let ack = try RegistrationFrame.make("accepted", epoch)
                try await d.run(channel: channel) { try await channel.send(ack) }
                guard await generation(epoch, generationChannel) else { generationChannel.close(); throw AutomationError(code: .backendUnavailable) }
                generationChannel.close()
                let finish = try RegistrationFrame.deadline()
                try bridge.checkActualParent(parent, deadline: finish)
                try bridge.checkPeer(fd: fd.fileDescriptor, expected: parent, deadline: finish)
                let drained = try RegistrationFrame.make("drained", epoch)
                try await finish.run(channel: channel) { try await channel.send(drained) }
            }
            channel.close(); try? fd.close(); return true
        } catch {
            RootIdentityDiagnostic.emit("ROOT_DIAG side=runner stage=\(stage.rawValue) error=\(RootIdentityDiagnostic.classification(error))")
            channel.close(); try? inspector?.close(); return false
        }
    }
}
#endif
