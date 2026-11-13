import Foundation
@testable import SafarierCore

public enum AutomationWireCases {
    public struct Failure: Error { public let label: String }
    public static func run() async throws -> Int {
        var count = 0
        func check(_ ok: @autoclosure () -> Bool, _ label: String) throws { count += 1; if !ok() { throw Failure(label: label) } }
        let id = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let token = String(repeating: "A", count: 43)
        let target = AutomationTargetIdentity(profileID: id, runnerInstanceID: id, windowID: id, pageID: id)
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 80, pixelWidth: 200, pixelHeight: 160, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 3)
        let caps = AutomationCapabilities(backend: .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: "1", role: "runner", managerPID: 1)
        let state = AutomationState(target: target, url: URL(string: "about:blank"), loading: false, sessionState: .ready, viewVersion: 3)
        let results: [AutomationResult] = [.sessionOpened(sessionID: token, target: target, viewport: viewport), .nativeDelivered(sequence: 1, buttons: 0, viewVersion: 3), .navigationFinished(viewVersion: 3), .snapshotWritten(path: "/tmp/test.png", viewport: viewport), .capabilities(caps), .stateRead(state), .sessionClosed(CleanupReceipt(cleaned: true, terminatedOwnedRunner: false))]
        for result in results {
            let reply = AutomationReply(requestID: id, outcome: .success(result))
            let data = try AutomationCodec.encode(reply)
            try check((try? AutomationCodec.decodeReply(data)) == reply, "reply roundtrip")
        }
        let failure = AutomationReply(requestID: nil, outcome: .failure(AutomationError(code: .invalidRequest)))
        try check((try? AutomationCodec.decodeReply(AutomationCodec.encode(failure))) == failure, "error null id")
        for json in ["{\"version\":1,\"requestID\":null,\"status\":\"ok\",\"effect\":\"nativeDelivered\",\"result\":{\"sequence\":1,\"buttons\":0,\"viewVersion\":1}}", "{\"version\":1,\"vers\\u0069on\":1,\"requestID\":null,\"status\":\"error\",\"error\":{\"code\":\"INVALID_REQUEST\",\"retryable\":false,\"sideEffects\":\"none\"}}", "{\"version\":1,\"requestID\":null,\"status\":\"error\",\"effect\":\"stateRead\",\"error\":{\"code\":\"INVALID_REQUEST\",\"retryable\":false,\"sideEffects\":\"none\"}}"] {
            try check((try? AutomationCodec.decodeReply(Data(json.utf8))) == nil, "bad reply")
        }
        let validNative = "{\"version\":1,\"requestID\":\"\(id)\",\"status\":\"ok\",\"effect\":\"nativeDelivered\",\"result\":{\"sequence\":1,\"buttons\":0,\"viewVersion\":1}}"
        for json in [validNative.replacingOccurrences(of: "nativeDelivered", with: "navigationFinished"), validNative.replacingOccurrences(of: "\"buttons\":0", with: "\"buttons\":0,\"extra\":0"), validNative.replacingOccurrences(of: "\"buttons\":0", with: "\"buttons\":true"), validNative.replacingOccurrences(of: "\"buttons\":0", with: "\"buttons\":0,\"butt\\u006fns\":0"), validNative.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), validNative.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1e999")] {
            try check((try? AutomationCodec.decodeReply(Data(json.utf8))) == nil, "strict bad result")
        }
        try check((try? AutomationCodec.decodeReply(Data([0xff]))) == nil, "reply utf8")
        try check((try? AutomationCodec.decodeReply(Data(repeating: 32, count: 65_537))) == nil, "reply frame limit")
        let invalidRequest = AutomationRequest(version: 1, requestID: id, sessionID: token, action: .scroll(point: ViewportPoint(x: .infinity, y: 0), viewVersion: 1, deltaX: 0, deltaY: 0))
        try check((try? AutomationCodec.encodeRequest(invalidRequest)) == nil, "reject nonfinite request")
        let screenshotReply = AutomationReply(requestID: id, outcome: .success(.snapshotWritten(path: "/tmp/example.png", viewport: viewport)))
        let screenshotJSON = String(decoding: try AutomationCodec.encode(screenshotReply), as: UTF8.self)
        let infinityJSON = screenshotJSON.replacingOccurrences(of: "\"scaleX\":2", with: "\"scaleX\":1e999")
        try check(infinityJSON != screenshotJSON && (try? AutomationCodec.decodeReply(Data(infinityJSON.utf8))) == nil, "nonfinite result")
        let invalidViewport = AutomationViewport(viewportWidthPoints: .infinity, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let invalidReply = AutomationReply(requestID: id, outcome: .success(.snapshotWritten(path: "/tmp/example.png", viewport: invalidViewport)))
        try check((try? AutomationCodec.encode(invalidReply)) == nil, "nonfinite reply encoding")
        let openReply = AutomationReply(requestID: id, outcome: .success(.sessionOpened(sessionID: token, target: target, viewport: viewport)))
        let openJSON = String(decoding: try AutomationCodec.encode(openReply), as: UTF8.self)
        let invalidTokenJSON = openJSON.replacingOccurrences(of: token, with: String(repeating: "B", count: 43))
        try check((try? AutomationCodec.decodeReply(Data(invalidTokenJSON.utf8))) == nil, "noncanonical response token")
        func mutateReply(_ reply: AutomationReply, field: String, value: Any, nestedViewport: Bool) throws -> Data {
            var root = try JSONSerialization.jsonObject(with: AutomationCodec.encode(reply)) as! [String: Any]
            var result = root["result"] as! [String: Any]
            if nestedViewport {
                var view = result["viewport"] as! [String: Any]
                view[field] = value; result["viewport"] = view
            } else { result[field] = value }
            root["result"] = result
            return try JSONSerialization.data(withJSONObject: root)
        }
        let nativeReply = AutomationReply(requestID: id, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        let invalidButtons = try mutateReply(nativeReply, field: "buttons", value: 2, nestedViewport: false)
        try check((try? AutomationCodec.decodeReply(invalidButtons)) == nil, "invalid native button decode")
        let negativeButtons = try mutateReply(nativeReply, field: "buttons", value: -1, nestedViewport: false)
        try check((try? AutomationCodec.decodeReply(negativeButtons)) == nil, "negative native button decode")
        let validButton = try mutateReply(nativeReply, field: "buttons", value: 1, nestedViewport: false)
        try check((try? AutomationCodec.decodeReply(validButton)) != nil, "left button accepted")
        let invalidButtonReply = AutomationReply(requestID: id, outcome: .success(.nativeDelivered(sequence: 1, buttons: 2, viewVersion: 1)))
        try check((try? AutomationCodec.encode(invalidButtonReply)) == nil, "invalid native button encode")
        for key in ["viewportWidthPoints", "viewportHeightPoints", "pixelWidth", "pixelHeight", "scaleX", "scaleY", "pageZoom"] {
            let badOpen = try mutateReply(openReply, field: key, value: 0, nestedViewport: true)
            let badSnapshot = try mutateReply(screenshotReply, field: key, value: 0, nestedViewport: false)
            try check((try? AutomationCodec.decodeReply(badOpen)) == nil, "open zero " + key)
            try check((try? AutomationCodec.decodeReply(badSnapshot)) == nil, "snapshot zero " + key)
            let negativeOpen = try mutateReply(openReply, field: key, value: -1, nestedViewport: true)
            let negativeSnapshot = try mutateReply(screenshotReply, field: key, value: -1, nestedViewport: false)
            try check((try? AutomationCodec.decodeReply(negativeOpen)) == nil, "open negative " + key)
            try check((try? AutomationCodec.decodeReply(negativeSnapshot)) == nil, "snapshot negative " + key)
        }
        for key in ["pixelWidth", "pixelHeight"] {
            let tooLarge = try mutateReply(screenshotReply, field: key, value: 4097, nestedViewport: false)
            try check((try? AutomationCodec.decodeReply(tooLarge)) == nil, "snapshot edge limit " + key)
            let atLimit = try mutateReply(screenshotReply, field: key, value: 4096, nestedViewport: false)
            try check((try? AutomationCodec.decodeReply(atLimit)) != nil, "snapshot edge boundary " + key)
        }
        let zeroViewport = AutomationViewport(viewportWidthPoints: 0, viewportHeightPoints: 1, pixelWidth: 1, pixelHeight: 1, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let zeroOpen = AutomationReply(requestID: id, outcome: .success(.sessionOpened(sessionID: token, target: target, viewport: zeroViewport)))
        let zeroSnapshot = AutomationReply(requestID: id, outcome: .success(.snapshotWritten(path: "/tmp/example.png", viewport: zeroViewport)))
        try check((try? AutomationCodec.encode(zeroOpen)) == nil, "open zero encode")
        try check((try? AutomationCodec.encode(zeroSnapshot)) == nil, "snapshot zero encode")
        let hugeViewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 4097, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let hugeOpen = AutomationReply(requestID: id, outcome: .success(.sessionOpened(sessionID: token, target: target, viewport: hugeViewport)))
        let hugeOpenData = try AutomationCodec.encode(hugeOpen)
        try check((try? AutomationCodec.decodeReply(hugeOpenData)) == hugeOpen, "native viewport over screenshot limit accepted")
        let hugeSnapshot = AutomationReply(requestID: id, outcome: .success(.snapshotWritten(path: "/tmp/example.png", viewport: hugeViewport)))
        try check((try? AutomationCodec.encode(hugeSnapshot)) == nil, "snapshot too large encode")
        let actions: [(String,String,Bool)] = [("capabilities","{}",false),("openSession","{\"profileID\":\"\(id)\"}",false),("getState","{}",true),("navigate","{\"url\":\"https://example.com/\"}",true),("screenshot","{}",true),("move","{\"x\":1,\"y\":2,\"viewVersion\":3}",true),("mouseDown","{\"x\":1,\"y\":2,\"viewVersion\":3}",true),("mouseUp","{\"x\":1,\"y\":2,\"viewVersion\":3}",true),("click","{\"x\":1,\"y\":2,\"viewVersion\":3,\"count\":2}",true),("scroll","{\"x\":1,\"y\":2,\"viewVersion\":3,\"deltaX\":-1,\"deltaY\":2}",true),("insertText","{\"text\":\"test\"}",true),("key","{\"name\":\"Tab\",\"shift\":true}",true),("cancel","{}",true),("closeSession","{}",true)]
        for (name,params,needsSession) in actions {
            let session = needsSession ? ",\"sessionID\":\"\(token)\"" : ""
            let data = Data("{\"version\":1,\"requestID\":\"\(id)\",\"action\":\"\(name)\",\"parameters\":\(params)\(session)}".utf8)
            let request = try AutomationCodec.decode(data)
            try check((try? AutomationCodec.decode(AutomationCodec.encodeRequest(request))) == request, "request roundtrip")
        }
        let hello = try AutomationHandshakeCodec.makeChallenge(profileID: id, nonce: token)
        let challenge = try AutomationHandshakeCodec.readChallenge(hello, expectedProfileID: id)
        let response = try AutomationHandshakeCodec.makeResponse(challenge, runnerInstanceID: id, runnerPID: 123)
        try check((try? AutomationHandshakeCodec.readResponse(response, expectedProfileID: id, expectedNonce: token, expectedPID: 123)) != nil, "handshake")
        try check((try? AutomationHandshakeCodec.readResponse(response, expectedProfileID: id, expectedNonce: token, expectedPID: 124)) == nil, "pid mismatch")
        try check((try? AutomationHandshakeCodec.readResponse(response, expectedProfileID: UUID(), expectedNonce: token, expectedPID: 123)) == nil, "profile mismatch")
        try check((try? AutomationHandshakeCodec.readResponse(response, expectedProfileID: id, expectedNonce: String(repeating:"B", count:43), expectedPID: 123)) == nil, "nonce mismatch")
        let helloText = String(decoding: hello, as: UTF8.self)
        for badHello in [helloText.replacingOccurrences(of: "manager", with: "runner"), helloText.replacingOccurrences(of: "hello", with: "ready"), helloText.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), helloText.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"vers\\u0069on\":1"), helloText.replacingOccurrences(of: "\"role\":\"manager\"", with: "\"role\":\"manager\",\"extra\":0")] {
            try check((try? AutomationHandshakeCodec.readChallenge(Data(badHello.utf8), expectedProfileID: id)) == nil, "bad hello")
        }
        try check((try? AutomationHandshakeCodec.readChallenge(hello, expectedProfileID: UUID())) == nil, "hello profile mismatch")
        let responseText = String(decoding: response, as: UTF8.self)
        for badResponse in [responseText.replacingOccurrences(of: "runner", with: "manager"), responseText.replacingOccurrences(of: "ready", with: "hello"), responseText.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), responseText.replacingOccurrences(of: "\"runnerPID\":123", with: "\"runnerPID\":true")] {
            try check((try? AutomationHandshakeCodec.readResponse(Data(badResponse.utf8), expectedProfileID: id, expectedNonce: token, expectedPID: 123)) == nil, "bad ready")
        }
        let otherToken = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try check((try? AutomationHandshakeCodec.readResponse(response, expectedProfileID: id, expectedNonce: otherToken, expectedPID: 123)) == nil, "canonical wrong nonce")
        let badPair = try AutomationChannel.makePair(); let badRunner = try AutomationChannel(adopting: badPair.child)
        let badService = Task { await AutomationRunnerBootstrap.serveUnavailable(profileID: id, channel: badRunner, idleSeconds: 1) }
        try await badPair.parent.send(Data("{}".utf8))
        let badEOF = try? await badPair.parent.receive()
        try check(badEOF == nil, "pre-hello invalid closes")
        _ = await badService.value; badPair.parent.close()
        let timeoutPair = try AutomationChannel.makePair()
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        do { _ = try await AutomationHandshakeCodec.negotiate(channel: timeoutPair.parent, profileID: id, expectedPID: getpid(), timeoutSeconds: 0.05); throw Failure(label: "timeout accepted") }
        catch is AutomationError { try check(ProcessInfo.processInfo.systemUptime - timeoutStart < 1, "handshake deadline") }
        try? timeoutPair.child.close()
        let cancelPair = try AutomationChannel.makePair()
        let pending = Task { try await AutomationHandshakeCodec.negotiate(channel: cancelPair.parent, profileID: id, expectedPID: getpid(), timeoutSeconds: 5) }
        try await Task.sleep(nanoseconds: 20_000_000); pending.cancel()
        var cancelled = false
        do { _ = try await pending.value } catch { cancelled = true }
        try check(cancelled, "handshake cancel")
        try? cancelPair.child.close()
        let eofPair = try AutomationChannel.makePair(); try eofPair.child.close()
        var eofRejected = false
        do { _ = try await AutomationHandshakeCodec.negotiate(channel: eofPair.parent, profileID: id, expectedPID: getpid(), timeoutSeconds: 1) } catch { eofRejected = true }
        try check(eofRejected, "handshake EOF")
        let mismatchPair = try AutomationChannel.makePair(); let mismatchPeer = try AutomationChannel(adopting: mismatchPair.child)
        let forged = Task {
            guard let data = try await mismatchPeer.receive() else { return }
            let c = try AutomationHandshakeCodec.readChallenge(data, expectedProfileID: id)
            try await mismatchPeer.send(AutomationHandshakeCodec.makeResponse(c, runnerInstanceID: id, runnerPID: getpid()))
        }
        var rejectedMismatch = false
        do { _ = try await AutomationHandshakeCodec.negotiate(channel: mismatchPair.parent, profileID: id, expectedPID: getpid() + 1, timeoutSeconds: 1) } catch { rejectedMismatch = true }
        try check(rejectedMismatch, "negotiation PID mismatch")
        try await forged.value
        let mismatchEOF = try? await mismatchPeer.receive()
        try check(mismatchEOF == nil, "identity mismatch closes")
        mismatchPeer.close()
        let pair = try AutomationChannel.makePair(); let runner = try AutomationChannel(adopting: pair.child)
        let service = Task { await AutomationRunnerBootstrap.serveUnavailable(profileID: id, channel: runner, idleSeconds: 2) }
        let handshake = try await AutomationHandshakeCodec.negotiate(channel: pair.parent, profileID: id, expectedPID: getpid(), timeoutSeconds: 0.1)
        try check(handshake.profileID == id, "negotiated")
        try await Task.sleep(nanoseconds: 200_000_000)
        let capData = Data("{\"version\":1,\"requestID\":\"\(id)\",\"action\":\"capabilities\",\"parameters\":{}}".utf8)
        try await pair.parent.send(capData)
        guard let capReply = try await pair.parent.receive() else { throw Failure(label: "cap EOF") }
        let parsed = try AutomationCodec.decodeReply(capReply)
        if case .success(.capabilities(let value)) = parsed.outcome { try check(value.backend == .unavailable && value.uiPolicy == .unverified && value.coldLaunch == .unverified, "unavailable caps") } else { throw Failure(label: "caps type") }
        for (name,params,needsSession) in actions where name != "capabilities" {
            let session = needsSession ? ",\"sessionID\":\"\(token)\"" : ""
            let data = Data("{\"version\":1,\"requestID\":\"\(id)\",\"action\":\"\(name)\",\"parameters\":\(params)\(session)}".utf8)
            try await pair.parent.send(data)
            guard let bytes = try await pair.parent.receive() else { throw Failure(label: "service EOF") }
            let r = try AutomationCodec.decodeReply(bytes)
            try check(r.outcome == .failure(AutomationError(code: .backendUnavailable)), "reject \(name)")
        }
        try await pair.parent.send(Data("{\"bad\":true}".utf8))
        guard let malformed = try await pair.parent.receive() else { throw Failure(label: "malformed EOF") }
        let malformedReply = try AutomationCodec.decodeReply(malformed)
        try check(malformedReply.requestID == nil && malformedReply.outcome == .failure(AutomationError(code: .invalidRequest)), "malformed fixed reply")
        pair.parent.close(); _ = await service.value
        let stopPair = try AutomationChannel.makePair(); let stopRunner = try AutomationChannel(adopting: stopPair.child)
        let stopService = Task { await AutomationRunnerBootstrap.serveUnavailable(profileID: id, channel: stopRunner, idleSeconds: 5) }
        _ = try await AutomationHandshakeCodec.negotiate(channel: stopPair.parent, profileID: id, expectedPID: getpid(), timeoutSeconds: 1)
        stopService.cancel()
        _ = await stopService.value
        let stopEOF = try? await stopPair.parent.receive()
        try check(stopEOF == nil, "service cancellation closes")
        stopPair.parent.close()
        let idlePair = try AutomationChannel.makePair(); let idleRunner = try AutomationChannel(adopting: idlePair.child)
        let idleService = Task { await AutomationRunnerBootstrap.serveUnavailable(profileID: id, channel: idleRunner, idleSeconds: 0.05) }
        let idleStatus = await idleService.value
        try check(idleStatus != 0, "idle closes")
        let idleEOF = try? await idlePair.parent.receive()
        try check(idleEOF == nil, "idle EOF")
        idlePair.parent.close()
        return count
    }
}
