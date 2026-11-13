import Foundation

/// Correlates delegate callbacks with one exact navigation and generation.
struct NavigationCorrelation {
    private enum PendingKind { case finished, provisional }
    private struct Pending {
        let ticket: UUID
        let kind: PendingKind
    }
    private var epoch: UInt64 = 0
    private var current: AnyObject?
    private var finished = false
    private var committed = false
    private var pending: Pending?
    private var retired: [AnyObject] = []
    private var continuationCount = 0

    mutating func begin(_ navigation: AnyObject) -> UInt64 {
        epoch &+= 1
        current = navigation
        finished = false
        committed = false
        pending = nil
        retired.removeAll()
        continuationCount = 0
        return epoch
    }

    func matches(_ navigation: AnyObject, epoch: UInt64) -> Bool {
        self.epoch == epoch && current === navigation
    }

    mutating func noteFinished(_ navigation: AnyObject, epoch: UInt64) -> Bool {
        guard matches(navigation, epoch: epoch), pending == nil else { return false }
        finished = true
        committed = true
        return true
    }

    mutating func noteCommitted(_ navigation: AnyObject, epoch: UInt64) -> Bool {
        guard matches(navigation, epoch: epoch), pending == nil else { return false }
        committed = true
        return true
    }

    func isUncommittedContinuation(_ navigation: AnyObject, epoch: UInt64) -> Bool {
        matches(navigation, epoch: epoch) && !committed && !retired.isEmpty
    }

    var hasPendingContinuation: Bool { pending != nil }

    mutating func reserveContinuation(parent: AnyObject, epoch: UInt64) -> UUID? {
        guard matches(parent, epoch: epoch), finished, pending == nil,
              continuationCount < 8 else { return nil }
        let ticket = UUID()
        pending = Pending(ticket: ticket, kind: .finished)
        continuationCount += 1
        return ticket
    }

    mutating func reserveProvisionalContinuation(parent: AnyObject, epoch: UInt64) -> UUID? {
        guard isUncommittedContinuation(parent, epoch: epoch), !finished, pending == nil,
              continuationCount < 8 else { return nil }
        let ticket = UUID()
        pending = Pending(ticket: ticket, kind: .provisional)
        continuationCount += 1
        return ticket
    }

    mutating func confirmProvisionalContinuation(ticket: UUID, parent: AnyObject, epoch: UInt64) -> Bool {
        guard isUncommittedContinuation(parent, epoch: epoch), !finished,
              let pending, pending.kind == .provisional, pending.ticket == ticket else { return false }
        self.pending = nil
        return true
    }

    mutating func adoptContinuation(_ child: AnyObject, ticket: UUID, parent: AnyObject, epoch: UInt64) -> UInt64? {
        guard matches(parent, epoch: epoch), let pending, pending.ticket == ticket,
              child !== parent, !isRetired(child), self.epoch < UInt64.max else { return nil }
        switch pending.kind {
        case .finished: guard finished else { return nil }
        case .provisional:
            guard isUncommittedContinuation(parent, epoch: epoch), !finished else { return nil }
        }
        retired.append(parent)
        self.epoch += 1
        current = child
        finished = false
        committed = false
        self.pending = nil
        return self.epoch
    }

    func canReplaceFailedProvisional(_ parent: AnyObject, epoch: UInt64) -> Bool {
        matches(parent, epoch: epoch) && !committed && !finished && pending == nil && self.epoch < UInt64.max
    }

    mutating func replaceFailedProvisional(_ parent: AnyObject, with child: AnyObject, epoch: UInt64) -> UInt64? {
        guard canReplaceFailedProvisional(parent, epoch: epoch),
              child !== parent, !isRetired(child) else { return nil }
        retired.append(parent)
        self.epoch += 1
        current = child
        return self.epoch
    }

    func isRetired(_ navigation: AnyObject) -> Bool {
        retired.contains { $0 === navigation }
    }

    mutating func finish(_ navigation: AnyObject, epoch: UInt64) -> Bool {
        guard matches(navigation, epoch: epoch), pending == nil else { return false }
        current = nil
        finished = false
        committed = false
        return true
    }

    mutating func invalidate() {
        epoch &+= 1
        current = nil
        finished = false
        committed = false
        pending = nil
        retired.removeAll()
        continuationCount = 0
    }
}

