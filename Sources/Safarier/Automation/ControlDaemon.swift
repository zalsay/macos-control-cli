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
    var readyToStop: Bool?
    var connection: UUID?
    var frame: UUID?
    var screenshotPath: String?
    var remoteScreenshotUnavailable: Bool?
    var viewport: AutomationViewport?
    var ocr: SemanticOCRResult?
    var selection: SemanticDecision?
    var timingMs: UInt64?
    var sent: Bool?
    var effectVerified: Bool?
    var filesSelected: Int?
    var navigationSubmitted: Bool?
    var state: AutomationState?
    var capabilities: AutomationCapabilities?
    var sequence: UInt64?
    var buttons: Int?
    var viewVersion: UInt64?
    var cleaned: Bool?
    var terminatedOwnedRunner: Bool?
    var retainedBrowser: RetainedBrowserCleanup?
    var controlReleased: ControlReleaseReceipt?
    var authorization: HostAuthorizationReceipt?
    init(_ id: UUID, status: String, error: String? = nil) { self.version = 1; self.requestID = id; self.status = status; self.error = error }
}

struct HostAuthorizationReceipt: Codable, Equatable, Sendable {
    let requestID: UUID
    let status: String
    let osStatus: Int32?
    let statusDescription: String
    let businessEventSent: Bool

    init(requestID: UUID, status: String, osStatus: Int32? = nil, statusDescription: String, businessEventSent: Bool = false) {
        self.requestID = requestID
        self.status = status
        self.osStatus = osStatus
        self.statusDescription = statusDescription
        self.businessEventSent = businessEventSent
    }

