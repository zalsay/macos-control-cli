import Foundation
@main struct Main {
 static func main() {
  let url = URL(string: "https://example.com/")!
  func decision(_ code: Int, provisional: Bool = true, safe: Bool = true, retries: Int = 0, remaining: Double = 10, cancelled: Bool = false) -> Double? {
   NavigationRetryPolicy.delay(error: NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: url]), url: url, provisional: provisional, knownGET: safe, retries: retries, remaining: remaining, cancelled: cancelled)
  }
  precondition(decision(NSURLErrorTimedOut) == 0.5)
  precondition(decision(NSURLErrorNetworkConnectionLost, retries: 1) == 1)
  precondition(decision(NSURLErrorTimedOut, retries: 2) == nil)
  precondition(decision(NSURLErrorTimedOut, remaining: 0.5) == nil)
  precondition(decision(NSURLErrorTimedOut, remaining: .infinity) == nil)
  precondition(decision(NSURLErrorTimedOut, remaining: .nan) == nil)
  precondition(decision(NSURLErrorTimedOut, cancelled: true) == nil)
  precondition(decision(NSURLErrorTimedOut, provisional: false) == nil)
  precondition(decision(NSURLErrorTimedOut, safe: false) == nil)
  precondition(decision(NSURLErrorCancelled) == nil)
  precondition(decision(NSURLErrorUserAuthenticationRequired) == nil)
  precondition(decision(NSURLErrorServerCertificateUntrusted) == nil)
  precondition(NavigationRetryPolicy.delay(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: url, provisional: true, knownGET: true, retries: 0, remaining: 10, cancelled: false) == nil)
  var c = NavigationCorrelation(); let a = NSObject(), b = NSObject(); let e = c.begin(a)
  let next = c.replaceFailedProvisional(a, with: b, epoch: e)!
  precondition(c.isRetired(a) && !c.matches(a, epoch: e) && c.matches(b, epoch: next))
  precondition(!c.noteCommitted(a, epoch: e))
  precondition(c.noteCommitted(b, epoch: next))
  precondition(c.replaceFailedProvisional(b, with: NSObject(), epoch: next) == nil)
  // Exercise policy and correlation together over a single simulated budget.
  func attempts(budget: Double, cancelAfterFirst: Bool = false, commitFirst: Bool = false) -> Int {
   var clock = 0.0, retries = 0, count = 1
   var correlation = NavigationCorrelation(); var current = NSObject()
   var epoch = correlation.begin(current)
   if commitFirst { precondition(correlation.noteCommitted(current, epoch: epoch)) }
   while let delay = decision(NSURLErrorTimedOut, retries: retries, remaining: budget - clock,
                              cancelled: cancelAfterFirst) {
    guard correlation.canReplaceFailedProvisional(current, epoch: epoch) else { break }
    clock += delay
    let old = current, oldEpoch = epoch, child = NSObject()
    epoch = correlation.replaceFailedProvisional(old, with: child, epoch: oldEpoch)!
    current = child; retries += 1; count += 1
    precondition(correlation.isRetired(old) && !correlation.noteFinished(old, epoch: oldEpoch))
   }
   return count
  }
  precondition(attempts(budget: 60) == 3)
  precondition(attempts(budget: 1.5) == 2)
  precondition(attempts(budget: 60, cancelAfterFirst: true) == 1)
  precondition(attempts(budget: 60, commitFirst: true) == 1)
  var state = ControllerNavigationRetryState()
  let root = NSObject(), childNav = NSObject(), other = NSObject()
  precondition(state.begin(root, url: url, now: 0, budget: 60))
  let expiry = state.expiryTicket!
  precondition(!state.isExpired(expiry, now: 59.99))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
  let ticket = state.failed(root, error: error, provisional: true, now: 1)!
  precondition(ticket.delay == 0.5 && ticket.attempt == 2)
  precondition(!state.mayDispatch(ticket, now: 1.49))
  precondition(state.mayDispatch(ticket, now: 1.5))
  precondition(state.adopt(childNav, ticket: ticket, now: 1.5))
  precondition(state.isRetired(root) && state.failed(root, error: error, provisional: true, now: 2) == nil)
  precondition(state.isExpired(expiry, now: 60) && state.matchesActive(expiry, navigation: childNav))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  let ticket2 = state.failed(childNav, error: error, provisional: true, now: 2)!
  state.cancel()
  precondition(!state.mayDispatch(ticket2, now: 3) && state.isRetired(childNav))
  precondition(!state.isExpired(expiry, now: 61))
  precondition(state.begin(other, url: url, now: 5, budget: 1))
  precondition(!state.isExpired(expiry, now: 61))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  precondition(state.failed(other, error: error, provisional: true, now: 5.5) == nil)
  let fresh = NSObject(); precondition(state.begin(fresh, url: url, now: 0, budget: 60))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  let pending = state.failed(fresh, error: error, provisional: true, now: 1)!
  state.observeAction(url: url, mainFrame: true, get: true, explicit: false)
  precondition(!state.mayDispatch(pending, now: 2) && state.isRetired(fresh))
  let p = NSObject(), q = NSObject(), r = NSObject()
  precondition(state.begin(p, url: url, now: 0, budget: 60))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  let first = state.failed(p, error: error, provisional: true, now: 1)!
  precondition(state.adopt(q, ticket: first, now: 1.5))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  let second = state.failed(q, error: error, provisional: true, now: 2)!
  precondition(state.adopt(r, ticket: second, now: 3))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  precondition(state.failed(r, error: error, provisional: true, now: 4) == nil)
  let redirected = NSObject(); precondition(state.begin(redirected, url: url, now: 0, budget: 60))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  state.disallowRetry(redirected)
  precondition(state.failed(redirected, error: error, provisional: true, now: 1) == nil)
  let redirectOriginal = NSObject(), replacement = NSObject()
  precondition(state.begin(redirectOriginal, url: url, now: 0, budget: 60))
  let redirectExpiry = state.expiryTicket!
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  state.observeAction(url: URL(string: "https://example.com/redirect")!, mainFrame: true, get: true, explicit: false)
  precondition(state.matches(redirectOriginal) && !state.isRetired(redirectOriginal), "redirect must retain current navigation")
  precondition(state.matchesActive(redirectExpiry, navigation: redirectOriginal) && state.isExpired(redirectExpiry, now: 60))
  let atsError = NSError(domain: NSURLErrorDomain, code: -1022, userInfo: [NSURLErrorFailingURLErrorKey: url])
  precondition(state.failed(redirectOriginal, error: atsError, provisional: true, now: 2) == nil)
  precondition(state.failed(redirectOriginal, error: error, provisional: true, now: 2) == nil)
  state.cancel() // didStart mismatch on an actual replacement retires the prior navigation.
  precondition(state.isRetired(redirectOriginal) && !state.matches(redirectOriginal))
  precondition(state.begin(replacement, url: url, now: 3, budget: 60))
  precondition(state.matches(replacement) && !state.isRetired(replacement))
  let stopped = NSObject(); precondition(state.begin(stopped, url: url, now: 0, budget: 60))
  state.observeAction(url: url, mainFrame: true, get: true, explicit: true)
  let stoppedTicket = state.failed(stopped, error: error, provisional: true, now: 1)!
  state.cancel() // The same cancel operation used by stop and delegate handoff.
  precondition(!state.mayDispatch(stoppedTicket, now: 2) && state.isRetired(stopped))
  print("navigation retry: PASS")
 }
}
