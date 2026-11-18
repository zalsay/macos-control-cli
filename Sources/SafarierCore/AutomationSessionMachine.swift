import Foundation

/// Synchronous effects are intents only: the serialized owner is responsible for
/// identity re-verification and the actual work. No page or process is touched here.
public struct AutomationSessionTicket: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let instanceID: UUID
    public let epoch: UInt64
    public let requestID: UUID
    public init(instanceID: UUID, epoch: UInt64, requestID: UUID) { self.instanceID = instanceID; self.epoch = epoch; self.requestID = requestID }
    public var description: String { "AutomationSessionTicket(redacted)" }
    public var debugDescription: String { description }
}
public struct AutomationSessionCleanupTicket: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let instanceID: UUID
    public let epoch: UInt64
    public init(instanceID: UUID, epoch: UInt64) { self.instanceID = instanceID; self.epoch = epoch }
    public var description: String { "AutomationSessionCleanupTicket(redacted)" }
    public var debugDescription: String { description }
}
public enum AutomationSessionEffect: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case reply(AutomationReply)
    case completion(AutomationSessionTicket, AutomationReply)
    case awaitCleanup(AutomationSessionTicket)
    case dispatch(AutomationSessionTicket, AutomationRequest)
    case destroyOwnedTarget(AutomationTargetIdentity, AutomationCloseReason, AutomationSessionCleanupTicket)
    public var description: String { "AutomationSessionEffect(redacted)" }
    public var debugDescription: String { description }
}
public enum AutomationSessionEvent: Sendable {
    case permissionRevoked, channelClosed, runnerExited, targetChanged, blocked, schedulingFailed
    case geometryChanged(target: AutomationTargetIdentity, viewport: AutomationViewport)
    case cleanupFinished(ticket: AutomationSessionCleanupTicket, receipt: CleanupReceipt)
}

/// Not Sendable: every method must be called by the same serial owner.
public final class AutomationSessionMachine: CustomStringConvertible, CustomDebugStringConvertible {
    public private(set) var state: AutomationSessionState = .opening
    public private(set) var controlReleaseCommitted = false
    public var description: String { "AutomationSessionMachine(redacted)" }
    public var debugDescription: String { description }
    public func acceptsSessionID(_ value: String?) -> Bool {
        guard !controlReleaseCommitted, let value, AutomationSessionToken.isCanonical(value) else { return false }
        return value.utf8.elementsEqual(token.utf8)
    }
    public var isRegisteredInteractive: Bool { registeredInteractive }
    public var boundTarget: AutomationTargetIdentity? { target }
    public var boundViewport: AutomationViewport? { viewport }
    public var currentTicket: AutomationSessionTicket? { flight?.ticket }
    public func synchronizeViewport(target observed: AutomationTargetIdentity, viewport view: AutomationViewport) -> Bool {
        guard observed == target, state == .ready, flight == nil else { return false }
        if releasePreparation != nil { return true }
        if registeredInteractive {
            guard viewportValid(view, target: observed) else { return false }
            viewport = view
            return true
        }
        guard
              let old = viewport, view.viewVersion >= old.viewVersion,
              viewportValid(view, target: observed),
              view.viewportWidthPoints == old.viewportWidthPoints, view.viewportHeightPoints == old.viewportHeightPoints,
              view.pixelWidth == old.pixelWidth, view.pixelHeight == old.pixelHeight,
              view.scaleX == old.scaleX, view.scaleY == old.scaleY, view.pageZoom == old.pageZoom else { return false }
        viewport = view
        return true
    }
    public var currentCleanupTicket: AutomationSessionCleanupTicket? { cleanupTicket }
    public var nextDeadline: Double? {
        switch state {
        case .closed, .released: return nil
        case .stopping: return cleanupDeadline
        default: return [registeredInteractive ? nil : idleDeadline, holdDeadline, flight?.deadline, releaseDeadline].compactMap { $0 }.min()
        }
    }
    private struct Flight {
        let ticket: AutomationSessionTicket
        let request: AutomationRequest
        let deadline: Double
        let previousViewport: AutomationViewport
    }
    private let instanceID = UUID()
    private let registeredInteractive: Bool
    private let profileID: UUID
    private let token: String
    private var target: AutomationTargetIdentity?
    private var viewport: AutomationViewport?
    private var epoch: UInt64 = 0
    private var flight: Flight?
    private var replay: AutomationReplayCache?
    // Active request IDs are retained only to prevent terminal ID collisions.
    // Terminal metadata stores only close/cancel kind, never arbitrary payloads.
    private var knownIDs = Set<UUID>()
    private var terminalCloseKinds: [UUID: Bool] = [:]
    private var idleDeadline: Double
    private var holdDeadline: Double?
    private var cleanupDeadline: Double?
    private var cleanupTicket: AutomationSessionCleanupTicket?
    private var lastTime: Double
    private var closeRequest: AutomationRequest?
    private var closeTicket: AutomationSessionTicket?
    private var closeReserved = false
    private var closeReceipt = CleanupReceipt(cleaned: false, terminatedOwnedRunner: false)
    private var releasePreparation: ControlReleasePreparation?
    private var releaseDeadline: Double?

