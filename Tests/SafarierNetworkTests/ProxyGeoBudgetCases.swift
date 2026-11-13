import Foundation
import SafarierCore
import SafarierNetwork

enum ProxyGeoBudgetCases {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double
        init(_ value: Double = 0) { self.value = value }
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
    }
    final class ClockSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]
        private var last: Double
        init(_ values: [Double]) { self.values = values; self.last = values.last! }
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return values.isEmpty ? last : values.removeFirst() }
    }
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, Double)] = []
        func append(_ url: String, _ timeout: Double) { lock.lock(); defer { lock.unlock() }; values.append((url, timeout)) }
        func get() -> [(String, Double)] { lock.lock(); defer { lock.unlock() }; return values }
    }
    struct Failure: Error { let message: String }
    static func waitForEntry(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }; count += 1
        }
        func error(_ expected: ProxyGeoResolutionError, _ operation: () throws -> ProxyGeoResult?) throws {
            do { _ = try operation(); throw Failure(message: "expected \(expected)") }
            catch let actual as ProxyGeoResolutionError { try check(actual == expected, "expected \(expected), got \(actual)") }
        }
        let proxy = ProxySettings(name: "US proxy", kind: .httpConnect, host: "invalid", port: 1)
        let clock = Clock(10), calls = Calls()
        let resolved = try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, timeout: 4, deadline: 15, now: { clock.now() }, fetch: { url, _, _, timeout in
            calls.append(url, timeout)
            if calls.get().count == 1 { clock.set(13); return nil }
            return "{\"country_code\":\"JP\",\"timezone\":\"Asia/Tokyo\"}"
        })
        let seen = calls.get()
        try check(seen.count == 2, "second endpoint succeeds")
        try check(seen.map(\.0) == Array(ProxyGeoResolver.endpoints.prefix(2)).map(\.url), "endpoint order")
        try check(seen.map(\.1) == [4, 2], "remaining budget decreases")
        try check(resolved?.countryCode == "JP" && resolved?.source == .lookup(ProxyGeoResolver.endpoints[1].url), "parsed result")

        for lateBody: String? in ["{\"country_code\":\"US\"}", nil] {
            let c = Clock(1), n = Calls()
            try error(.timeout) { try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "Japan", deadline: 2, now: { c.now() }, fetch: { url, _, _, timeout in n.append(url, timeout); c.set(2); return lateBody }) }
            try check(n.get().count == 1, "late result stops requests and hint")
        }
        for bad in [-1.0, Double.nan, Double.infinity] {
            let n = Calls()
            try error(.invalidBudget) { try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, timeout: bad, deadline: 5, now: { 0 }, fetch: { url, _, _, timeout in n.append(url, timeout); return nil }) }
            try check(n.get().isEmpty, "invalid timeout before fetch")
        }
        for bad in [-1.0, Double.nan, Double.infinity] {
            try error(.invalidBudget) { try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, deadline: bad, now: { 0 }, fetch: { _, _, _, _ in nil }) }
        }
        try error(.invalidBudget) { try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, timeout: 0, deadline: 5, now: { 0 }, fetch: { _, _, _, _ in nil }) }
        for bad in [-1.0, Double.nan, Double.infinity] {
            try error(.invalidClock) { try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, deadline: 5, now: { bad }, fetch: { _, _, _, _ in nil }) }
        }
        for bad in [Double.nan, 0.5] {
            let c = Clock(1)
            try error(.invalidClock) { try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "US", deadline: 5, now: { c.now() }, fetch: { _, _, _, _ in c.set(bad); return nil }) }
        }
        let parsedLate = ClockSequence([1, 1, 1, 2])
        try error(.timeout) { try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "Japan", deadline: 2, now: { parsedLate.now() }, fetch: { _, _, _, _ in "{\"country_code\":\"US\"}" }) }
        let hintLate = ClockSequence([1, 1, 2])
        try error(.timeout) { try ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: "Japan", deadline: 2, now: { hintLate.now() }, fetch: { _, _, _, _ in nil }) }
        let beforeHint = ClockSequence([1, 2])
        try error(.timeout) { try ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: "Japan", deadline: 2, now: { beforeHint.now() }, fetch: { _, _, _, _ in nil }) }
        let noResult = try ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: nil, deadline: 5, now: { 1 }, fetch: { _, _, _, _ in nil })
        try check(noResult == nil, "no proxy or hint returns nil")
        let shortBudgetCalls = Calls()
        let noHintProxy = ProxySettings(name: "proxy", kind: .httpConnect, host: "invalid", port: 1)
        let allFailed = try ProxyGeoResolver.resolve(proxy: noHintProxy, password: nil, nodeHint: nil, timeout: 4, deadline: 1.5, now: { 1 }, fetch: { url, _, _, timeout in shortBudgetCalls.append(url, timeout); return nil })
        try check(allFailed == nil, "all failed lookups and no hint returns nil")
        try check(shortBudgetCalls.get().count == 3 && shortBudgetCalls.get().allSatisfy { $0.1 == 0.5 }, "subsecond remaining budget is not rounded up")
        let noProxyCalls = Calls()
        let hint = try ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: "Japan", deadline: 10, now: { 1 }, fetch: { url, _, _, timeout in noProxyCalls.append(url, timeout); return nil })
        try check(hint?.countryCode == "JP" && hint?.source == .nameHint, "no proxy hint")
        try check(noProxyCalls.get().isEmpty, "no proxy means no fetch")
        try error(.timeout) { try ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: "Japan", deadline: 1, now: { 1 }, fetch: { _, _, _, _ in nil }) }
        let oldCalls = Calls()
        let old = ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "Japan", timeout: 7, fetch: { url, _, _, timeout in oldCalls.append(url, timeout); return nil })
        try check(old?.countryCode == "JP" && old?.source == .nameHint, "legacy hint")
        try check(oldCalls.get().map(\.0) == ProxyGeoResolver.endpoints.map(\.url), "legacy endpoint order")
        try check(oldCalls.get().map(\.1) == [7, 7, 7], "legacy per-request timeout")
        let legacySuccessCalls = Calls()
        let legacySuccess = ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "Japan", timeout: 7, fetch: { url, _, _, timeout in legacySuccessCalls.append(url, timeout); return "{\"country_code\":\"US\"}" })
        try check(legacySuccess?.countryCode == "US" && legacySuccess?.source == .lookup(ProxyGeoResolver.endpoints[0].url), "legacy lookup")
        try check(legacySuccessCalls.get().count == 1, "legacy stops at first valid lookup")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let duringFetch = Task.detached { () -> ProxyGeoResolutionError? in
            do {
                _ = try ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "Japan", deadline: 10, now: { 1 }, fetch: { _, _, _, _ in entered.signal(); release.wait(); return "{\"country_code\":\"US\"}" })
                return nil
            } catch { return error as? ProxyGeoResolutionError }
        }
        let didEnter = await Task.detached { waitForEntry(entered) }.value
        guard didEnter else { release.signal(); throw Failure(message: "fetch did not start") }
        duringFetch.cancel()
        release.signal()
        let duringFetchResult = await duringFetch.value
        try check(duringFetchResult == .cancelled, "cancellation after fetch rejects success")
        let cancelled = Task { () -> ProxyGeoResolutionError? in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: "Japan", deadline: 10, now: { 1 }, fetch: { _, _, _, _ in nil }); return nil }
            catch { return error as? ProxyGeoResolutionError }
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        try check(cancelledResult == .cancelled, "task cancellation")
        return count
    }
}
