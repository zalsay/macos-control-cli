import Foundation

public struct AutomationHandshakeChallenge: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profileID: UUID
    public let nonce: String
    public init(profileID: UUID, nonce: String) { self.profileID = profileID; self.nonce = nonce }
    public var description: String { "AutomationHandshakeChallenge(redacted)" }
    public var debugDescription: String { description }
}
public struct AutomationHandshakeResponse: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profileID: UUID
    public let nonce: String
    public let runnerInstanceID: UUID
    public let runnerPID: Int32
    public init(profileID: UUID, nonce: String, runnerInstanceID: UUID, runnerPID: Int32) { self.profileID = profileID; self.nonce = nonce; self.runnerInstanceID = runnerInstanceID; self.runnerPID = runnerPID }
    public var description: String { "AutomationHandshakeResponse(redacted)" }
    public var debugDescription: String { description }
}
internal enum AutomationChannelDeadline {
    static func run<T: Sendable>(channel: AutomationChannel, seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds.isFinite, seconds > 0, seconds < Double(UInt64.max) / 1_000_000_000 else { channel.close(origin: .deadlineFailure); throw AutomationError(code: .invalidRequest) }
        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw AutomationError(code: .timeout) }
                do {
                    guard let result = try await group.next() else { throw AutomationError(code: .runnerExited) }
                    try Task.checkCancellation()
                    group.cancelAll()
                    return result
                } catch { channel.close(origin: AutomationChannel.failureCloseOrigin(error)); group.cancelAll(); throw error }
            }
        }, onCancel: { channel.close(origin: .cancellation) })
    }
}
public enum AutomationHandshakeCodec {
    private static func encode(_ d: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) }
    public static func makeChallenge(profileID: UUID, nonce: String) throws -> Data {
        guard AutomationSessionToken.isCanonical(nonce) else { throw AutomationError(code: .invalidRequest) }
        return try encode(["kind":"hello","version":1,"role":"manager","profileID":profileID.uuidString,"nonce":nonce])
    }
    public static func readChallenge(_ data: Data, expectedProfileID: UUID) throws -> AutomationHandshakeChallenge {
        do {
            let d = try AutomationJSONBoundary.object(data); try AutomationJSONBoundary.exact(d, ["kind","version","role","profileID","nonce"])
            guard AutomationJSONBoundary.integer(d["version"]) == 1, d["kind"] as? String == "hello", d["role"] as? String == "manager", let raw = d["profileID"] as? String, let id = UUID(uuidString: raw), id == expectedProfileID, let nonce = d["nonce"] as? String, AutomationSessionToken.isCanonical(nonce) else { throw AutomationError(code: .invalidRequest) }
            return AutomationHandshakeChallenge(profileID: id, nonce: nonce)
        } catch { throw AutomationError(code: .invalidRequest) }
    }
    public static func makeResponse(_ challenge: AutomationHandshakeChallenge, runnerInstanceID: UUID, runnerPID: Int32) throws -> Data {
        guard AutomationSessionToken.isCanonical(challenge.nonce), runnerPID > 0 else { throw AutomationError(code: .invalidRequest) }
        return try encode(["kind":"ready","version":1,"role":"runner","profileID":challenge.profileID.uuidString,"nonce":challenge.nonce,"runnerInstanceID":runnerInstanceID.uuidString,"runnerPID":runnerPID])
    }
    public static func readResponse(_ data: Data, expectedProfileID: UUID, expectedNonce: String, expectedPID: Int32) throws -> AutomationHandshakeResponse {
        do {
            let d = try AutomationJSONBoundary.object(data); try AutomationJSONBoundary.exact(d, ["kind","version","role","profileID","nonce","runnerInstanceID","runnerPID"])
            guard AutomationJSONBoundary.integer(d["version"]) == 1, d["kind"] as? String == "ready", d["role"] as? String == "runner", let raw = d["profileID"] as? String, let id = UUID(uuidString: raw), id == expectedProfileID, let nonce = d["nonce"] as? String, AutomationSessionToken.isCanonical(nonce), AutomationSessionToken.isCanonical(expectedNonce), nonce.utf8.elementsEqual(expectedNonce.utf8), let instanceString = d["runnerInstanceID"] as? String, let instance = UUID(uuidString: instanceString), let pid = AutomationJSONBoundary.integer(d["runnerPID"]), pid > 0, pid <= Int32.max, Int32(pid) == expectedPID else { throw AutomationError(code: .invalidRequest) }
            return AutomationHandshakeResponse(profileID: id, nonce: nonce, runnerInstanceID: instance, runnerPID: Int32(pid))
        } catch { throw AutomationError(code: .invalidRequest) }
    }
    public static func negotiate(channel: AutomationChannel, profileID: UUID, expectedPID: Int32, timeoutSeconds: Double = AutomationLimits.startupSeconds) async throws -> AutomationHandshakeResponse {
        do {
            guard expectedPID > 0 else { throw AutomationError(code: .invalidRequest) }
            let nonce = try AutomationSessionToken.generate()
            return try await AutomationChannelDeadline.run(channel: channel, seconds: timeoutSeconds) {
                try await channel.send(makeChallenge(profileID: profileID, nonce: nonce))
                guard let data = try await channel.receive() else { throw AutomationError(code: .runnerExited) }
                return try readResponse(data, expectedProfileID: profileID, expectedNonce: nonce, expectedPID: expectedPID)
            }
        } catch { channel.close(); throw error }
    }
}

extension AutomationHandshakeCodec {
    static func negotiateBound(context: ControllerGenerationContext, startupCutoff: UInt64) async throws -> AutomationHandshakeResponse {
        try await context.negotiateBound(startupCutoff: startupCutoff)
    }
}