/// A retry requires positive evidence of the original main-frame GET and its failing URL.
enum NavigationRetryPolicy {
    static func delay(error: Error, url: URL, provisional: Bool, knownGET: Bool,
                      retries: Int, remaining: Double, cancelled: Bool) -> Double? {
        let failure = error as NSError
        guard provisional, knownGET, !cancelled, remaining.isFinite, (0..<2).contains(retries),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              failure.domain == NSURLErrorDomain,
              (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL) == url else { return nil }
        let transient = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                         NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet]
        guard transient.contains(failure.code) else { return nil }
        let delay = retries == 0 ? 0.5 : 1.0
        return remaining > delay ? delay : nil
    }
}

/// Controller-owned lifecycle for one explicit main-frame GET and its retries.
struct ControllerNavigationRetryState {
    struct ExpiryTicket: Equatable {
        fileprivate let id: UUID
        fileprivate let deadline: Double
    }
    struct Ticket: Equatable {
        fileprivate let id: UUID
        let delay: Double
        let attempt: Int
        fileprivate let readyAt: Double
    }
    private final class WeakNavigation {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
    private var current: AnyObject?
    private var retired: [WeakNavigation] = []
    private var url: URL?
    private var deadline = 0.0
    private var retries = 0
    private var awaitingAction = false
    private var knownGET = false
    private var pending: Ticket?
    private var retryAllowed = false
    private(set) var expiryTicket: ExpiryTicket?

    mutating func begin(_ navigation: AnyObject, url: URL, now: Double, budget: Double) -> Bool {
        cancel()
        retired.removeAll { $0.value == nil }
        guard retired.count < 256, now.isFinite, budget.isFinite, (now + budget).isFinite, budget > 0,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        current = navigation; self.url = url; deadline = now + budget
        expiryTicket = ExpiryTicket(id: UUID(), deadline: deadline)
        retries = 0; awaitingAction = true; knownGET = false; retryAllowed = true
        return true
    }
    mutating func cancel() {
        if let current { retired.append(WeakNavigation(current)) }
        current = nil; pending = nil; url = nil; knownGET = false; retryAllowed = false; awaitingAction = false; expiryTicket = nil
    }
    func isRetired(_ navigation: AnyObject) -> Bool { retired.contains { $0.value === navigation } }
    func matches(_ navigation: AnyObject) -> Bool { current === navigation }
    var isActive: Bool { current != nil }
    var activeNavigation: AnyObject? { current }
    func matchesActive(_ ticket: ExpiryTicket, navigation: AnyObject) -> Bool {
        expiryTicket == ticket && current === navigation
    }
    func remaining(_ ticket: ExpiryTicket, now: Double) -> Double? {
        guard expiryTicket == ticket, current != nil, now.isFinite else { return nil }
        return max(0, ticket.deadline - now)
    }
    func isExpired(_ ticket: ExpiryTicket, now: Double) -> Bool {
        remaining(ticket, now: now) == 0
    }
    mutating func disallowCurrentRetry() { retryAllowed = false; knownGET = false; pending = nil }
    mutating func observeAction(url: URL?, mainFrame: Bool, get: Bool, explicit: Bool) {
        guard mainFrame, current != nil else { return }
        if !awaitingAction && pending == nil { disallowCurrentRetry(); return }
        guard awaitingAction, pending == nil, explicit, get, url == self.url else { cancel(); return }
        awaitingAction = false; knownGET = true
    }
    mutating func disallowRetry(_ navigation: AnyObject) {
        guard matches(navigation) else { return }
        retryAllowed = false; knownGET = false; pending = nil
    }
    mutating func failed(_ navigation: AnyObject, error: Error, provisional: Bool, now: Double) -> Ticket? {
        guard matches(navigation), pending == nil, now.isFinite, let url,
              let delay = NavigationRetryPolicy.delay(error: error, url: url, provisional: provisional,
                 knownGET: knownGET && retryAllowed && !awaitingAction, retries: retries,
                 remaining: deadline - now, cancelled: false) else { return nil }
        let ticket = Ticket(id: UUID(), delay: delay, attempt: retries + 2, readyAt: now + delay)
        pending = ticket
        return ticket
    }
    var originalURL: URL? { url }
    func isPending(_ ticket: Ticket) -> Bool { pending == ticket }
    func mayDispatch(_ ticket: Ticket, now: Double) -> Bool {
        pending == ticket && current != nil && retryAllowed && now.isFinite && now >= ticket.readyAt && now < deadline
    }
    mutating func adopt(_ child: AnyObject, ticket: Ticket, now: Double) -> Bool {
        guard mayDispatch(ticket, now: now), let current, child !== current, !isRetired(child), retired.count < 256 else { return false }
        retired.append(WeakNavigation(current)); self.current = child; pending = nil
        retries += 1; awaitingAction = true; knownGET = false
        return true
    }
}
