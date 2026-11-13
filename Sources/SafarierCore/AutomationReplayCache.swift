import Foundation

/// One authenticated caller/session scope. Caller must serialize access. Time is a
/// monotonic seconds value supplied by the owner, never a wall-clock timestamp.
public struct AutomationReplayCache: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "AutomationReplayCache(redacted)" }
    public var debugDescription: String { description }
    public enum Begin: Equatable, Sendable {
        case reserved, inFlight, replay(AutomationReply), rejected(AutomationErrorCode)
    }
    private struct Entry {
        let request: AutomationRequest
        var reply: AutomationReply?
    }
    private var entries: [UUID: Entry] = [:]
    private var deadline: Double
    private var lastTime: Double
    private var expired: Bool
    public init(startedAt: Double) {
        self.deadline = startedAt + AutomationLimits.idleSeconds
        self.lastTime = startedAt
        self.expired = !startedAt.isFinite || !deadline.isFinite
    }
    private mutating func valid(_ now: Double) -> Bool {
        guard !expired, now.isFinite, now >= lastTime, now < deadline else { expired = true; return false }
        lastTime = now
        return true
    }
    /// Renew only after the owner has authenticated a valid session operation.
    public mutating func renew(at now: Double) -> Bool {
        guard valid(now), (now + AutomationLimits.idleSeconds).isFinite else { expired = true; return false }
        deadline = now + AutomationLimits.idleSeconds
        return true
    }
    // Replay identity follows decoded wire values, but page text and URL bytes
    // must not inherit Swift String's canonical Unicode equivalence.
    private static func matches(_ lhs: AutomationRequest, _ rhs: AutomationRequest) -> Bool {
        guard lhs.version == rhs.version, lhs.requestID == rhs.requestID, lhs.sessionID == rhs.sessionID else { return false }
        switch (lhs.action, rhs.action) {
        case let (.insertText(a), .insertText(b)):
            return a.utf8.elementsEqual(b.utf8)
        case let (.navigate(a), .navigate(b)):
            return a.absoluteString.utf8.elementsEqual(b.absoluteString.utf8)
        default:
            return lhs.action == rhs.action
        }
    }
    public mutating func begin(_ request: AutomationRequest, at now: Double) -> Begin {
        guard valid(now) else { return .rejected(.sessionExpired) }
        if let entry = entries[request.requestID] {
            guard Self.matches(entry.request, request) else { return .rejected(.requestIDReused) }
            return entry.reply.map(Begin.replay) ?? .inFlight
        }
        guard entries.count < AutomationLimits.replayEntries else { return .rejected(.replayWindowFull) }
        entries[request.requestID] = Entry(request: request, reply: nil)
        return .reserved
    }
    @discardableResult public mutating func complete(_ request: AutomationRequest, reply: AutomationReply, at now: Double) -> Bool {
        guard valid(now), reply.requestID == request.requestID, var entry = entries[request.requestID], Self.matches(entry.request, request), entry.reply == nil else { return false }
        entry.reply = reply
        entries[request.requestID] = entry
        return true
    }
}
