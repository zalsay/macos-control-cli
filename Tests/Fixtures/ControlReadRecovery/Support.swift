import Foundation

// Only the channel and authenticated-context boundary are doubled. The fixture
// compiles the production client's complete request/send/receive implementation.
public struct ProcessExit: Sendable {}
public final class OwnedRunnerProcess: @unchecked Sendable {
    public let pid: Int32 = 1
    public let ownershipID = UUID()
    public var isRunning: Bool { true }
    public func waitForExit(timeoutSeconds: Double) async throws -> ProcessExit? { nil }
}
final class RunnerControlPeer: @unchecked Sendable {
    let child: OwnedRunnerProcess?
    init(child: OwnedRunnerProcess) { self.child = child }
    var isRunning: Bool { child?.isRunning == true }
}
final class AutomationChannel: @unchecked Sendable {
    enum ChannelError: Error { case closed, sendBackpressure }
    private let lock = NSLock()
    private var open = true
    private var writes = Set<UUID>()
    private let sendDelay: Duration
    init(sendDelay: Duration = .zero) { self.sendDelay = sendDelay }
    func close() { lock.lock(); open = false; lock.unlock() }
    func requireOpen(before: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard open else { throw ChannelError.closed }
    }
    func hasSent(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return writes.contains(id) }
    private func record(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard open else { throw ChannelError.closed }
        writes.insert(id)
    }
    func sendBound(_ admission: SealedWriteAdmission) async throws {
        try requireOpen(before: admission.cutoff)
        try record(admission.id)
        if sendDelay > .zero { try await Task.sleep(for: sendDelay) }
    }
}
final class FixtureBinding {
    let channel: AutomationChannel
    init(_ channel: AutomationChannel) { self.channel = channel }
    func checkCommit() throws { try channel.requireOpen(before: UInt64.max) }
}
final class SealedWriteAdmission {
    let binding: FixtureBinding, frame: Data, cutoff: UInt64
    let context: ControllerGenerationContext, id: UUID, generation: UUID
    init(context: ControllerGenerationContext, frame: Data, cutoff: UInt64, id: UUID, generation: UUID) {
        self.context = context; self.frame = frame; self.cutoff = cutoff; self.id = id; self.generation = generation
        binding = FixtureBinding(context.channel)
    }
    func isOwnedRequest(context: ControllerGenerationContext, id: UUID, generation: UUID) -> Bool {
        self.context === context && self.id == id && self.generation == generation
    }
    func finishDeadline() {}
}
final class ControllerGenerationContext: @unchecked Sendable {
    let registrationNonce: String?
    let channel: AutomationChannel
    let validationDelay: Duration
    init(channel: AutomationChannel, registered: Bool, validationDelay: Duration = .zero) {
        self.channel = channel; registrationNonce = registered ? String(repeating: "A", count: 43) : nil
        self.validationDelay = validationDelay
    }
    func mintOwnedRequest(client: AutomationRunnerClient, id: UUID, generation: UUID) async throws -> SealedWriteAdmission? {
        guard let (frame, cutoff) = await client.beginOwnedRequestMint(context: self, id: id, generation: generation) else { return nil }
        let admission = SealedWriteAdmission(context: self, frame: frame, cutoff: cutoff, id: id, generation: generation)
        try await client.installOwnedRequestAdmission(context: self, id: id, generation: generation, admission: admission)
        return admission
    }
    func armOwnedRequest(client: AutomationRunnerClient, id: UUID, generation: UUID, admission: SealedWriteAdmission) async throws {
        try await client.checkQueuedPending(context: self, id: id, generation: generation, admission: admission)
    }
    func validateInbound(client: AutomationRunnerClient, id: UUID, generation: UUID, reply: AutomationReply) async throws {
        let before = try await client.inboundPendingDeadline(context: self, id: id, generation: generation, reply: reply)
        if validationDelay > .zero { try await Task.sleep(for: validationDelay) }
        let after = try await client.inboundPendingDeadline(context: self, id: id, generation: generation, reply: reply)
        guard before == after else { throw AutomationChannel.ChannelError.closed }
    }
    func checkBackpressureHealth(_ admission: SealedWriteAdmission, id: UUID, generation: UUID) throws { try channel.requireOpen(before: admission.cutoff) }
    func stopFromClient(_ code: AutomationErrorCode) { channel.close() }
    func safeClose() async {}
}
