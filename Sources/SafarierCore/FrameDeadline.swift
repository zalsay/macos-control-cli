import Foundation
// Copied from repository freeze 040 Transport.swift; no transport or control protocol.
enum HarnessError: Error { case identityNotReady, invalidClock, deadline, eof, invalidMode, environment }
struct FrameDeadline: Sendable {
    let lifetimeStart: UInt64, frameStart: UInt64
    private let controllerExpiry: UInt64?
    init(lifetimeStart: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= lifetimeStart, now - lifetimeStart < UInt64(AutomationLimits.generationSeconds * 1_000_000_000) else { throw HarnessError.deadline }
        self.lifetimeStart = lifetimeStart; frameStart = now; controllerExpiry = nil
    }
    // The seal is minted exclusively by the concrete controller owner in the server file.
    init(lifetimeStart: UInt64, controller: ControllerDeadlineSeal) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let (lifeEnd, overflow) = lifetimeStart.addingReportingOverflow(UInt64(AutomationLimits.generationSeconds * 1_000_000_000))
        guard !overflow, now >= lifetimeStart, now < lifeEnd, now < controller.cutoff else { throw HarnessError.deadline }
        self.lifetimeStart = lifetimeStart; frameStart = now
        controllerExpiry = min(lifeEnd, controller.cutoff)
    }
    func remaining() throws -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= frameStart, now >= lifetimeStart else { throw HarnessError.invalidClock }
        if let controllerExpiry {
            guard now < controllerExpiry else { throw HarnessError.deadline }
            return Double(controllerExpiry - now) / 1_000_000_000
        }
        let frame = now - frameStart, life = now - lifetimeStart
        guard frame < UInt64(AutomationLimits.frameSeconds * 1_000_000_000), life < UInt64(AutomationLimits.generationSeconds * 1_000_000_000) else { throw HarnessError.deadline }
        return Double(min(UInt64(AutomationLimits.frameSeconds * 1_000_000_000) - frame,UInt64(AutomationLimits.generationSeconds * 1_000_000_000) - life)) / 1_000_000_000
    }
    func cutoffNanoseconds() throws -> UInt64 {
        _ = try remaining()
        if let controllerExpiry { return controllerExpiry }
        let (frameEnd, frameOverflow) = frameStart.addingReportingOverflow(UInt64(AutomationLimits.frameSeconds * 1_000_000_000))
        let (lifeEnd, lifeOverflow) = lifetimeStart.addingReportingOverflow(UInt64(AutomationLimits.generationSeconds * 1_000_000_000))
        guard !frameOverflow, !lifeOverflow else { throw HarnessError.invalidClock }
        return min(frameEnd, lifeEnd)
    }
    func expiry() throws -> DispatchTime {
        return DispatchTime(uptimeNanoseconds: try cutoffNanoseconds())
    }
    func run<T: Sendable>(channel: AutomationChannel, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            let seconds = try remaining()
            let value = try await AutomationChannelDeadline.run(channel:channel,seconds:seconds,operation:operation)
            _ = try remaining(); try Task.checkCancellation(); return value
        } catch { channel.close(origin: AutomationChannel.failureCloseOrigin(error)); throw error }
    }
}
