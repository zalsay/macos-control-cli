import Darwin
import Dispatch
import Foundation
import SafarierControlSupport
import SafarierCore

struct ControlBrokerReply: Codable {
    let version: Int
    let requestID: UUID
    var status: String
    var error: String?
    var connection: UUID?
    var frame: UUID?
    var screenshotPath: String?
    var viewport: AutomationViewport?
    var ocr: SemanticOCRResult?
    var selection: SemanticDecision?
    var timingMs: UInt64?
    var effectVerified: Bool?
    var state: AutomationState?
    var capabilities: AutomationCapabilities?
    var sequence: UInt64?
    var buttons: Int?
    var viewVersion: UInt64?
    var cleaned: Bool?
    var terminatedOwnedRunner: Bool?
    var retainedBrowser: RetainedBrowserCleanup?
    var controlReleased: ControlReleaseReceipt?
    init(_ id: UUID, status: String, error: String? = nil) { self.version = 1; self.requestID = id; self.status = status; self.error = error }
}

/// All 18 transport slots include unauthenticated handshakes. After decoding,
/// ordinary operations can claim at most 16, leaving two operation slots for
/// cancel/close; a handshake flood can still temporarily occupy all transports.
final class ControlAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0
    private var ordinary = 0
    func open() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connections < 18 else { return false }
        connections += 1; return true
    }
    func claim(ordinary isOrdinary: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isOrdinary || ordinary < 16 else { return false }
        if isOrdinary { ordinary += 1 }
        return true
    }
    func finish(ordinary isOrdinary: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isOrdinary { ordinary -= 1 }
        connections -= 1
    }
}

@MainActor
final class ControlBroker {
    private final class Session {
        let token: String, target: AutomationTargetIdentity
        var viewport: AutomationViewport
        var frameID: UUID?
        var active = false, awaitingAck = false, uncertain = false
        var semanticCancellation: ControlCancellation?
        init(token: String, target: AutomationTargetIdentity, viewport: AutomationViewport) { self.token = token; self.target = target; self.viewport = viewport }
    }
    private struct CacheEntry { let request: Data; var response: Data? }
    private let sender: @MainActor (AutomationRequest) async throws -> AutomationReply
    private let loadDecisionConfig: () throws -> ControlDecisionConfig
    private let recognize: (String, AutomationViewport) async -> SemanticOCRResult
    private let decide: (ControlDecisionConfig, Data, ControlCancellation) async throws -> Data
    private var sessions: [UUID: Session] = [:]
    private var cache: [UUID: CacheEntry] = [:]
    private var opening = false
    private var openingUncertain = false
    private var stopping = false
    private var pendingAcknowledgements: [UUID: (Session, Bool)] = [:]
    #if SAFARIER_CONTROL_TESTING
    private var testChildDiagnostic: ((UUID, UUID) -> Void)?
    #endif
    private func recordScreenshotChild(parent: UUID, child: UUID) {
        #if SAFARIER_CONTROL_TESTING
        if let testChildDiagnostic { testChildDiagnostic(parent, child); return }
        #endif
        NavigationDiagnostic.screenshotChild(parent: parent, child: child)
    }

    init(applicationPath: String) throws {
        let manager = try ControlAppleEventClient(applicationPath: applicationPath)
        sender = { request in try await manager.send(request) }
        loadDecisionConfig = { try ControlDecisionConfig.load() }
        recognize = { path, viewport in await ControlOCR.shared.recognize(path:path,viewport:viewport) }
        decide = { config, request, cancellation in try await ControlDecision.decide(config:config,request:request,cancellation:cancellation) }
    }
    #if SAFARIER_CONTROL_TESTING
    init(testSender: @escaping @MainActor (AutomationRequest) async throws -> AutomationReply,
         testConfig: @escaping () throws -> ControlDecisionConfig = { try ControlDecisionConfig.load() },
         testOCR: @escaping (String, AutomationViewport) async -> SemanticOCRResult = { path, viewport in await ControlOCR.shared.recognize(path:path,viewport:viewport) },
         testDecision: @escaping (ControlDecisionConfig, Data, ControlCancellation) async throws -> Data = { config, request, cancellation in try await ControlDecision.decide(config:config,request:request,cancellation:cancellation) },
         testChildDiagnostic: ((UUID, UUID) -> Void)? = nil) {
        sender=testSender; loadDecisionConfig=testConfig; recognize=testOCR; decide=testDecision; self.testChildDiagnostic = testChildDiagnostic
    }
    #endif

