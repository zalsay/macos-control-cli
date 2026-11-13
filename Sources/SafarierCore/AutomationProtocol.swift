import Foundation
import CoreFoundation
import Security

public enum AutomationLimits {
    public static let frameBytes = 65_536, textBytes = 16_384, replayEntries = 256
    public static let startupSeconds = 60.0, navigationSeconds = 60.0
    public static let actionSeconds = 10.0, idleSeconds = 60.0, heldSeconds = 10.0, cleanupSeconds = 4.0
    public static let frameSeconds = 6.0, generationSeconds = 90.0
    public static let screenshotMaxEdge = 4_096, screenshotMaxBytes = 33_554_432, screenshotCount = 8
}
public struct ViewportPoint: Equatable, Sendable {
    public let x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public enum AutomationKey: String, Codable, Sendable {
    case backspace = "Backspace", delete = "Delete", enter = "Enter", tab = "Tab", escape = "Escape"
    case left = "Left", right = "Right", up = "Up", down = "Down", home = "Home", end = "End"
}
public enum AutomationNavigationInput: Equatable, Sendable {
    case enter
    case click(point: ViewportPoint)
}
public enum AutomationAction: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case launchInteractive(profileID: UUID, url: URL?, spi: String?)
    case capabilities, openSession(profileID: UUID), getState, navigate(url: URL), screenshot
    case navigateByInput(input: AutomationNavigationInput, viewVersion: UInt64)
    case move(point: ViewportPoint, viewVersion: UInt64), mouseDown(point: ViewportPoint, viewVersion: UInt64), mouseUp(point: ViewportPoint, viewVersion: UInt64)
    case click(point: ViewportPoint, viewVersion: UInt64, count: Int)
    case scroll(point: ViewportPoint, viewVersion: UInt64, deltaX: Double, deltaY: Double)
    case insertText(String), key(name: AutomationKey, shift: Bool), cancel, closeSession, releaseControl
    case commitControlRelease(transferID: UUID)
    public var description: String { "AutomationAction(redacted)" }
    public var debugDescription: String { description }
    public var isNavigation: Bool {
        switch self { case .navigate, .navigateByInput: return true; default: return false }
    }
}
public struct AutomationRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let version: Int, requestID: UUID
    public let sessionID: String?, action: AutomationAction
    public init(version: Int, requestID: UUID, sessionID: String?, action: AutomationAction) { self.version = version; self.requestID = requestID; self.sessionID = sessionID; self.action = action }
    public var description: String { "AutomationRequest(redacted)" }
    public var debugDescription: String { description }
}
public enum AutomationErrorCode: String, Codable, Sendable {
    case invalidRequest = "INVALID_REQUEST", unsupportedProtocol = "UNSUPPORTED_PROTOCOL", unauthorized = "UNAUTHORIZED", profileNotAllowed = "PROFILE_NOT_ALLOWED", profileAlreadyRunning = "PROFILE_ALREADY_RUNNING", sessionNotFound = "SESSION_NOT_FOUND", sessionExpired = "SESSION_EXPIRED", sessionBusy = "SESSION_BUSY", sessionBlocked = "SESSION_BLOCKED", requestIDReused = "REQUEST_ID_REUSED", replayWindowFull = "REPLAY_WINDOW_FULL", backendUnavailable = "BACKEND_UNAVAILABLE", backgroundLaunchUnverified = "BACKGROUND_LAUNCH_UNVERIFIED", uiPolicyUnavailable = "UI_POLICY_UNAVAILABLE", interactionRequired = "INTERACTION_REQUIRED", targetChanged = "TARGET_CHANGED", invalidPointerState = "INVALID_POINTER_STATE", outOfBounds = "OUT_OF_BOUNDS", timeout = "TIMEOUT", cancelled = "CANCELLED", runnerExited = "RUNNER_EXITED", indeterminateResult = "INDETERMINATE_RESULT"
}
public enum AutomationSideEffects: String, Codable, Sendable { case none, possible, delivered }
public struct AutomationError: Error, Codable, Equatable, Sendable {
    public let code: AutomationErrorCode, retryable: Bool, sideEffects: AutomationSideEffects
    public init(code: AutomationErrorCode, retryable: Bool = false, sideEffects: AutomationSideEffects = .none) { self.code = code; self.retryable = retryable; self.sideEffects = sideEffects }
}
public enum AutomationCloseReason: String, Codable, Sendable { case requested, cancelled, expired, heldDeadline, channelClosed, targetChanged, permissionRevoked, runnerExited }
public struct RetainedBrowserCleanup: Codable, Equatable, Sendable {
    public let target: AutomationTargetIdentity
    public let inputReleased, artifactsCleaned, browserRetained, manualInteractionEnabled: Bool
    public init(target: AutomationTargetIdentity, inputReleased: Bool, artifactsCleaned: Bool, browserRetained: Bool, manualInteractionEnabled: Bool) {
        self.target = target; self.inputReleased = inputReleased; self.artifactsCleaned = artifactsCleaned
        self.browserRetained = browserRetained; self.manualInteractionEnabled = manualInteractionEnabled
    }
    public var confirmed: Bool { inputReleased && artifactsCleaned && browserRetained && manualInteractionEnabled }
}
public struct CleanupReceipt: Codable, Equatable, Sendable {
    public let cleaned: Bool, terminatedOwnedRunner: Bool
    public let retainedBrowser: RetainedBrowserCleanup?
    public init(cleaned: Bool, terminatedOwnedRunner: Bool, retainedBrowser: RetainedBrowserCleanup? = nil) {
        self.cleaned = cleaned; self.terminatedOwnedRunner = terminatedOwnedRunner; self.retainedBrowser = retainedBrowser
    }
}
public struct AutomationTargetIdentity: Codable, Equatable, Sendable {
    public let profileID: UUID, runnerInstanceID: UUID, windowID: UUID, pageID: UUID
    public init(profileID: UUID, runnerInstanceID: UUID, windowID: UUID, pageID: UUID) { self.profileID = profileID; self.runnerInstanceID = runnerInstanceID; self.windowID = windowID; self.pageID = pageID }
}
public struct ControlReleasePreparation: Codable, Equatable, Sendable {
    public let target: AutomationTargetIdentity
    public let transferID: UUID
    public let inputReleased, artifactsCleaned, browserRetained: Bool
    public init(target: AutomationTargetIdentity, transferID: UUID, inputReleased: Bool, artifactsCleaned: Bool, browserRetained: Bool) {
        self.target = target; self.transferID = transferID; self.inputReleased = inputReleased; self.artifactsCleaned = artifactsCleaned; self.browserRetained = browserRetained
    }
}
public struct ControlReleaseReceipt: Codable, Equatable, Sendable {
    public let target: AutomationTargetIdentity
    public let transferID: UUID
    public let inputReleased, artifactsCleaned, browserRetained, manualInteractionEnabled: Bool
    public init(target: AutomationTargetIdentity, transferID: UUID, inputReleased: Bool, artifactsCleaned: Bool, browserRetained: Bool, manualInteractionEnabled: Bool) {
        self.target = target; self.transferID = transferID; self.inputReleased = inputReleased; self.artifactsCleaned = artifactsCleaned; self.browserRetained = browserRetained; self.manualInteractionEnabled = manualInteractionEnabled
    }
}
public struct AutomationViewport: Codable, Equatable, Sendable {
    public let viewportWidthPoints: Double, viewportHeightPoints: Double, pixelWidth: Int, pixelHeight: Int, scaleX: Double, scaleY: Double, pageZoom: Double, viewVersion: UInt64
    public init(viewportWidthPoints: Double, viewportHeightPoints: Double, pixelWidth: Int, pixelHeight: Int, scaleX: Double, scaleY: Double, pageZoom: Double, viewVersion: UInt64) { self.viewportWidthPoints = viewportWidthPoints; self.viewportHeightPoints = viewportHeightPoints; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.scaleX = scaleX; self.scaleY = scaleY; self.pageZoom = pageZoom; self.viewVersion = viewVersion }
    public func contains(_ point: ViewportPoint) -> Bool {
        viewportWidthPoints.isFinite && viewportHeightPoints.isFinite && viewportWidthPoints > 0 && viewportHeightPoints > 0 && point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 && point.x < viewportWidthPoints && point.y < viewportHeightPoints
    }
}
public enum AutomationCapabilityStatus: String, Codable, Sendable { case active, unavailable, unverified }
public struct AutomationCapabilities: Codable, Equatable, Sendable {
    public let backend: AutomationCapabilityStatus, uiPolicy: AutomationCapabilityStatus, coldLaunch: AutomationCapabilityStatus
    public let version: String, role: String, managerPID: Int
    public init(backend: AutomationCapabilityStatus, uiPolicy: AutomationCapabilityStatus, coldLaunch: AutomationCapabilityStatus, version: String, role: String, managerPID: Int) { self.backend = backend; self.uiPolicy = uiPolicy; self.coldLaunch = coldLaunch; self.version = version; self.role = role; self.managerPID = managerPID }
}
public enum AutomationSessionState: String, Codable, Sendable { case opening, ready, held, blocked, stopping, closed, released }
public struct AutomationState: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "AutomationState(redacted)" }; public var debugDescription: String { description }
    public let target: AutomationTargetIdentity, url: URL?, loading: Bool, sessionState: AutomationSessionState, viewVersion: UInt64
    public init(target: AutomationTargetIdentity, url: URL?, loading: Bool, sessionState: AutomationSessionState, viewVersion: UInt64) { self.target = target; self.url = url; self.loading = loading; self.sessionState = sessionState; self.viewVersion = viewVersion }
}
public enum AutomationResult: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "AutomationResult(redacted)" }; public var debugDescription: String { description }
    case sessionOpened(sessionID: String, target: AutomationTargetIdentity, viewport: AutomationViewport)
    case interactiveLaunched(profileID: UUID)
    case nativeDelivered(sequence: UInt64, buttons: Int, viewVersion: UInt64)
    case navigationFinished(viewVersion: UInt64)
    case snapshotWritten(path: String, viewport: AutomationViewport)
    case capabilities(AutomationCapabilities), stateRead(AutomationState), sessionClosed(CleanupReceipt)
    case controlReleasePrepared(ControlReleasePreparation), controlReleased(ControlReleaseReceipt)
}
public enum AutomationOutcome: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case success(AutomationResult), failure(AutomationError)
    public var description: String { "AutomationOutcome(redacted)" }; public var debugDescription: String { description }
}
public struct AutomationReply: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let requestID: UUID?, outcome: AutomationOutcome
    public init(requestID: UUID?, outcome: AutomationOutcome) { self.requestID = requestID; self.outcome = outcome }
    public var description: String { "AutomationReply(redacted)" }; public var debugDescription: String { description }
}
public enum AutomationSessionToken {
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AutomationError(code: .backendUnavailable) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func isCanonical(_ token: String) -> Bool {
        guard token.utf8.count == 43, token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), let d = Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), d.count == 32 else { return false }
        return d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == token
    }
}