    init(requestID: UUID, reply: ControlAuthorization.Reply) {
        self.init(requestID: requestID, status: reply.status, osStatus: reply.osStatus,
                  statusDescription: "本次授权请求的系统回执：\(reply.statusDescription)这是历史回执，不是当前权限探测；没有发送业务事件。")
    }
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
        var frames: [(id: UUID, viewport: AutomationViewport)] = []
        func rememberFrame(_ viewport: AutomationViewport) -> UUID {
            let id = UUID()
            frames.append((id, viewport))
            if frames.count > 32 { frames.removeFirst(frames.count - 32) }
            frameID = id
            return id
        }
        func frameViewport(_ id: UUID) -> AutomationViewport? { frames.first { $0.id == id }?.viewport }
        var active = false, awaitingAck = false
        // Historical diagnostic only; each explicit request is admitted afresh.
        var uncertain = false
        var semanticCancellation: ControlCancellation?
        init(token: String, target: AutomationTargetIdentity, viewport: AutomationViewport) { self.token = token; self.target = target; self.viewport = viewport }
    }
    private struct CacheEntry { let request: Data; var response: Data? }
    typealias Sender = @MainActor (AutomationRequest) async throws -> AutomationReply
    private var sender: Sender
    private let refreshOnConnect: @MainActor () throws -> Sender?
    private let loadDecisionConfig: () throws -> ControlDecisionConfig
    private let recognize: (String, AutomationViewport) async -> SemanticOCRResult
    private let decide: (ControlDecisionConfig, Data, ControlCancellation) async throws -> Data
    private var sessions: [UUID: Session] = [:]
    private var cache: [UUID: CacheEntry] = [:]
    private var opening = false
    private var stopping = false
    private var stopCommitScheduled = false
    private var pendingAcknowledgements: [UUID: (Session, Bool)] = [:]
    private struct AuthorizationAttempt {
        let requestID: UUID
        var receipt: HostAuthorizationReceipt
    }
    private var authorizationAttempt: AuthorizationAttempt?
    private let hostProfileID: UUID?
    private let authorize: @MainActor (Bool) async -> ControlAuthorization.Reply
    #if SAFARIER_CONTROL_TESTING
    private var testChildDiagnostic: ((UUID, UUID) -> Void)?
    #endif
    private func recordScreenshotChild(parent: UUID, child: UUID) {
        #if SAFARIER_CONTROL_TESTING
        if let testChildDiagnostic { testChildDiagnostic(parent, child); return }
        #endif
        NavigationDiagnostic.screenshotChild(parent: parent, child: child)
    }

    init(applicationPath: String, runtimePath: String) throws {
        var current = try ControlAppleEventClient(applicationPath: applicationPath)
        func boundSender(_ manager: ControlAppleEventClient) -> Sender {
            { request in try await manager.send(request) }
        }
        sender = boundSender(current)
        refreshOnConnect = {
            guard current.managerHasExited else { return nil }
            let replacement = try ControlAppleEventClient(applicationPath: applicationPath)
            current = replacement
            return boundSender(replacement)
        }
        authorize = { request in
            let manager = current
            return await manager.authorization(request: request)
        }
        hostProfileID = RemoteHostRuntime.profileID(runtimePath: runtimePath)
        loadDecisionConfig = { try ControlDecisionConfig.load() }
        recognize = { path, viewport in await ControlOCR.shared.recognize(path:path,viewport:viewport) }
        decide = { config, request, cancellation in try await ControlDecision.decide(config:config,request:request,cancellation:cancellation) }
    }
    #if SAFARIER_CONTROL_TESTING
    init(testSender: @escaping Sender,
         testRefreshOnConnect: @escaping @MainActor () throws -> Sender? = { nil },
         testAuthorization: @escaping @MainActor (Bool) async -> ControlAuthorization.Reply = { _ in
             ControlAuthorization.Reply(status: "unavailable", osStatus: nil)
         },
         testHostProfileID: UUID? = nil,
         testConfig: @escaping () throws -> ControlDecisionConfig = { try ControlDecisionConfig.load() },
         testOCR: @escaping (String, AutomationViewport) async -> SemanticOCRResult = { path, viewport in await ControlOCR.shared.recognize(path:path,viewport:viewport) },
         testDecision: @escaping (ControlDecisionConfig, Data, ControlCancellation) async throws -> Data = { config, request, cancellation in try await ControlDecision.decide(config:config,request:request,cancellation:cancellation) },
         testChildDiagnostic: ((UUID, UUID) -> Void)? = nil) {
        sender=testSender; refreshOnConnect=testRefreshOnConnect; authorize=testAuthorization; hostProfileID=testHostProfileID
        loadDecisionConfig=testConfig; recognize=testOCR; decide=testDecision; self.testChildDiagnostic = testChildDiagnostic
    }
    #endif

    private func response(_ request: ControlRequest, _ code: String) -> ControlBrokerReply { ControlBrokerReply(request.requestID, status: "error", error: code) }
    private func point(_ x: Double, _ y: Double, frame: UUID, session: Session) throws -> ViewportPoint {
        guard let viewport = session.frameViewport(frame), let p = ControlRuntime.nativePoint(x: x, y: y, viewport: viewport) else { throw ControlRuntime.Failure.unsafe }
        return p
    }
    private func exchange(_ id: UUID, _ action: AutomationAction, _ token: String?, expectedViewVersion: UInt64? = nil) async throws -> AutomationResult {
        let reply = try await sender(AutomationRequest(version: 1, requestID: id, sessionID: token, action: action, expectedViewVersion: expectedViewVersion))
        switch reply.outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }
    private func adoptViewport(_ viewport: AutomationViewport, session: Session) {
        // A screenshot describes the current page; changes are observations, not
        // evidence that a previous input failed or that its frame is unusable.
        session.viewport = viewport
    }
    private func matches(_ action: AutomationAction, _ value: AutomationResult) -> Bool {
        switch (action, value) {
        case (.getState, .stateRead), (.screenshot, .snapshotWritten),
             (.navigate, .navigationSubmitted), (.navigate, .navigationFinished), (.navigateByInput, .navigationFinished),
             (.navigateByInput, .navigationSubmitted), (.navigateByInput, .nativeDelivered),
             (.move, .nativeDelivered), (.mouseDown, .nativeDelivered), (.mouseUp, .nativeDelivered),
             (.click, .nativeDelivered), (.insertText, .nativeDelivered), (.key, .nativeDelivered),
             (.cancel, .sessionClosed), (.closeSession, .sessionClosed): return true
        case let (.selectFiles(paths), .filesSelected(count)): return count == paths.count
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
        switch request.operation { case .cancel, .disconnect, .release, .daemonStop, .authorizationStatus: reserved = true; default: reserved = false }
        cache[request.requestID] = CacheEntry(request: canonical, response: nil)
        let reply = await perform(request, reserved: reserved)
        let data = encode(reply)
        cache[request.requestID]?.response = data
        return (data, pendingAcknowledgements[request.requestID] == nil ? nil : request.requestID)
    }
    func acknowledgement(_ requestID: UUID, received: Bool) {
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        NavigationDiagnostic.emitID(requestID, "broker.ack", received ? "received" : "lost")
        #endif
        guard let (session, _) = pendingAcknowledgements.removeValue(forKey: requestID) else { return }
        session.awaitingAck = pendingAcknowledgements.values.contains { $0.0 === session }
        if !received {
            session.uncertain = true
        }
    }
    /// A cached stop reply must not schedule cleanup a second time.
    func claimStopCommit() -> Bool {
        guard stopping, !stopCommitScheduled else { return false }
        stopCommitScheduled = true
        return true
    }
    private func encode(_ reply: ControlBrokerReply) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data("{\"version\":1,\"status\":\"error\"}".utf8)
    }
    private func perform(_ request: ControlRequest, reserved: Bool) async -> ControlBrokerReply {
        var result = ControlBrokerReply(request.requestID, status: "ok")
        if case .status = request.operation {
            result.readyToStop = canStop(excluding: request.requestID)
            return result
        }
        if case .daemonStop = request.operation {
            guard canStop(excluding: request.requestID) else { return response(request, "SESSION_BUSY") }
            stopping = true
            return result
        }
        if case .capabilities = request.operation {
            do { guard case let .capabilities(caps) = try await exchange(request.requestID, .capabilities, nil) else { return response(request, "INVALID_REPLY") }; result.capabilities = caps; return result }
            catch { return response(request, "UNAVAILABLE") }
        }
        if case .authorizationRequest = request.operation {
            guard hostProfileID != nil else { return response(request, "HOST_PROFILE_REQUIRED") }
            if let authorizationAttempt, authorizationAttempt.receipt.status == "pending" {
                result.authorization = HostAuthorizationReceipt(requestID: authorizationAttempt.requestID, status: "pending",
                    statusDescription: "系统授权请求正在等待用户处理；没有发送业务事件。")
                return result
            }
            let authorizationID = request.requestID
            authorizationAttempt = AuthorizationAttempt(requestID: authorizationID, receipt: HostAuthorizationReceipt(
                requestID: authorizationID, status: "pending", statusDescription: "系统授权请求已派发，等待用户处理；没有发送业务事件。"))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reply = await self.authorize(true)
                guard self.authorizationAttempt?.requestID == authorizationID else { return }
                self.authorizationAttempt?.receipt = HostAuthorizationReceipt(requestID: authorizationID, reply: reply)
            }
            result.authorization = authorizationAttempt?.receipt
            return result
        }
        if case let .authorizationStatus(authorizationID) = request.operation {
            guard hostProfileID != nil, let attempt = authorizationAttempt,
                  attempt.requestID == authorizationID else { return response(request, "AUTHORIZATION_NOT_FOUND") }
            result.authorization = attempt.receipt
            return result
        }
        if case let .connect(profileID) = request.operation {
            guard !opening else { return response(request, "SESSION_BUSY") }
            opening = true
            defer { opening = false }
            do {
                if let replacement = try refreshOnConnect() {
                    // Only an explicitly requested fresh connection can change
                    // recipients. An old frame or in-flight semantic operation
                    // must never use a new Manager's connection.
                    for session in sessions.values { session.semanticCancellation?.cancel() }
                    sessions.removeAll()
                    pendingAcknowledgements.removeAll()
                    sender = replacement
                }
                guard case let .sessionOpened(token, target, viewport) = try await exchange(request.requestID, .openSession(profileID: profileID), nil), target.profileID == profileID else { return response(request, "INVALID_REPLY") }
                let id = UUID(); let session = Session(token: token, target: target, viewport: viewport)
                session.awaitingAck = true; sessions[id] = session; pendingAcknowledgements[request.requestID] = (session, true)
                result.connection = id; result.viewport = viewport; return result
            } catch let error as AutomationError {
                return response(request, error.code.rawValue)
            } catch ControlAppleEventClient.Failure.unavailable { return response(request, "UNAVAILABLE") }
            catch { return response(request, "INDETERMINATE_RESULT") }
        }
        let connection: UUID
        switch request.operation {
        case let .state(c), let .observe(c), let .clickTarget(c, _), let .selectFile(c, _), let .cancel(c), let .disconnect(c), let .release(c), let .navigate(c, _),
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
        guard reserved || !session.active else { return response(request, "SESSION_BUSY") }
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
                adoptViewport(viewport, session: session)
                let frame = session.rememberFrame(viewport)
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
                guard sessions[connection] === session, case let .nativeDelivered(sequence,buttons,version) = value else { session.uncertain = true; return response(request,"INVALID_REPLY") }
                result.sequence=sequence; result.buttons=buttons; result.viewVersion=version
                result.sent=true; result.selection=chosen; result.timingMs=(DispatchTime.now().uptimeNanoseconds-started)/1_000_000; result.effectVerified=false; return result
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
            case .selectFile(_, let paths): action = .selectFiles(paths)
            case .cancel: action = .cancel
            case .disconnect: action = .closeSession
            case .release: action = .releaseControl
            case let .navigate(_, url): action = .navigate(url: url)
            case let .move(_, frame, x, y): action = .move(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion)
            case let .mouseDown(_, frame, x, y): action = .mouseDown(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion)
            case let .mouseUp(_, frame, x, y): action = .mouseUp(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion)
            case let .click(_, frame, x, y, count): action = .click(point: try point(x, y, frame: frame, session: session), viewVersion: session.viewport.viewVersion, count: count)
            case let .type(_, frame, text): guard session.frameViewport(frame) != nil else { throw ControlRuntime.Failure.unsafe }; action = .insertText(text)
            case let .press(_, frame, key, shift): guard session.frameViewport(frame) != nil else { throw ControlRuntime.Failure.unsafe }; action = .key(name: key, shift: shift)
            case let .pressEnterAndWait(_, frame): guard session.frameViewport(frame) != nil else { throw ControlRuntime.Failure.unsafe }; action = .navigateByInput(input: .enter, viewVersion: session.viewport.viewVersion)
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
                let old = session.viewport
                let current = AutomationViewport(viewportWidthPoints: old.viewportWidthPoints, viewportHeightPoints: old.viewportHeightPoints, pixelWidth: old.pixelWidth, pixelHeight: old.pixelHeight, scaleX: old.scaleX, scaleY: old.scaleY, pageZoom: old.pageZoom, viewVersion: state.viewVersion)
                guard state.target == session.target else { session.uncertain = true; return response(request, "TARGET_CHANGED") }
                adoptViewport(current, session: session)
                result.state = state
            case let .snapshotWritten(path, viewport):
                adoptViewport(viewport, session: session)
                let frame = session.rememberFrame(viewport); result.connection = connection; result.frame = frame; result.screenshotPath = path; result.viewport = viewport
                result.ocr = await recognize(path,viewport)
                guard sessions[connection] === session, session.frameID == frame, session.viewport == viewport else { return response(request,"TARGET_CHANGED") }
            case let .navigationSubmitted(version), let .navigationFinished(version):
                let old = session.viewport
                session.viewport = AutomationViewport(viewportWidthPoints: old.viewportWidthPoints, viewportHeightPoints: old.viewportHeightPoints, pixelWidth: old.pixelWidth, pixelHeight: old.pixelHeight, scaleX: old.scaleX, scaleY: old.scaleY, pageZoom: old.pageZoom, viewVersion: version)
                result.viewVersion = version
                if case .navigationSubmitted = value { result.navigationSubmitted = true; result.effectVerified = false }
            case .filesSelected(let count):
                result.filesSelected = count; result.sent = true; result.effectVerified = false
            case let .nativeDelivered(sequence, buttons, version):
                result.sequence = sequence; result.buttons = buttons; result.viewVersion = version
                result.sent = true; result.effectVerified = false
            case let .sessionClosed(receipt):
                result.cleaned = receipt.cleaned; result.terminatedOwnedRunner = receipt.terminatedOwnedRunner
                let retained = receipt.retainedBrowser
                let borrowedConfirmed = !receipt.cleaned && !receipt.terminatedOwnedRunner && retained?.target == session.target && retained?.confirmed == true
                if borrowedConfirmed { result.retainedBrowser = retained }
                if !(receipt.cleaned && receipt.terminatedOwnedRunner && retained == nil) && !borrowedConfirmed {
                    result.status = "error"; result.error = "CLEANUP_UNCONFIRMED"
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

    /// Status preflight and daemonStop deliberately share the same admission
    /// predicate. Each request excludes its own still-in-flight cache entry.
    private func canStop(excluding requestID: UUID) -> Bool {
        sessions.isEmpty && pendingAcknowledgements.isEmpty && !opening &&
            authorizationAttempt?.receipt.status != "pending" &&
            !cache.contains(where: { $0.key != requestID && $0.value.response == nil })
    }
}

@MainActor
enum ControlDaemon {
    static func serve(applicationPath: String, runtimePath: String) throws {
        guard cs_control_verify_self() == 1 else { throw ControlRuntime.Failure.unsafe }
        let runtime = try ControlRuntime(path: runtimePath, create: true)
        let broker = try ControlBroker(applicationPath: applicationPath, runtimePath: runtimePath)
        let instance = ControlRuntime.applicationInstance(applicationPath)
        let admission = ControlAdmission()
        guard let startupLock = try runtime.acquireStartupLock(waitSeconds: 3) else {
            throw ControlRuntime.Failure.indeterminate
        }
        defer { startupLock.release() }
        let (listener, socketPin) = try runtime.listenSocket(lockedBy: startupLock)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue.global(qos: .userInitiated))
        source.setCancelHandler {
            Darwin.close(listener)
            CFRunLoopStop(CFRunLoopGetMain())
        }
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
                    switch request.operation { case .cancel, .disconnect, .release, .daemonStop, .authorizationStatus: ordinary = false; default: ordinary = true }
                    guard admission.claim(ordinary: ordinary) else { Darwin.close(descriptor); admission.finish(ordinary: false); return }
                    Task { @MainActor in
                        do {
                            try runtime.validateSocket(socketPin)
                            guard ControlRuntime.samePeer(peer, try ControlRuntime.peer(descriptor)) else { throw ControlRuntime.Failure.unsafe }
                        } catch { Darwin.close(descriptor); admission.finish(ordinary: ordinary); return }
                        let (reply, acknowledgement) = await broker.handle(request)
                        let shouldStop: Bool
                        if case .daemonStop = request.operation,
                           let parsed = try? JSONDecoder().decode(ControlBrokerReply.self, from: reply), parsed.status == "ok" {
                            shouldStop = broker.claimStopCommit()
                        }
                        else { shouldStop = false }
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { Darwin.close(descriptor); admission.finish(ordinary: ordinary) }
                            var received = false
                            do {
                                try runtime.validateSocket(socketPin)
                                try ControlRuntime.serverReply(descriptor, reply: reply, peer: peer, hello: hello)
                                received = true
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
                            if shouldStop {
                                // The authenticated, idle stop was committed by the
                                // broker before replying. A disconnected client must
                                // not leave the broker permanently stuck in stopping.
                                do { try runtime.removeOwnedSocket(socketPin, lockedBy: startupLock) }
                                catch {
                                    NavigationDiagnostic.emitID(request.requestID, "server.stop.cleanup", "CLEANUP_UNCONFIRMED")
                                }
                                source.cancel()
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