    private init(profileID: UUID, token: String, at now: Double, registeredInteractive: Bool) {
        self.registeredInteractive = registeredInteractive
        self.profileID = profileID; self.token = token; self.lastTime = now
        self.idleDeadline = now + AutomationLimits.idleSeconds
        self.replay = AutomationReplayCache(startedAt: now, expiresWhenIdle: !registeredInteractive)
    }
    public static func open(profileID: UUID, allowsBackgroundAutomation: Bool, humanProfileRunning: Bool, token: String, at now: Double, registeredInteractive: Bool = false) -> Result<AutomationSessionMachine, AutomationError> {
        guard allowsBackgroundAutomation else { return .failure(AutomationError(code: .profileNotAllowed)) }
        guard !humanProfileRunning else { return .failure(AutomationError(code: .profileAlreadyRunning)) }
        guard AutomationSessionToken.isCanonical(token), now.isFinite, (now + AutomationLimits.idleSeconds).isFinite else { return .failure(AutomationError(code: .invalidRequest)) }
        return .success(AutomationSessionMachine(profileID: profileID, token: token, at: now, registeredInteractive: registeredInteractive))
    }
    private func reply(_ request: AutomationRequest, _ code: AutomationErrorCode, effects: AutomationSideEffects = .none) -> AutomationSessionEffect {
        .reply(AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: code, sideEffects: effects))))
    }
    private func viewportValid(_ view: AutomationViewport, target: AutomationTargetIdentity) -> Bool {
        let reply = AutomationReply(requestID: UUID(), outcome: .success(.sessionOpened(sessionID: token, target: target, viewport: view)))
        return (try? AutomationCodec.encode(reply)) != nil
    }
    public func bind(target: AutomationTargetIdentity, viewport: AutomationViewport, at now: Double) -> [AutomationSessionEffect] {
        let effects = tick(at: now)
        guard effects.isEmpty, state == .opening else { return effects }
        guard target.profileID == profileID, viewportValid(viewport, target: target) else { state = .closed; replay = nil; return [] }
        self.target = target; self.viewport = viewport; state = .ready
        return []
    }
    private func replayBegin(_ request: AutomationRequest, at now: Double) -> AutomationReplayCache.Begin {
        replay?.begin(request, at: now) ?? .rejected(.sessionExpired)
    }
    private func replayComplete(_ request: AutomationRequest, reply: AutomationReply, at now: Double) -> Bool {
        replay?.complete(request, reply: reply, at: now) ?? false
    }
    private func replayRenew(at now: Double) -> Bool {
        replay?.renew(at: now) ?? false
    }
    private func bumpEpoch() { if epoch < UInt64.max { epoch += 1 } }
    private func stop(_ reason: AutomationCloseReason, at now: Double) -> [AutomationSessionEffect] {
        guard state != .closed && state != .released && state != .stopping else { return [] }
        bumpEpoch(); var effects: [AutomationSessionEffect] = []
        if let f = flight {
            let failure = AutomationReply(requestID: f.request.requestID, outcome: .failure(AutomationError(code: .indeterminateResult, sideEffects: f.request.action.isReadOnly ? .none : .possible)))
            _ = replayComplete(f.request, reply: failure, at: now)
            effects.append(.completion(f.ticket, failure)); flight = nil
        }
        holdDeadline = nil; state = .stopping
        if now.isFinite && (now + AutomationLimits.cleanupSeconds).isFinite { cleanupDeadline = now + AutomationLimits.cleanupSeconds } else { cleanupDeadline = nil }
        if let target {
            let ticket = AutomationSessionCleanupTicket(instanceID: instanceID, epoch: epoch)
            cleanupTicket = ticket
            effects.append(.destroyOwnedTarget(target, reason, ticket))
        }
        else { effects += finalizeCleanup(closeReceipt, at: now) }
        if cleanupDeadline == nil && state == .stopping { effects += finalizeCleanup(closeReceipt, at: now) }
        return effects
    }
    private func finalizeCleanup(_ receipt: CleanupReceipt, at now: Double) -> [AutomationSessionEffect] {
        guard state == .stopping else { return [] }
        closeReceipt = receipt; state = .closed; cleanupDeadline = nil; cleanupTicket = nil
        guard let request = closeRequest else { replay = nil; return [] }
        let result = AutomationReply(requestID: request.requestID, outcome: .success(.sessionClosed(receipt)))
        if closeReserved { _ = replayComplete(request, reply: result, at: now) }
        terminalCloseKinds[request.requestID] = request.action == .cancel
        replay = nil
        closeRequest = nil; closeReserved = false
        guard let ticket = closeTicket else { return [] }
        closeTicket = nil
        return [.completion(ticket, result)]
    }
    public func tick(at now: Double) -> [AutomationSessionEffect] {
        if state == .released { return [] }
        if !now.isFinite || now < lastTime {
            if state == .stopping { return finalizeCleanup(closeReceipt, at: now) }
            var effects = stop(.expired, at: now)
            if state == .stopping { effects += finalizeCleanup(closeReceipt, at: now) }
            return effects
        }
        lastTime = now
        if state == .stopping, let deadline = cleanupDeadline, now >= deadline { return finalizeCleanup(closeReceipt, at: now) }
        guard state != .closed && state != .released && state != .stopping else { return [] }
        if !registeredInteractive && now >= idleDeadline { return stop(.expired, at: now) }
        if let deadline = holdDeadline, now >= deadline { return stop(.heldDeadline, at: now) }
        if let deadline = releaseDeadline, now >= deadline { return stop(.expired, at: now) }
        if let f = flight, now >= f.deadline {
            if registeredInteractive && f.request.action.isReadOnly {
                let reply = AutomationReply(requestID: f.request.requestID, outcome: .failure(AutomationError(code: .timeout)))
                flight = nil
                _ = replayComplete(f.request, reply: reply, at: now)
                return [.completion(f.ticket, reply)]
            }
            return stop(.expired, at: now)
        }
        return []
    }
    public func event(_ event: AutomationSessionEvent, at now: Double) -> [AutomationSessionEffect] {
        if state == .released { return [] }
        let expired = tick(at: now)
        if !expired.isEmpty, registeredInteractive, state == .ready || state == .held {
            return expired + self.event(event, at: now)
        }
        if !expired.isEmpty || state == .closed { return expired }
        if state == .stopping {
            if case let .cleanupFinished(ticket, receipt) = event, ticket == cleanupTicket { return finalizeCleanup(receipt, at: now) }
            if case .schedulingFailed = event { return finalizeCleanup(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false), at: now) }
            return []
        }
        switch event {
        case .cleanupFinished: return []
        case .schedulingFailed: return stop(.expired, at: now)
        case .permissionRevoked: return stop(.permissionRevoked, at: now)
        case .channelClosed: return stop(.channelClosed, at: now)
        case .runnerExited: return stop(.runnerExited, at: now)
        case .targetChanged: return stop(.targetChanged, at: now)
        case .blocked:
            if registeredInteractive { return [] }
            if state == .held || flight != nil { return stop(.targetChanged, at: now) }
            if state == .ready { state = .blocked }; return []
        case let .geometryChanged(observed, view):
            if registeredInteractive {
                guard observed == target, viewportValid(view, target: observed) else { return stop(.targetChanged, at: now) }
                // Do not disturb an in-flight receipt; synchronize on the next request.
                if flight == nil { viewport = view }
                return []
            }
            guard observed == target, let current = viewport, viewportValid(view, target: observed), view.viewVersion > current.viewVersion else { return stop(.targetChanged, at: now) }
            if state == .held || flight != nil { return stop(.targetChanged, at: now) }
            viewport = view; return []
        }
    }
    public func begin(_ request: AutomationRequest, permission: Bool, target observed: AutomationTargetIdentity, at now: Double) -> [AutomationSessionEffect] {
        guard let supplied = request.sessionID, AutomationSessionToken.isCanonical(supplied), supplied.utf8.elementsEqual(token.utf8) else { return [reply(request, .sessionNotFound)] }
        if controlReleaseCommitted { return [reply(request, .sessionExpired)] }
        var reusedInFlight = false
        if permission, observed == target, (try? AutomationCodec.encodeRequest(request)) != nil {
            if let closing = closeRequest, closing.requestID == request.requestID, closing.action != request.action {
                reusedInFlight = true
            } else if state != .closed, now.isFinite, now >= lastTime, (registeredInteractive || now < idleDeadline), knownIDs.contains(request.requestID) {
                if case .rejected(.requestIDReused) = replayBegin(request, at: now) { reusedInFlight = true }
            }
        }
        let expired = tick(at: now)
        if !expired.isEmpty {
            if registeredInteractive, state == .ready || state == .held {
                return expired + begin(request, permission: permission, target: observed, at: now)
            }
            return expired + [reply(request, reusedInFlight ? .requestIDReused : .sessionExpired)]
        }
        if state == .closed {
            guard observed == target else { return [reply(request, .targetChanged)] }
            guard (try? AutomationCodec.encodeRequest(request)) != nil else { return [reply(request, .invalidRequest)] }
            switch request.action {
            case .closeSession, .cancel:
                let isCancel = request.action == .cancel
                if let recorded = terminalCloseKinds[request.requestID] {
                    guard recorded == isCancel else { return [reply(request, .requestIDReused)] }
                } else {
                    guard !knownIDs.contains(request.requestID) else { return [reply(request, .requestIDReused)] }
                    guard registeredInteractive || knownIDs.count < AutomationLimits.replayEntries else { return [reply(request, .replayWindowFull)] }
                    knownIDs.insert(request.requestID)
                    terminalCloseKinds[request.requestID] = isCancel
                }
                return [.reply(AutomationReply(requestID: request.requestID, outcome: .success(.sessionClosed(closeReceipt))))]
            default: return [reply(request, .sessionExpired)]
            }
        }
        guard permission else { return stop(.permissionRevoked, at: now) + [reply(request, .profileNotAllowed)] }
        guard observed == target else { return stop(.targetChanged, at: now) + [reply(request, .targetChanged)] }
        guard (try? AutomationCodec.encodeRequest(request)) != nil else { return [reply(request, .invalidRequest)] }
        if state == .stopping { return [reply(request, reusedInFlight ? .requestIDReused : .sessionBusy)] }
        guard state != .opening else { return [reply(request, .sessionBusy)] }
        switch request.action {
        case .capabilities, .openSession: return [reply(request, .invalidRequest)]
        default: break
        }
        if state == .blocked {
            switch request.action { case .getState, .screenshot, .cancel, .closeSession: break; default: return [reply(request, .sessionBlocked)] }
        }
        if knownIDs.contains(request.requestID) {
            switch replayBegin(request, at: now) {
            case .inFlight: return [reply(request, .sessionBusy)]
            case .replay(let cached):
                guard replayRenew(at: now) else { return stop(.expired, at: now) + [reply(request, .sessionExpired)] }
                idleDeadline = now + AutomationLimits.idleSeconds; return [.reply(cached)]
            case .rejected(let code): return [reply(request, code)]
            case .reserved: return [reply(request, .indeterminateResult)]
            }
        }
        if let preparation = releasePreparation {
            switch request.action {
            case .commitControlRelease(let transferID) where transferID == preparation.transferID: break
            case .cancel, .closeSession: break
            default: return [reply(request, .sessionBusy)]
            }
        } else if case .commitControlRelease = request.action { return [reply(request, .invalidRequest)] }
        switch request.action {
        case .cancel, .closeSession:
            switch replayBegin(request, at: now) {
            case .reserved: knownIDs.insert(request.requestID); closeReserved = true
            case .rejected(.replayWindowFull): closeReserved = false // cleanup must not be blocked by a full replay window
            case .rejected(let code): return [reply(request, code)]
            default: return [reply(request, .sessionBusy)]
            }
            closeRequest = request
            let nextEpoch = epoch == UInt64.max ? epoch : epoch + 1
            let waiting = AutomationSessionTicket(instanceID: instanceID, epoch: nextEpoch, requestID: request.requestID)
            closeTicket = waiting
            return [.awaitCleanup(waiting)] + stop(request.action == .cancel ? .cancelled : .requested, at: now)
        default: break
        }
        guard flight == nil else { return [reply(request, .sessionBusy)] }
        guard let view = viewport else { return [reply(request, .targetChanged)] }
        if !registeredInteractive, let expected = request.expectedViewVersion, expected != view.viewVersion { return [reply(request, .targetChanged)] }
        switch request.action {
        case .releaseControl: if state != .ready && !(registeredInteractive && state == .held) { return [reply(request, .invalidPointerState)] }
        case .commitControlRelease: if state != .ready { return [reply(request, .invalidPointerState)] }
        case .mouseDown: if state == .held { return [reply(request, .invalidPointerState)] }
        case .mouseUp: if state != .held { return [reply(request, .invalidPointerState)] }
        case .selectFiles:
            guard registeredInteractive else { return [reply(request, .fileDialogUnsupported)] }
            if state == .held { return [reply(request, .invalidPointerState)] }
        case .click: if state == .held { return [reply(request, .invalidPointerState)] }
        case .navigate, .navigateByInput: if state == .held { return (registeredInteractive ? [] : stop(.targetChanged, at: now)) + [reply(request, .invalidPointerState)] }
        default: break
        }
        let pointVersion: (ViewportPoint, UInt64)?
        switch request.action {
        case let .move(p,v), let .mouseDown(p,v), let .mouseUp(p,v), let .click(p,v,_), let .scroll(p,v,_,_): pointVersion = (p,v)
        case let .navigateByInput(.click(point: p), v): pointVersion = (p,v)
        default: pointVersion = nil
        }
        if let (point, version) = pointVersion {
            guard registeredInteractive || version == view.viewVersion else { return [reply(request, .targetChanged)] }
            guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0, point.x < view.viewportWidthPoints, point.y < view.viewportHeightPoints else { return [reply(request, .outOfBounds)] }
        }
        if case let .navigateByInput(.enter, version) = request.action, !registeredInteractive, version != view.viewVersion { return [reply(request, .targetChanged)] }
        if !registeredInteractive, request.action.isNavigation, view.viewVersion == UInt64.max { return stop(.targetChanged, at: now) + [reply(request, .targetChanged)] }
        guard epoch < UInt64.max else { return stop(.expired, at: now) + [reply(request, .sessionExpired)] }
        switch replayBegin(request, at: now) {
        case .reserved: knownIDs.insert(request.requestID)
        case .rejected(let code): return [reply(request, code)]
        default: return [reply(request, .sessionBusy)]
        }
        guard replayRenew(at: now), (now + AutomationLimits.idleSeconds).isFinite else { return stop(.expired, at: now) + [reply(request, .sessionExpired)] }
        idleDeadline = now + AutomationLimits.idleSeconds
        if !registeredInteractive && request.action.isNavigation {
            viewport = AutomationViewport(viewportWidthPoints: view.viewportWidthPoints, viewportHeightPoints: view.viewportHeightPoints, pixelWidth: view.pixelWidth, pixelHeight: view.pixelHeight, scaleX: view.scaleX, scaleY: view.scaleY, pageZoom: view.pageZoom, viewVersion: view.viewVersion + 1)
        }
        if case .mouseDown = request.action, !registeredInteractive { holdDeadline = now + AutomationLimits.heldSeconds }
        bumpEpoch(); let ticket = AutomationSessionTicket(instanceID: instanceID, epoch: epoch, requestID: request.requestID)
        let duration = request.action.isNavigation ? AutomationLimits.navigationSeconds : AutomationLimits.actionSeconds
        if case .releaseControl = request.action {
            releaseDeadline = now + (registeredInteractive ? AutomationLimits.releaseHandshakeSeconds : AutomationLimits.actionSeconds)
        }
        // Preparing and committing are separate actions. Keep a bounded handshake
        // between them without spending the commit's entire budget on preparation.
        let deadline = min(releaseDeadline ?? .infinity, now + duration)
        flight = Flight(ticket: ticket, request: request, deadline: deadline, previousViewport: view)
        return [.dispatch(ticket, request)]
    }
    public func complete(ticket: AutomationSessionTicket, reply response: AutomationReply, at now: Double) -> [AutomationSessionEffect] {
        let expired = tick(at: now); if !expired.isEmpty || state == .closed || state == .stopping { return expired }
        guard let current = flight, current.ticket == ticket, ticket.epoch == epoch else { return [] }
        let request = current.request
        let validated = response.requestID == request.requestID && (try? AutomationCodec.encode(response)) != nil && validOutcome(response.outcome, action: request.action)
        guard validated else {
            return stop(.targetChanged, at: now)
        }
        if !registeredInteractive, case .failure(let failure) = response.outcome, !request.action.isReadOnly, failure.sideEffects != .none {
            return stop(.targetChanged, at: now)
        }
        // Navigation reserves its next viewport at dispatch. A known pre-dispatch
        // busy rejection has not consumed that version and remains retryable.
        if request.action.isNavigation, case .failure(let failure) = response.outcome,
           (failure.code == .sessionBusy || failure.code == .targetChanged), failure.sideEffects == .none {
            viewport = current.previousViewport
        }
        flight = nil
        if case .success = response.outcome {
            switch request.action { case .mouseDown: state = .held; case .mouseUp: state = .ready; holdDeadline = nil; default: break }
        } else if case .mouseDown = request.action { holdDeadline = nil }
        guard replayComplete(request, reply: response, at: now) else {
            let failure = AutomationReply(requestID: request.requestID, outcome: .failure(AutomationError(code: .indeterminateResult, sideEffects: request.action.isReadOnly ? .none : .possible)))
            return stop(.expired, at: now) + [.completion(ticket, failure)]
        }
        if case .success(let result) = response.outcome {
            switch result {
            case .controlReleasePrepared(let preparation):
                releasePreparation = preparation
                if registeredInteractive { state = .ready; holdDeadline = nil }
            case .controlReleased:
                controlReleaseCommitted = true; state = .released; releasePreparation = nil; releaseDeadline = nil; replay = nil
            default: break
            }
        } else if registeredInteractive, case .failure(let error) = response.outcome, error.sideEffects == .none,
                  error.code == .sessionBusy || error.code == .invalidPointerState {
            // A rejected preparation did not start a handshake. A rejected commit
            // retains its exact preparation so the next explicit call can finish it.
            if case .releaseControl = request.action { releaseDeadline = nil }
        } else if case .releaseControl = request.action { return stop(.targetChanged, at: now) + [.completion(ticket, response)] }
        else if case .commitControlRelease = request.action { return stop(.targetChanged, at: now) + [.completion(ticket, response)] }
        return [.completion(ticket, response)]
    }
    private func validOutcome(_ outcome: AutomationOutcome, action: AutomationAction) -> Bool {
        if case .failure = outcome { return true }
        guard case .success(let value) = outcome else { return false }
        switch (action, value) {
        case let (.releaseControl, .controlReleasePrepared(value)):
            return value.target == target && value.inputReleased && value.artifactsCleaned && value.browserRetained
        case let (.commitControlRelease(transferID), .controlReleased(value)):
            return releasePreparation?.transferID == transferID && value.transferID == transferID && value.target == target && value.inputReleased && value.artifactsCleaned && value.browserRetained && value.manualInteractionEnabled
        case let (.getState, .stateRead(value)): return value.target == target && (registeredInteractive || value.viewVersion == viewport?.viewVersion) && value.sessionState == state
        case let (.screenshot, .snapshotWritten(_, value)): return registeredInteractive || value == viewport
        case let (.navigate, .navigationSubmitted(v)), let (.navigate, .navigationFinished(v)), let (.navigateByInput, .navigationFinished(v)): return registeredInteractive || v == viewport?.viewVersion
        case (.navigateByInput, .nativeDelivered): return registeredInteractive
        case let (.selectFiles(paths), .filesSelected(count)): return registeredInteractive && count == paths.count
        case let (.mouseDown, .nativeDelivered(_, buttons, v)): return buttons == 1 && (registeredInteractive || v == viewport?.viewVersion)
        case let (.mouseUp, .nativeDelivered(_, buttons, v)): return buttons == 0 && (registeredInteractive || v == viewport?.viewVersion)
        case let (.move, .nativeDelivered(_, buttons, v)), let (.scroll, .nativeDelivered(_, buttons, v)), let (.insertText, .nativeDelivered(_, buttons, v)), let (.key, .nativeDelivered(_, buttons, v)):
            return buttons == (state == .held ? 1 : 0) && (registeredInteractive || v == viewport?.viewVersion)
        case let (.click, .nativeDelivered(_, buttons, v)): return buttons == 0 && (registeredInteractive || v == viewport?.viewVersion)
        default: return false
        }
    }
}