// A structural preflight: JSONSerialization validates grammar; this pass also detects
// escaped duplicate object keys before Foundation can discard them.
private struct JSONKeyScanner {
    let bytes: [UInt8]
    var index = 0
    mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func string() throws -> String {
        let start = index
        guard index < bytes.count, bytes[index] == 34 else { throw AutomationError(code: .invalidRequest) }
        index += 1
        while index < bytes.count {
            let c = bytes[index]; index += 1
            if c == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if c == 92 { guard index < bytes.count else { throw AutomationError(code: .invalidRequest) }; index += 1 }
        }
        throw AutomationError(code: .invalidRequest)
    }
    mutating func value(_ depth: Int) throws {
        guard depth <= 32 else { throw AutomationError(code: .invalidRequest) }
        space(); guard index < bytes.count else { throw AutomationError(code: .invalidRequest) }
        switch bytes[index] {
        case 123:
            index += 1; space(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                space(); let key = try string(); guard keys.insert(key).inserted else { throw AutomationError(code: .invalidRequest) }
                space(); guard index < bytes.count && bytes[index] == 58 else { throw AutomationError(code: .invalidRequest) }; index += 1
                try value(depth + 1); space(); guard index < bytes.count else { throw AutomationError(code: .invalidRequest) }
                let c = bytes[index]; index += 1; if c == 125 { return }; guard c == 44 else { throw AutomationError(code: .invalidRequest) }
            }
        case 91:
            index += 1; space(); if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true { try value(depth + 1); space(); guard index < bytes.count else { throw AutomationError(code: .invalidRequest) }; let c = bytes[index]; index += 1; if c == 93 { return }; guard c == 44 else { throw AutomationError(code: .invalidRequest) } }
        case 34: _ = try string()
        default:
            let start = index; while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }; guard index > start else { throw AutomationError(code: .invalidRequest) }
        }
    }
}
internal enum AutomationJSONBoundary {
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= AutomationLimits.frameBytes, String(data: data, encoding: .utf8) != nil else { throw AutomationError(code: .invalidRequest) }
        var scanner = JSONKeyScanner(bytes: Array(data))
        try scanner.value(0); scanner.space()
        guard scanner.index == data.count, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AutomationError(code: .invalidRequest) }
        return object
    }
    static func exact(_ object: [String: Any], _ required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw AutomationError(code: .invalidRequest) }
    }
    static func integer(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return UInt64(n.stringValue)
    }
}
public enum AutomationCodec {
    public static func decode(_ data: Data) throws -> AutomationRequest {
        do { return try decodeChecked(data) } catch let e as AutomationError { throw e } catch { throw AutomationError(code: .invalidRequest) }
    }
    private static func decodeChecked(_ data: Data) throws -> AutomationRequest {
        let bad = AutomationError(code: .invalidRequest)
        let root = try AutomationJSONBoundary.object(data)
        guard Set(root.keys).isSubset(of: ["version","requestID","sessionID","action","parameters"]), let version = integer(root["version"]), let idString = root["requestID"] as? String, let id = UUID(uuidString: idString), let name = root["action"] as? String, let p = root["parameters"] as? [String: Any] else { throw bad }
        guard version == 1 else { throw AutomationError(code: .unsupportedProtocol) }
        let session: String?
        if root.keys.contains("sessionID") { guard let s = root["sessionID"] as? String, AutomationSessionToken.isCanonical(s) else { throw bad }; session = s } else { session = nil }
        guard (name == "capabilities" || name == "openSession" || name == "launchInteractive") == (session == nil) else { throw bad }
        func keys(_ expected: Set<String>) throws { guard Set(p.keys) == expected else { throw bad } }
        func point() throws -> (ViewportPoint, UInt64) {
            guard let x = number(p["x"]), let y = number(p["y"]), let v = integer(p["viewVersion"]) else { throw bad }
            return (ViewportPoint(x: x, y: y), v)
        }
        let action: AutomationAction
        switch name {
        case "capabilities": try keys([]); action = .capabilities
        case "openSession": try keys(["profileID"]); guard let s = p["profileID"] as? String, let id = UUID(uuidString: s) else { throw bad }; action = .openSession(profileID: id)
        case "launchInteractive":
            guard Set(p.keys).isSubset(of: ["profileID", "url", "spi"]), let s = p["profileID"] as? String, let id = UUID(uuidString: s) else { throw bad }
            let url: URL?
            if let value = p["url"] { guard let text = value as? String, let parsed = URL(string: text), parsed.scheme != nil else { throw bad }; url = parsed } else { url = nil }
            let spi: String?
            if let value = p["spi"] { guard let text = value as? String, let parsed = try? SPIFeatures(parsing: text), parsed.description == text else { throw bad }; spi = text } else { spi = nil }
            action = .launchInteractive(profileID: id, url: url, spi: spi)
        case "getState": try keys([]); action = .getState
        case "screenshot": try keys([]); action = .screenshot
        case "cancel": try keys([]); action = .cancel
        case "closeSession": try keys([]); action = .closeSession
        case "releaseControl": try keys([]); action = .releaseControl
        case "commitControlRelease": try keys(["transferID"]); guard let s = p["transferID"] as? String, let id = UUID(uuidString: s) else { throw bad }; action = .commitControlRelease(transferID: id)
        case "navigate":
            try keys(["url"]); guard let s = p["url"] as? String, let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http","https"].contains(scheme), let host = u.host, !host.isEmpty, host != ".", host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { throw bad }; action = .navigate(url: u)
        case "navigateByInput":
            guard let input = p["input"] as? String else { throw bad }
            switch input {
            case "Enter":
                try keys(["input", "viewVersion"])
                guard let version = integer(p["viewVersion"]) else { throw bad }
                action = .navigateByInput(input: .enter, viewVersion: version)
            case "click":
                try keys(["input", "x", "y", "viewVersion"])
                let (position, version) = try point()
                action = .navigateByInput(input: .click(point: position), viewVersion: version)
            default: throw bad
            }
        case "move", "mouseDown", "mouseUp":
            try keys(["x","y","viewVersion"]); let (pt,v) = try point(); if name == "move" { action = .move(point: pt, viewVersion: v) } else if name == "mouseDown" { action = .mouseDown(point: pt, viewVersion: v) } else { action = .mouseUp(point: pt, viewVersion: v) }
        case "click":
            try keys(["x","y","viewVersion","count"]); let (pt,v) = try point(); guard let n = integer(p["count"]), n == 1 || n == 2 else { throw bad }; action = .click(point: pt, viewVersion: v, count: Int(n))
        case "scroll":
            try keys(["x","y","viewVersion","deltaX","deltaY"]); let (pt,v) = try point(); guard let dx = number(p["deltaX"]), let dy = number(p["deltaY"]), abs(dx) <= 1000, abs(dy) <= 1000 else { throw bad }; action = .scroll(point: pt, viewVersion: v, deltaX: dx, deltaY: dy)
        case "insertText": try keys(["text"]); guard let s = p["text"] as? String, s.utf8.count <= AutomationLimits.textBytes else { throw bad }; action = .insertText(s)
        case "key":
            try keys(["name","shift"]); guard let s = p["name"] as? String, let key = AutomationKey(rawValue: s), let n = p["shift"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw bad }; let shift = n.boolValue; guard !shift || [.tab,.left,.right,.up,.down,.home,.end].contains(key) else { throw bad }; action = .key(name: key, shift: shift)
        default: throw bad
        }
        return AutomationRequest(version: 1, requestID: id, sessionID: session, action: action)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }; return n.doubleValue
    }
    private static func integer(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return UInt64(n.stringValue)
    }
    public static func encodeRequest(_ request: AutomationRequest) throws -> Data {
        do { return try encodeRequestChecked(request) } catch { throw AutomationError(code: .invalidRequest) }
    }
    private static func encodeRequestChecked(_ request: AutomationRequest) throws -> Data {
        var name: String; var params: [String: Any] = [:]
        func point(_ p: ViewportPoint, _ v: UInt64) -> [String: Any] { ["x":p.x,"y":p.y,"viewVersion":v] }
        switch request.action {
        case let .launchInteractive(id, url, spi):
            name = "launchInteractive"; params = ["profileID": id.uuidString]
            if let url { params["url"] = url.absoluteString }
            if let spi { params["spi"] = spi }
        case .capabilities: name = "capabilities"
        case .openSession(let id): name = "openSession"; params = ["profileID":id.uuidString]
        case .getState: name = "getState"
        case .navigate(let url): name = "navigate"; params = ["url":url.absoluteString]
        case let .navigateByInput(input, version):
            name = "navigateByInput"
            switch input {
            case .enter: params = ["input":"Enter", "viewVersion":version]
            case .click(let position): params = point(position, version); params["input"] = "click"
            }
        case .screenshot: name = "screenshot"
        case let .move(p,v): name = "move"; params = point(p,v)
        case let .mouseDown(p,v): name = "mouseDown"; params = point(p,v)
        case let .mouseUp(p,v): name = "mouseUp"; params = point(p,v)
        case let .click(p,v,n): name = "click"; params = point(p,v); params["count"] = n
        case let .scroll(p,v,x,y): name = "scroll"; params = point(p,v); params["deltaX"] = x; params["deltaY"] = y
        case .insertText(let text): name = "insertText"; params = ["text":text]
        case let .key(key,shift): name = "key"; params = ["name":key.rawValue,"shift":shift]
        case .cancel: name = "cancel"
        case .closeSession: name = "closeSession"
        case .releaseControl: name = "releaseControl"
        case .commitControlRelease(let id): name = "commitControlRelease"; params = ["transferID":id.uuidString]
        }
        var root: [String: Any] = ["version":request.version,"requestID":request.requestID.uuidString,"action":name,"parameters":params]
        if let session = request.sessionID { root["sessionID"] = session }
        guard JSONSerialization.isValidJSONObject(root) else { throw AutomationError(code: .invalidRequest) }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        _ = try decode(data)
        return data
    }
    private static func validateViewport(_ viewport: AutomationViewport, screenshot: Bool) throws {
        let dimensions = [viewport.viewportWidthPoints, viewport.viewportHeightPoints, viewport.scaleX, viewport.scaleY, viewport.pageZoom]
        guard dimensions.allSatisfy({ $0.isFinite && $0 > 0 }), viewport.pixelWidth > 0, viewport.pixelHeight > 0,
              !screenshot || (viewport.pixelWidth <= AutomationLimits.screenshotMaxEdge && viewport.pixelHeight <= AutomationLimits.screenshotMaxEdge) else {
            throw AutomationError(code: .invalidRequest)
        }
    }
    private static func validateButtons(_ buttons: Int) throws {
        guard buttons == 0 || buttons == 1 else { throw AutomationError(code: .invalidRequest) }
    }
    public static func decodeReply(_ data: Data) throws -> AutomationReply {
        do { return try decodeReplyChecked(data) } catch let e as AutomationError { throw e } catch { throw AutomationError(code: .invalidRequest) }
    }
    private static func decodeReplyChecked(_ data: Data) throws -> AutomationReply {
        let bad = AutomationError(code: .invalidRequest)
        let root = try AutomationJSONBoundary.object(data)
        guard let v = AutomationJSONBoundary.integer(root["version"]) else { throw bad }
        guard v == 1 else { throw AutomationError(code: .unsupportedProtocol) }
        let id: UUID?
        if root["requestID"] is NSNull { id = nil }
        else if let raw = root["requestID"] as? String, let uuid = UUID(uuidString: raw) { id = uuid }
        else { throw bad }
        guard let status = root["status"] as? String else { throw bad }
        func dict(_ value: Any?) throws -> [String: Any] { guard let d = value as? [String: Any] else { throw bad }; return d }
        func typed<T: Decodable>(_ type: T.Type, _ d: [String: Any]) throws -> T { try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: d)) }
        func target(_ value: Any?) throws { let d = try dict(value); try AutomationJSONBoundary.exact(d, ["profileID","runnerInstanceID","windowID","pageID"]) }
        let viewportKeys: Set<String> = ["viewportWidthPoints","viewportHeightPoints","pixelWidth","pixelHeight","scaleX","scaleY","pageZoom","viewVersion"]
        func viewport(_ value: Any?, screenshot: Bool = false) throws -> AutomationViewport {
            let d = try dict(value); try AutomationJSONBoundary.exact(d, viewportKeys)
            let decoded = try typed(AutomationViewport.self, d)
            try validateViewport(decoded, screenshot: screenshot)
            return decoded
        }
        if status == "error" {
            try AutomationJSONBoundary.exact(root, ["version","requestID","status","error"])
            let d = try dict(root["error"]); try AutomationJSONBoundary.exact(d, ["code","retryable","sideEffects"])
            return AutomationReply(requestID: id, outcome: .failure(try typed(AutomationError.self,d)))
        }
        guard status == "ok", let id, let effect = root["effect"] as? String else { throw bad }
        try AutomationJSONBoundary.exact(root, ["version","requestID","status","effect","result"])
        let result = try dict(root["result"]); let value: AutomationResult
        switch effect {
        case "interactiveLaunched":
            try AutomationJSONBoundary.exact(result, ["profileID"])
            guard let raw = result["profileID"] as? String, let id = UUID(uuidString: raw) else { throw bad }
            value = .interactiveLaunched(profileID: id)
        case "sessionOpened":
            try AutomationJSONBoundary.exact(result, ["sessionID","target","viewport"]); guard let session = result["sessionID"] as? String, AutomationSessionToken.isCanonical(session) else { throw bad }
            try target(result["target"])
            value = .sessionOpened(sessionID: session, target: try typed(AutomationTargetIdentity.self,dict(result["target"])), viewport: try viewport(result["viewport"]))
        case "nativeDelivered":
            try AutomationJSONBoundary.exact(result, ["sequence","buttons","viewVersion"])
            struct Native: Decodable { let sequence: UInt64; let buttons: Int; let viewVersion: UInt64 }
            let n = try typed(Native.self,result); try validateButtons(n.buttons); value = .nativeDelivered(sequence: n.sequence, buttons: n.buttons, viewVersion: n.viewVersion)
        case "navigationFinished":
            try AutomationJSONBoundary.exact(result, ["viewVersion"]); struct Navigation: Decodable { let viewVersion: UInt64 }; value = .navigationFinished(viewVersion: try typed(Navigation.self,result).viewVersion)
        case "snapshotWritten":
            try AutomationJSONBoundary.exact(result, viewportKeys.union(["path"])); guard let path = result["path"] as? String else { throw bad }; var copy = result; copy.removeValue(forKey: "path"); value = .snapshotWritten(path: path, viewport: try viewport(copy, screenshot: true))
        case "stateRead":
            if result.keys.contains("backend") {
                try AutomationJSONBoundary.exact(result, ["backend","uiPolicy","coldLaunch","version","role","managerPID"]); value = .capabilities(try typed(AutomationCapabilities.self,result))
            } else {
                try AutomationJSONBoundary.exact(result, ["target","loading","sessionState","viewVersion"], optional: ["url"]); try target(result["target"]); value = .stateRead(try typed(AutomationState.self,result))
            }
        case "sessionClosed":
            try AutomationJSONBoundary.exact(result, ["cleaned","terminatedOwnedRunner"], optional: ["retainedBrowser"])
            if let raw = result["retainedBrowser"] {
                let retained = try dict(raw)
                try AutomationJSONBoundary.exact(retained, ["target","inputReleased","artifactsCleaned","browserRetained","manualInteractionEnabled"])
                try target(retained["target"])
            }
            let receipt = try typed(CleanupReceipt.self,result)
            guard receipt.retainedBrowser == nil || (!receipt.cleaned && !receipt.terminatedOwnedRunner) else { throw bad }
            value = .sessionClosed(receipt)
        case "controlReleasePrepared":
            try AutomationJSONBoundary.exact(result, ["target","transferID","inputReleased","artifactsCleaned","browserRetained"]); try target(result["target"])
            value = .controlReleasePrepared(try typed(ControlReleasePreparation.self, result))
        case "controlReleased":
            try AutomationJSONBoundary.exact(result, ["target","transferID","inputReleased","artifactsCleaned","browserRetained","manualInteractionEnabled"]); try target(result["target"])
            value = .controlReleased(try typed(ControlReleaseReceipt.self, result))
        default: throw bad
        }
        return AutomationReply(requestID: id, outcome: .success(value))
    }
    public static func encode(_ reply: AutomationReply) throws -> Data {
        do { return try encodeChecked(reply) } catch { throw AutomationError(code: .invalidRequest) }
    }
    private static func encodeChecked(_ reply: AutomationReply) throws -> Data {
        var root: [String: Any] = ["version": 1, "requestID": reply.requestID?.uuidString ?? NSNull()]
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]) }
        switch reply.outcome {
        case .failure(let error): root["status"] = "error"; root["error"] = try object(error)
        case .success(let result):
            guard reply.requestID != nil else { throw AutomationError(code: .invalidRequest) }
            root["status"] = "ok"
            switch result {
            case .interactiveLaunched(let id): root["effect"] = "interactiveLaunched"; root["result"] = ["profileID": id.uuidString]
            case let .sessionOpened(sessionID, target, viewport): guard AutomationSessionToken.isCanonical(sessionID) else { throw AutomationError(code: .invalidRequest) }; try validateViewport(viewport, screenshot: false); root["effect"] = "sessionOpened"; root["result"] = ["sessionID":sessionID,"target":try object(target),"viewport":try object(viewport)]
            case let .nativeDelivered(sequence, buttons, viewVersion): try validateButtons(buttons); root["effect"] = "nativeDelivered"; root["result"] = ["sequence":sequence,"buttons":buttons,"viewVersion":viewVersion]
            case .navigationFinished(let v): root["effect"] = "navigationFinished"; root["result"] = ["viewVersion":v]
            case let .snapshotWritten(path, viewport):
                try validateViewport(viewport, screenshot: true)
                root["effect"] = "snapshotWritten"
                guard var snapshot = try object(viewport) as? [String: Any] else { throw AutomationError(code: .invalidRequest) }
                snapshot["path"] = path; root["result"] = snapshot
            case .capabilities(let value): root["effect"] = "stateRead"; root["result"] = try object(value)
            case .stateRead(let value): root["effect"] = "stateRead"; root["result"] = try object(value)
            case .sessionClosed(let value):
                guard value.retainedBrowser == nil || (!value.cleaned && !value.terminatedOwnedRunner) else { throw AutomationError(code: .invalidRequest) }
                root["effect"] = "sessionClosed"; root["result"] = try object(value)
            case .controlReleasePrepared(let value): root["effect"] = "controlReleasePrepared"; root["result"] = try object(value)
            case .controlReleased(let value): root["effect"] = "controlReleased"; root["result"] = try object(value)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]); guard data.count <= AutomationLimits.frameBytes else { throw AutomationError(code: .invalidRequest) }; return data
    }
}