    private func response(_ request: ControlRequest, _ code: String) -> ControlBrokerReply { ControlBrokerReply(request.requestID, status: "error", error: code) }
    private func point(_ x: Double, _ y: Double, frame: UUID, session: Session) throws -> ViewportPoint {
        guard session.frameID == frame, let p = ControlRuntime.nativePoint(x: x, y: y, viewport: session.viewport) else { throw ControlRuntime.Failure.unsafe }
        return p
    }
    private func exchange(_ id: UUID, _ action: AutomationAction, _ token: String?) async throws -> AutomationResult {
        let reply = try await sender(AutomationRequest(version: 1, requestID: id, sessionID: token, action: action))
        switch reply.outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }
    private func matches(_ action: AutomationAction, _ value: AutomationResult) -> Bool {
        switch (action, value) {
        case (.getState, .stateRead), (.screenshot, .snapshotWritten),
             (.navigate, .navigationFinished), (.navigateByInput, .navigationFinished),
             (.move, .nativeDelivered), (.mouseDown, .nativeDelivered), (.mouseUp, .nativeDelivered),
             (.click, .nativeDelivered), (.insertText, .nativeDelivered), (.key, .nativeDelivered),
             (.cancel, .sessionClosed), (.closeSession, .sessionClosed): return true
        case (.releaseControl, .controlReleased): return true
        default: return false
        }
    }
    func handle(_ request: ControlRequest) async -> (Data, UUID?) {
        NavigationDiagnostic.emit(request, "broker.received")
        let response = await handleRequest(request)
        let reply = try? JSONDecoder().decode(ControlBrokerReply.self, from: response.0)
        NavigationDiagnostic.emit(request, "broker.reply", reply?.status == "ok" ? "ok" : (reply?.error ?? "error"))
        return response
    }
    private func handleRequest(_ request: ControlRequest) async -> (Data, UUID?) {
        let canonical: Data
        do { canonical = try ControlProtocol.encodeRequest(request) }
        catch { return (encode(response(request, "INVALID_REQUEST")), nil) }
        if let existing = cache[request.requestID] {
            guard existing.request == canonical else { return (encode(response(request, "REQUEST_ID_REUSED")), nil) }
            return (existing.response ?? encode(response(request, "SESSION_BUSY")), nil)
        }
        guard !stopping else { return (encode(response(request, "SESSION_BUSY")), nil) }
        let reserved: Bool
        switch request.operation { case .cancel, .disconnect, .release, .daemonStop: reserved = true; default: reserved = false }
        let capacity: Int
        if case .daemonStop = request.operation { capacity = AutomationLimits.replayEntries + 1 }
        else { capacity = reserved ? AutomationLimits.replayEntries : AutomationLimits.replayEntries - 2 }
        guard cache.count < capacity else { return (encode(response(request, "REPLAY_WINDOW_FULL")), nil) }
        cache[request.requestID] = CacheEntry(request: canonical, response: nil)
        let isRelease: Bool
        if case .release = request.operation { isRelease = true } else { isRelease = false }
        let reply = await perform(request, reserved: reserved && !isRelease)
        let data = encode(reply)
        cache[request.requestID]?.response = data
        return (data, pendingAcknowledgements[request.requestID] == nil ? nil : request.requestID)
    }
    func acknowledgement(_ requestID: UUID, received: Bool) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        NavigationDiagnostic.emitID(requestID, "broker.ack", received ? "received" : "lost")
        #endif
        guard let (session, wasOpen) = pendingAcknowledgements.removeValue(forKey: requestID) else { return }
        session.awaitingAck = pendingAcknowledgements.values.contains { $0.0 === session }
        if wasOpen { opening = false }
        if !received {
            session.uncertain = true
            if wasOpen || !sessions.values.contains(where: { $0 === session }) { openingUncertain = true }
        }
    }
    private func encode(_ reply: ControlBrokerReply) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data("{\"version\":1,\"status\":\"error\"}".utf8)
    }
    private func perform(_ request: ControlRequest, reserved: Bool) async -> ControlBrokerReply {
        var result = ControlBrokerReply(request.requestID, status: "ok")
        if case .status = request.operation { return result }
        if case .daemonStop = request.operation {
            guard sessions.isEmpty, pendingAcknowledgements.isEmpty, !opening, !openingUncertain,
                  !cache.contains(where: { $0.key != request.requestID && $0.value.response == nil }) else { return response(request, "SESSION_BUSY") }
            stopping = true
            return result
        }
        if case .capabilities = request.operation {
            do { guard case let .capabilities(caps) = try await exchange(request.requestID, .capabilities, nil) else { return response(request, "INVALID_REPLY") }; result.capabilities = caps; return result }
            catch { return response(request, "UNAVAILABLE") }
        }
        if case let .connect(profileID) = request.operation {
            guard !opening, !openingUncertain else { return response(request, openingUncertain ? "INDETERMINATE_RESULT" : "SESSION_BUSY") }
            opening = true
            var waitingForAcknowledgement = false
            defer { if !waitingForAcknowledgement { opening = false } }
            do {
                guard case let .sessionOpened(token, target, viewport) = try await exchange(request.requestID, .openSession(profileID: profileID), nil), target.profileID == profileID else { openingUncertain = true; return response(request, "INVALID_REPLY") }
                let id = UUID(); let session = Session(token: token, target: target, viewport: viewport)
                session.awaitingAck = true; sessions[id] = session; pendingAcknowledgements[request.requestID] = (session, true)
                waitingForAcknowledgement = true
                result.connection = id; result.viewport = viewport; return result
            } catch let error as AutomationError {
                if error.sideEffects != .none || error.code == .indeterminateResult { openingUncertain = true }
                return response(request, error.code.rawValue)
            } catch ControlAppleEventClient.Failure.unavailable { return response(request, "UNAVAILABLE") }
            catch { openingUncertain = true; return response(request, "INDETERMINATE_RESULT") }
        }
        let connection: UUID
        switch request.operation {
        case let .state(c), let .observe(c), let .clickTarget(c, _), let .cancel(c), let .disconnect(c), let .release(c), let .navigate(c, _),
             let .move(c, _, _, _), let .mouseDown(c, _, _, _), let .mouseUp(c, _, _, _),
             let .click(c, _, _, _, _), let .type(c, _, _), let .press(c, _, _, _),
             let .pressEnterAndWait(c, _), let .clickAndWait(c, _, _, _): connection = c
        default: return response(request, "INVALID_REQUEST")
        }
        guard let session = sessions[connection] else { return response(request, "SESSION_NOT_FOUND") }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if case .pressEnterAndWait = request.operation {
            NavigationDiagnostic.brokerAdmission(request, reserved: reserved, active: session.active, awaiting: session.awaitingAck, uncertain: session.uncertain)
        }
        #endif
        guard reserved || (!session.active && !session.awaitingAck && !session.uncertain) else { return response(request, session.uncertain ? "INDETERMINATE_RESULT" : "SESSION_BUSY") }
        if reserved { session.semanticCancellation?.cancel() }
        if !reserved { session.active = true }
        defer { if !reserved { session.active = false } }
        if case let .clickTarget(_, target) = request.operation {
            let config: ControlDecisionConfig
            do { config = try loadDecisionConfig() } catch ControlDecisionConfig.Failure.disabled { return response(request, "MODEL_DISABLED") } catch { return response(request, "MODEL_NOT_CONFIGURED") }
            let started = DispatchTime.now().uptimeNanoseconds
            let cancellation = ControlCancellation(); session.semanticCancellation = cancellation
            defer { if session.semanticCancellation === cancellation { session.semanticCancellation = nil } }
            session.awaitingAck = true; pendingAcknowledgements[request.requestID] = (session, false)
            do {
                let screenshotID = UUID()
                recordScreenshotChild(parent: request.requestID, child: screenshotID)
                guard case let .snapshotWritten(path, viewport) = try await exchange(screenshotID, .screenshot, session.token) else { session.uncertain=true; return response(request,"INVALID_REPLY") }
                guard sessions[connection] === session, !cancellation.isCancelled else { return response(request,"TARGET_CHANGED") }
                guard viewport == session.viewport else { session.uncertain=true; return response(request,"TARGET_CHANGED") }
                let frame = UUID(); session.frameID = frame
                let ocr = await recognize(path,viewport)
                guard sessions[connection] === session, !cancellation.isCancelled, session.frameID == frame, session.viewport == viewport else { return response(request, "TARGET_CHANGED") }
                let payload: Data
                do { payload = try SemanticSelection.request(target:target,model:config.model,ocr:ocr) } catch { return response(request, "OCR_UNAVAILABLE") }
                let decision: Data
                do { decision = try await decide(config,payload,cancellation) } catch { return response(request, cancellation.isCancelled ? "CANCELLED" : "JEV_REQUEST_FAILED") }
                guard sessions[connection] === session, !cancellation.isCancelled, session.frameID == frame, session.viewport == viewport else { return response(request, "TARGET_CHANGED") }
                let chosen: SemanticDecision
                do { chosen = try SemanticSelection.select(response:decision,model:config.model,ocr:ocr) }
                catch SemanticSelection.Failure.notFound { return response(request, "TARGET_NOT_FOUND") }
                catch SemanticSelection.Failure.ambiguous { return response(request, "TARGET_AMBIGUOUS") }
                catch { return response(request, "JEV_INVALID_RESPONSE") }
                let point = try self.point(Double(chosen.point.x),Double(chosen.point.y),frame:frame,session:session)
                let value = try await exchange(request.requestID, .click(point:point,viewVersion:viewport.viewVersion,count:1), session.token)
                guard sessions[connection] === session, case let .nativeDelivered(sequence,buttons,version) = value, version == viewport.viewVersion else { session.uncertain = true; return response(request,"INVALID_REPLY") }
                result.sequence=sequence; result.buttons=buttons; result.viewVersion=version
                result.selection=chosen; result.timingMs=(DispatchTime.now().uptimeNanoseconds-started)/1_000_000; result.effectVerified=false; return result
            } catch let error as AutomationError {
                if error.sideEffects != .none || error.code == .indeterminateResult { session.uncertain=true }
                return response(request,error.code.rawValue)
            } catch { session.uncertain=true; return response(request,"INDETERMINATE_RESULT") }
        }
        let action: AutomationAction
        do {
            switch request.operation {
            case .state: action = .getState
            case .observe: action = .screenshot
            case .cancel: action = .cancel
            case .disconnect: action = .closeSession
            case .release: action = .releaseControl
            case let .navigate(_, url): action = .navigate(url: url)
            case let .move(_, frame, x, y): action = .move(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion)
            case let .mouseDown(_, frame, x, y): action = .mouseDown(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion)
            case let .mouseUp(_, frame, x, y): action = .mouseUp(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion)
            case let .click(_, frame, x, y, count): action = .click(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion, count: count)
            case let .type(_, frame, text): guard session.frameID == frame else { throw ControlRuntime.Failure.unsafe }; action = .insertText(text)
            case let .press(_, frame, key, shift): guard session.frameID == frame else { throw ControlRuntime.Failure.unsafe }; action = .key(name: key, shift: shift)
            case let .pressEnterAndWait(_, frame): guard session.frameID == frame else { throw ControlRuntime.Failure.unsafe }; action = .navigateByInput(input: .enter, viewVersion: session.viewport.viewVersion)
            case let .clickAndWait(_, frame, x, y): action = .navigateByInput(input: .click(point: try point(x, y, frame: frame, session: session)), viewVersion: session.viewport.viewVersion)
            default: return response(request, "INVALID_REQUEST")
            }
        } catch { return response(request, "INVALID_FRAME") }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        let traceRequest = AutomationRequest(version: 1, requestID: request.requestID, sessionID: nil, action: action)
        NavigationDiagnostic.emit(traceRequest, "broker.exchange.before")
        #endif
        if !reserved { session.awaitingAck = true; pendingAcknowledgements[request.requestID] = (session, false) }
        do {
            let value = try await exchange(request.requestID, action, session.token)
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            NavigationDiagnostic.emit(traceRequest, "broker.exchange.success")
            #endif
            guard sessions[connection] === session else { return response(request, "SESSION_NOT_FOUND") }
            guard matches(action, value) else { session.uncertain = true; return response(request, "INVALID_REPLY") }
            switch value {
            case let .stateRead(state):
                guard state.target == session.target, state.viewVersion == session.viewport.viewVersion else { session.uncertain = true; return response(request, "TARGET_CHANGED") }
                result.state = state
            case let .snapshotWritten(path, viewport):
                guard viewport == session.viewport else { session.uncertain = true; return response(request, "TARGET_CHANGED") }
                let frame = UUID(); session.frameID = frame; result.connection = connection; result.frame = frame; result.screenshotPath = path; result.viewport = viewport
                result.ocr = await recognize(path,viewport)
                guard sessions[connection] === session, session.frameID == frame, session.viewport == viewport else { return response(request,"TARGET_CHANGED") }
            case let .navigationFinished(version):
                let old = session.viewport
                guard version > old.viewVersion else { session.uncertain = true; return response(request, "TARGET_CHANGED") }
                session.viewport = AutomationViewport(viewportWidthPoints: old.viewportWidthPoints, viewportHeightPoints: old.viewportHeightPoints, pixelWidth: old.pixelWidth, pixelHeight: old.pixelHeight, scaleX: old.scaleX, scaleY: old.scaleY, pageZoom: old.pageZoom, viewVersion: version)
                session.frameID = nil; result.viewVersion = version
            case let .nativeDelivered(sequence, buttons, version):
                guard version == session.viewport.viewVersion else { session.uncertain = true; return response(request, "TARGET_CHANGED") }
                result.sequence = sequence; result.buttons = buttons; result.viewVersion = version
            case let .sessionClosed(receipt):
                result.cleaned = receipt.cleaned; result.terminatedOwnedRunner = receipt.terminatedOwnedRunner
                let retained = receipt.retainedBrowser
                let borrowedConfirmed = !receipt.cleaned && !receipt.terminatedOwnedRunner && retained?.target == session.target && retained?.confirmed == true
                if borrowedConfirmed { result.retainedBrowser = retained }
                if !(receipt.cleaned && receipt.terminatedOwnedRunner && retained == nil) && !borrowedConfirmed {
                    result.status = "error"; result.error = "CLEANUP_UNCONFIRMED"; openingUncertain = true
                }
                if result.status == "ok" {
                    session.awaitingAck = true
                    pendingAcknowledgements[request.requestID] = (session, false)
                }
                sessions.removeValue(forKey: connection)
            case let .controlReleased(receipt):
                guard receipt.target == session.target, receipt.inputReleased, receipt.artifactsCleaned, receipt.browserRetained, receipt.manualInteractionEnabled else { session.uncertain = true; return response(request, "INVALID_REPLY") }
                result.controlReleased = receipt
                sessions.removeValue(forKey: connection)
            default: session.uncertain = true; return response(request, "INVALID_REPLY")
            }
            return result
        } catch let error as AutomationError {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            NavigationDiagnostic.emit(traceRequest, "broker.exchange.error", error.code.rawValue)
            #endif
            if error.sideEffects != .none || error.code == .indeterminateResult { session.uncertain = true }
            return response(request, error.code.rawValue)
        } catch {
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            let code = (error as? ControlAppleEventClient.Failure).map { $0 == .unavailable ? "sender_unavailable" : "sender_indeterminate" } ?? "other"
            NavigationDiagnostic.emit(traceRequest, "broker.exchange.catch", code)
            #endif
            session.uncertain = true
            return response(request, "INDETERMINATE_RESULT")
        }
    }
}

