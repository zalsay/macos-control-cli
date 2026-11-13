import Foundation
@testable import SafarierCore

public enum AutomationProtocolCases {
    public static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            checks += 1
            if !condition() { throw CaseFailure(label) }
        }
        func decode(_ text: String) throws -> AutomationRequest { try AutomationCodec.decode(Data(text.utf8)) }
        func rejects(_ text: String) -> Bool { (try? decode(text)) == nil }
        let id = "00000000-0000-4000-8000-000000000001"
        let profile = "00000000-0000-4000-8000-000000000003"
        let token = String(repeating: "A", count: 43)
        func request(_ action: String, _ params: String, session: String? = nil) -> String {
            let field = session.map { ",\"sessionID\":\"\($0)\"" } ?? ""
            return "{\"version\":1,\"requestID\":\"\(id)\",\"action\":\"\(action)\",\"parameters\":\(params)\(field)}"
        }
        try check((try? decode(request("releaseControl", "{}", session: token))) != nil, "release request")
        try check((try? decode(request("commitControlRelease", "{\"transferID\":\"\(id)\"}", session: token))) != nil, "commit request")
        try check(rejects(request("commitControlRelease", "{\"transferID\":\"bad\"}", session: token)), "invalid transfer ID")
        let target = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let preparation = ControlReleasePreparation(target: target, transferID: UUID(), inputReleased: true, artifactsCleaned: true, browserRetained: true)
        let releaseReply = AutomationReply(requestID: UUID(), outcome: .success(.controlReleasePrepared(preparation)))
        let encodedRelease = try AutomationCodec.encode(releaseReply)
        try check((try? AutomationCodec.decodeReply(encodedRelease)) == releaseReply, "release proof roundtrip")
        var releaseJSON = try JSONSerialization.jsonObject(with: encodedRelease) as! [String: Any]
        var releaseResult = releaseJSON["result"] as! [String: Any]
        releaseResult["inputReleased"] = 1; releaseJSON["result"] = releaseResult
        try check((try? AutomationCodec.decodeReply(JSONSerialization.data(withJSONObject: releaseJSON))) == nil, "release boolean strict")
        releaseResult["inputReleased"] = true
        var releaseTarget = releaseResult["target"] as! [String: Any]; releaseTarget["extra"] = true
        releaseResult["target"] = releaseTarget; releaseJSON["result"] = releaseResult
        try check((try? AutomationCodec.decodeReply(JSONSerialization.data(withJSONObject: releaseJSON))) == nil, "release target strict")
        let open = try decode(request("openSession", "{\"profileID\":\"\(profile)\"}"))
        try check(open.action == .openSession(profileID: UUID(uuidString: profile)!), "typed open")
        let capabilities = try decode(request("capabilities", "{}"))
        try check(capabilities.action == .capabilities, "capabilities")
        for action in ["getState", "screenshot", "cancel", "closeSession"] {
            try check((try? decode(request(action, "{}", session: token))) != nil, "empty action \(action)")
            try check(rejects(request(action, "{}")), "session required \(action)")
        }
        let point = "{\"x\":1,\"y\":2,\"viewVersion\":18446744073709551615}"
        for action in ["move", "mouseDown", "mouseUp"] { try check((try? decode(request(action, point, session: token))) != nil, "point \(action)") }
        try check((try? decode(request("click", "{\"x\":1,\"y\":2,\"viewVersion\":1,\"count\":2}", session: token))) != nil, "click")
        try check(rejects(request("click", "{\"x\":1,\"y\":2,\"viewVersion\":1,\"count\":3}", session: token)), "click count")
        try check((try? decode(request("scroll", "{\"x\":1,\"y\":2,\"viewVersion\":1,\"deltaX\":-1000,\"deltaY\":1000}", session: token))) != nil, "scroll")
        try check(rejects(request("scroll", "{\"x\":1,\"y\":2,\"viewVersion\":1,\"deltaX\":1001,\"deltaY\":0}", session: token)), "scroll limit")
        try check((try? decode(request("navigate", "{\"url\":\"https://example.com/a\"}", session: token))) != nil, "url")
        let nativeEnter = try decode(request("navigateByInput", "{\"input\":\"Enter\",\"viewVersion\":1}", session: token))
        let nativeClick = try decode(request("navigateByInput", "{\"input\":\"click\",\"x\":1,\"y\":2,\"viewVersion\":1}", session: token))
        try check(nativeEnter.action == .navigateByInput(input: .enter, viewVersion: 1), "native navigation enter")
        try check(nativeClick.action == .navigateByInput(input: .click(point: ViewportPoint(x: 1, y: 2)), viewVersion: 1), "native navigation click")
        try check((try? AutomationCodec.decode(AutomationCodec.encodeRequest(nativeEnter))) == nativeEnter && (try? AutomationCodec.decode(AutomationCodec.encodeRequest(nativeClick))) == nativeClick, "native navigation roundtrip")
        for bad in ["{\"input\":\"Enter\",\"viewVersion\":1,\"url\":\"https://example.com\"}", "{\"input\":\"Enter\",\"viewVersion\":1,\"shift\":false}", "{\"input\":\"click\",\"x\":1,\"y\":2,\"viewVersion\":1,\"count\":2}", "{\"input\":\"click\",\"x\":1e999,\"y\":2,\"viewVersion\":1}", "{\"input\":\"other\",\"viewVersion\":1}"] {
            try check(rejects(request("navigateByInput", bad, session: token)), "native navigation strict fields")
        }
        try check(nativeEnter.action.isNavigation && nativeClick.action.isNavigation && !AutomationAction.getState.isNavigation, "navigation classification")
        try check(rejects(request("navigate", "{\"url\":\"http:///path\"}", session: token)), "host")
        try check(rejects(request("navigate", "{\"url\":\"file:///tmp/x\"}", session: token)), "scheme")
        try check((try? decode(request("insertText", "{\"text\":\"hello\"}", session: token))) != nil, "text")
        try check(rejects(request("insertText", "{\"text\":\"\(String(repeating: "a", count: 16385))\"}", session: token)), "text limit")
        try check((try? decode(request("key", "{\"name\":\"Left\",\"shift\":true}", session: token))) != nil, "key")
        try check(rejects(request("key", "{\"name\":\"Command\",\"shift\":false}", session: token)), "key whitelist")
        try check(rejects(request("evaluateJavaScript", "{}")), "unknown action")
        try check(rejects(request("capabilities", "{}", session: token)), "token prohibited")
        try check(rejects(request("getState", "{}", session: String(repeating: "B", count: 43))), "noncanonical token")
        try check(rejects(request("capabilities", "{\"bad\":true}")), "unknown nested key")
        try check(rejects(request("capabilities", "{\"x\":1,\"x\":2}")), "duplicate nested")
        try check(rejects("{\"version\":1,\"vers\\u0069on\":1,\"requestID\":\"\(id)\",\"action\":\"capabilities\",\"parameters\":{}}"), "escaped duplicate")
        try check(rejects(request("move", "{\"x\":true,\"y\":2,\"viewVersion\":1}", session: token)), "boolean not number")
        try check(rejects(request("capabilities", "{}").replacingOccurrences(of: "\"version\":1", with: "\"version\":2")), "version")
        let legacy = Data("{\"id\":\"\(profile)\",\"name\":\"test\",\"mode\":\"persistent\",\"createdAt\":0}".utf8)
        var p = try JSONDecoder().decode(Profile.self, from: legacy)
        try check(!p.allowsBackgroundAutomation, "legacy opt-in")
        p.allowsBackgroundAutomation = true
        let roundtrip = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        try check(roundtrip.allowsBackgroundAutomation, "profile roundtrip")
        try check(!p.duplicated(name: "copy").allowsBackgroundAutomation, "duplicate revoke")
        let generated = try AutomationSessionToken.generate()
        try check(AutomationSessionToken.isCanonical(generated), "random token format")
        try check(!AutomationSessionToken.isCanonical(generated + "="), "token padding")
        try check(rejects(request("navigate", "{\"url\":\"https://%20\"}", session: token)), "invalid host whitespace")
        try check(rejects(request("key", "{\"name\":\"Enter\",\"shift\":true}", session: token)), "shift whitelist")
        try check(rejects(request("move", "{\"x\":1e999,\"y\":2,\"viewVersion\":1}", session: token)), "infinite coordinate")
        try check(rejects(request("move", "{\"x\":1,\"y\":2,\"viewVersion\":-1}", session: token)), "negative view version")
        try check(rejects(request("capabilities", "{}").replacingOccurrences(of: "\"version\":1", with: "\"version\":true")), "boolean version")
        try check((try? AutomationCodec.decode(Data([0xff]))) == nil, "invalid utf8")
        try check((try? AutomationCodec.decode(Data(repeating: 32, count: 65537))) == nil, "frame limit")
        try check(rejects(request("capabilities", String(repeating: "[", count: 35) + String(repeating: "]", count: 35))), "depth limit")
        let text = try decode(request("insertText", "{\"text\":\"SECRET_INPUT\"}", session: token))
        try check(!String(reflecting: text).contains("SECRET_INPUT") && !String(reflecting: text).contains(token), "request redaction")
        try check(!String(reflecting: text.action).contains("SECRET_INPUT"), "action redaction")
        let errorReply = AutomationReply(requestID: nil, outcome: .failure(AutomationError(code: .invalidRequest)))
        let errorJSON = try JSONSerialization.jsonObject(with: AutomationCodec.encode(errorReply)) as! [String: Any]
        try check(errorJSON["requestID"] is NSNull && errorJSON["effect"] == nil && errorJSON["result"] == nil && errorJSON["status"] as? String == "error", "error wire shape")
        let uncorrelatedSuccess = AutomationReply(requestID: nil, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        try check((try? AutomationCodec.encode(uncorrelatedSuccess)) == nil, "success requires requestID")
        let okReply = AutomationReply(requestID: open.requestID, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 7)))
        let okJSON = try JSONSerialization.jsonObject(with: AutomationCodec.encode(okReply)) as! [String: Any]
        try check(okJSON["effect"] as? String == "nativeDelivered" && okJSON["error"] == nil && okJSON["result"] != nil, "success wire shape")
        let reordered = " { \"parameters\": {}, \"action\": \"capabilities\", \"requestID\": \"\(id)\", \"version\": 1 } "
        try check((try? decode(reordered)) == capabilities, "whitespace order")
        try check(rejects(request("getState", "{\"outer\":{\"name\":1,\"na\\u006de\":2}}", session: token)), "deep escaped duplicate")
        do { _ = try decode(request("capabilities", "{}").replacingOccurrences(of: "\"version\":1", with: "\"version\":2")); throw CaseFailure("version accepted") }
        catch let e as AutomationError { try check(e.code == .unsupportedProtocol, "version code") }
        try check(rejects(request("key", "{\"name\":\"Tab\",\"shift\":1}", session: token)), "shift boolean")
        try check(rejects(request("insertText", "{\"text\":\"\(String(repeating: "中", count: 5462))\"}", session: token)), "utf8 bytes limit")
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 50, pixelWidth: 200, pixelHeight: 100, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 4)
        let shot = AutomationReply(requestID: open.requestID, outcome: .success(.snapshotWritten(path: "/tmp/fake.png", viewport: viewport)))
        let shotJSON = try JSONSerialization.jsonObject(with: AutomationCodec.encode(shot)) as! [String: Any]
        let shotResult = shotJSON["result"] as! [String: Any]
        try check(shotJSON["effect"] as? String == "snapshotWritten" && shotResult["viewportWidthPoints"] != nil && shotResult["viewVersion"] != nil, "screenshot metadata")
        try check(!String(reflecting: shot).contains("fake.png"), "reply redaction")
        // These strings compare equal in Swift but send different UTF-8 to the page.
        let composed = "\u{e9}", decomposed = "e\u{301}"
        try check(composed == decomposed && !composed.utf8.elementsEqual(decomposed.utf8), "unicode test fixture")
        func stringParameter(_ value: String) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        let firstText = try decode(request("insertText", "{\"text\":\"\(composed)\"}", session: token))
        let secondText = try decode(request("insertText", "{\"text\":\"\(decomposed)\"}", session: token))
        let escapedText = try decode(request("insertText", "{\"text\":\"\\u00e9\"}", session: token))
        var textCache = AutomationReplayCache(startedAt: 0)
        try check(textCache.begin(firstText, at: 1) == .reserved, "unicode reserve")
        try check(textCache.begin(escapedText, at: 2) == .inFlight, "same text alternate JSON escape")
        try check(textCache.begin(secondText, at: 3) == .rejected(.requestIDReused), "unicode inflight mismatch")
        let textReceipt = AutomationReply(requestID: firstText.requestID, outcome: .failure(AutomationError(code: .timeout)))
        try check(!textCache.complete(secondText, reply: textReceipt, at: 4), "unicode mismatched completion")
        try check(textCache.complete(firstText, reply: textReceipt, at: 5), "unicode completion")
        try check(textCache.begin(secondText, at: 6) == .rejected(.requestIDReused), "unicode completed mismatch")
        try check(textCache.begin(escapedText, at: 7) == .replay(textReceipt), "same text completed replay")
        let firstURL = try decode(request("navigate", "{\"url\":\(try stringParameter("https://example.com/%C3%A9"))}", session: token))
        let secondURL = try decode(request("navigate", "{\"url\":\(try stringParameter("https://example.com/e%CC%81"))}", session: token))
        var urlCache = AutomationReplayCache(startedAt: 0)
        try check(urlCache.begin(firstURL, at: 1) == .reserved, "url reserve")
        try check(urlCache.begin(secondURL, at: 2) == .rejected(.requestIDReused), "url inflight mismatch")
        let urlReceipt = AutomationReply(requestID: firstURL.requestID, outcome: .failure(AutomationError(code: .timeout)))
        try check(urlCache.complete(firstURL, reply: urlReceipt, at: 3), "url completion")
        try check(urlCache.begin(secondURL, at: 4) == .rejected(.requestIDReused), "url completed mismatch")
        let upper = try decode("{\"version\":1,\"requestID\":\"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA\",\"action\":\"openSession\",\"parameters\":{\"profileID\":\"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB\"}}")
        let lower = try decode(" { \"parameters\": { \"profileID\": \"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\" }, \"action\": \"openSession\", \"requestID\": \"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\", \"version\": 1 }")
        var uuidCache = AutomationReplayCache(startedAt: 0)
        try check(uuidCache.begin(upper, at: 1) == .reserved, "uuid reserve")
        try check(uuidCache.begin(lower, at: 2) == .inFlight, "uuid case and JSON layout")
        var cache = AutomationReplayCache(startedAt: 0)
        try check(cache.begin(open, at: 1) == .reserved, "reserve")
        try check(cache.begin(open, at: 2) == .inFlight, "inflight")
        let receipt = AutomationReply(requestID: open.requestID, outcome: .failure(AutomationError(code: .timeout)))
        try check(cache.complete(open, reply: receipt, at: 3), "complete")
        try check(cache.begin(open, at: 4) == .replay(receipt), "replay")
        try check(!cache.complete(open, reply: receipt, at: 4), "no duplicate complete")
        let altered = try decode(request("capabilities", "{}"))
        try check(cache.begin(altered, at: 5) == .rejected(.requestIDReused), "reused")
        try check(cache.renew(at: 29), "renew")
        try check(cache.begin(open, at: 31) == .replay(receipt), "lease retains earlier keys")
        try check(cache.begin(open, at: 59) == .rejected(.sessionExpired), "lease expiry")
        try check(!cache.renew(at: 60), "no revival")
        var full = AutomationReplayCache(startedAt: 0)
        for i in 0..<256 {
            let rid = String(format: "00000000-0000-4000-8000-%012d", i)
            let r = try decode("{\"version\":1,\"requestID\":\"\(rid)\",\"action\":\"capabilities\",\"parameters\":{}}")
            try check(full.begin(r, at: 1) == .reserved, "capacity reserve")
        }
        let extra = try decode("{\"version\":1,\"requestID\":\"00000000-0000-4000-8001-000000000000\",\"action\":\"capabilities\",\"parameters\":{}}")
        try check(full.begin(extra, at: 1) == .rejected(.replayWindowFull), "capacity full")
        var backwards = AutomationReplayCache(startedAt: 10)
        try check(backwards.begin(open, at: 9) == .rejected(.sessionExpired), "backward monotonic clock")
        try check(!backwards.renew(at: 11), "backward clock fails closed")
        return checks
    }
    public struct CaseFailure: Error { public let label: String; init(_ label: String) { self.label = label } }
}