@MainActor
enum ControlDaemon {
    static func serve(applicationPath: String, runtimePath: String) throws {
        guard cs_control_verify_self() == 1 else { throw ControlRuntime.Failure.unsafe }
        let runtime = try ControlRuntime(path: runtimePath, create: true)
        let broker = try ControlBroker(applicationPath: applicationPath)
        let instance = ControlRuntime.applicationInstance(applicationPath)
        let admission = ControlAdmission()
        let (listener, socketPin) = try runtime.listenSocket()
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler {
            let descriptor = Darwin.accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            guard admission.open() else { Darwin.close(descriptor); return }
            do { try ControlRuntime.configureAccepted(descriptor) }
            catch { Darwin.close(descriptor); admission.finish(ordinary: false); return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runtime.validateSocket(socketPin)
                    let (request, peer, hello) = try ControlRuntime.serverReceive(descriptor, instance: instance)
                    try runtime.validateSocket(socketPin)
                    let ordinary: Bool
                    switch request.operation { case .cancel, .disconnect, .release, .daemonStop: ordinary = false; default: ordinary = true }
                    guard admission.claim(ordinary: ordinary) else { Darwin.close(descriptor); admission.finish(ordinary: false); return }
                    Task { @MainActor in
                        do {
                            try runtime.validateSocket(socketPin)
                            guard ControlRuntime.samePeer(peer, try ControlRuntime.peer(descriptor)) else { throw ControlRuntime.Failure.unsafe }
                        } catch { Darwin.close(descriptor); admission.finish(ordinary: ordinary); return }
                        let (reply, acknowledgement) = await broker.handle(request)
                        let shouldStop: Bool
                        if case .daemonStop = request.operation,
                           let parsed = try? JSONDecoder().decode(ControlBrokerReply.self, from: reply), parsed.status == "ok" { shouldStop = true }
                        else { shouldStop = false }
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { Darwin.close(descriptor); admission.finish(ordinary: ordinary) }
                            var received = false
                            do {
                                try runtime.validateSocket(socketPin)
                                try ControlRuntime.serverReply(descriptor, reply: reply, peer: peer, hello: hello)
                                received = true
                                if shouldStop {
                                    try runtime.removeOwnedSocket(socketPin)
                                    source.cancel()
                                    Darwin.close(listener)
                                    CFRunLoopStop(CFRunLoopGetMain())
                                }
                            } catch {
                                #if SAFARIER_BOUND_LOCAL_CANDIDATE
                                let code: String
                                if let failure = error as? ControlRuntime.Failure {
                                    switch failure {
                                    case .unsafe: code = "unsafe"
                                    case .disconnected: code = "disconnected"
                                    case .protocolError: code = "protocolError"
                                    case .indeterminate: code = "indeterminate"
                                    case .cleanupUnconfirmed: code = "cleanupUnconfirmed"
                                    }
                                } else { code = "other" }
                                NavigationDiagnostic.emitID(request.requestID, "server.reply.catch", code)
                                #endif
                                /* A lost acknowledgement is never a retry. */
                            }
                            if let acknowledgement { Task { @MainActor in broker.acknowledgement(acknowledgement, received: received) } }
                        }
                    }
                } catch { Darwin.close(descriptor); admission.finish(ordinary: false) }
            }
        }
        source.resume()
        CFRunLoopRun()
    }
}
