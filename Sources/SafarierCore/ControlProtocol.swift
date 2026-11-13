import Foundation
import CoreFoundation

public struct ControlRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let requestID: UUID, operation: ControlOperation
    public init(requestID: UUID, operation: ControlOperation) { self.requestID = requestID; self.operation = operation }
    public var description: String { "ControlRequest(redacted)" }; public var debugDescription: String { description }
}
public struct ControlHello: Equatable, Sendable {
    public let nonce: UUID, instance: UUID
    public init(nonce: UUID, instance: UUID) { self.nonce = nonce; self.instance = instance }
}
public enum ControlProtocol {
    public static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= AutomationLimits.frameBytes else { throw ControlError.frameTooLarge }
        let n = UInt32(payload.count)
        var out = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        out.append(payload); return out
    }
    public static func unframe(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw ControlError.invalidRequest }
        let bytes = [UInt8](data.prefix(4)); let n = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard n > 0, n <= AutomationLimits.frameBytes else { throw ControlError.frameTooLarge }
        guard data.count == Int(n) + 4 else { throw ControlError.invalidRequest }
        return Data(data.dropFirst(4))
    }
    private static func object(_ data: Data) throws -> [String:Any] {
        guard !data.isEmpty, data.count <= AutomationLimits.frameBytes else { throw ControlError.frameTooLarge }
        do { return try AutomationJSONBoundary.object(data) } catch { throw ControlError.invalidRequest }
    }
    private static func encode(_ object: [String:Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw ControlError.invalidRequest }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= AutomationLimits.frameBytes else { throw ControlError.frameTooLarge }; return data
    }
    private static func version(_ root: [String:Any]) throws {
        guard let n = root["version"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.stringValue == "1" else { throw ControlError.unsupportedVersion }
    }
    public static func encodeHello(_ hello: ControlHello) throws -> Data {
        try encode(["version":1,"kind":"hello","nonce":hello.nonce.uuidString,"instance":hello.instance.uuidString])
    }
    public static func decodeHello(_ data: Data) throws -> ControlHello {
        let root = try object(data); try version(root)
        guard Set(root.keys) == ["version","kind","nonce","instance"], root["kind"] as? String == "hello", let nonce = (root["nonce"] as? String).flatMap(UUID.init(uuidString:)), let instance = (root["instance"] as? String).flatMap(UUID.init(uuidString:)) else { throw ControlError.invalidRequest }
        return ControlHello(nonce:nonce,instance:instance)
    }
    public static func encodeRequest(_ request: ControlRequest) throws -> Data {
        var params: [String:Any] = [:]; let name: String
        func pair(_ connection: UUID, _ frame: UUID) { params["connection"] = connection.uuidString; params["frame"] = frame.uuidString }
        func point(_ c:UUID,_ f:UUID,_ x:Double,_ y:Double) { pair(c,f); params["x"] = x; params["y"] = y }
        switch request.operation {
        case .status: name = "status"
        case .daemonStop: name = "daemonStop"
        case .capabilities: name = "capabilities"
        case .connect(let id): name = "connect"; params["profile"] = id.uuidString
        case .state(let c): name = "state"; params["connection"] = c.uuidString
        case .observe(let c): name = "observe"; params["connection"] = c.uuidString
        case .clickTarget(let c,let target): name = "click-target"; params["connection"] = c.uuidString; params["target"] = target
        case .cancel(let c): name = "cancel"; params["connection"] = c.uuidString
        case .disconnect(let c): name = "disconnect"; params["connection"] = c.uuidString
        case .release(let c): name = "release"; params["connection"] = c.uuidString
        case .navigate(let c,let u): name = "navigate"; params["connection"] = c.uuidString; params["url"] = u.absoluteString
        case .move(let c,let f,let x,let y): name = "move"; point(c,f,x,y)
        case .mouseDown(let c,let f,let x,let y): name = "mouseDown"; point(c,f,x,y)
        case .mouseUp(let c,let f,let x,let y): name = "mouseUp"; point(c,f,x,y)
        case .click(let c,let f,let x,let y,let n): name = "click"; point(c,f,x,y); params["count"] = n
        case .type(let c,let f,let text): name = "type"; pair(c,f); params["text"] = text
        case .press(let c,let f,let key,let shift): name = "press"; pair(c,f); params["key"] = key.rawValue; params["shift"] = shift
        case .pressEnterAndWait(let c,let f): name = "pressEnterAndWait"; pair(c,f)
        case .clickAndWait(let c,let f,let x,let y): name = "clickAndWait"; point(c,f,x,y)
        case .help, .daemonStart, .daemonServe, .typeFromStdin: throw ControlError.invalidRequest
        }
        let data = try encode(["version":1,"requestID":request.requestID.uuidString,"operation":name,"parameters":params])
        guard try decodeRequest(data) == request else { throw ControlError.invalidRequest }
        return data
    }
    public static func decodeRequest(_ data: Data) throws -> ControlRequest {
        let root = try object(data); try version(root)
        guard Set(root.keys) == ["version","requestID","operation","parameters"], let id = (root["requestID"] as? String).flatMap(UUID.init(uuidString:)), let name = root["operation"] as? String, let params = root["parameters"] as? [String:Any] else { throw ControlError.invalidRequest }
        let expected: Set<String>
        switch name {
        case "status", "capabilities", "daemonStop": expected = []
        case "connect": expected = ["profile"]
        case "state", "observe", "cancel", "disconnect", "release": expected = ["connection"]
        case "click-target": expected = ["connection","target"]
        case "navigate": expected = ["connection","url"]
        case "move", "mouseDown", "mouseUp": expected = ["connection","frame","x","y"]
        case "click": expected = ["connection","frame","x","y","count"]
        case "type": expected = ["connection","frame","text"]
        case "press": expected = ["connection","frame","key","shift"]
        case "pressEnterAndWait": expected = ["connection","frame"]
        case "clickAndWait": expected = ["connection","frame","x","y"]
        default: throw ControlError.invalidRequest
        }
        guard Set(params.keys) == expected else { throw ControlError.invalidRequest }
        var args = name == "daemonStop" ? ["daemon", "stop"] : [name == "pressEnterAndWait" ? "press" : name == "clickAndWait" ? "click" : name]
        if name == "pressEnterAndWait" { args += ["--key", "Enter", "--wait-navigation"] }
        if name == "clickAndWait" { args.append("--wait-navigation") }
        for key in expected.sorted() {
            guard let value = params[key] else { throw ControlError.invalidRequest }
            if key == "shift" {
                guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ControlError.invalidRequest }
                if n.boolValue { args.append("--shift") }; continue
            }
            let valueString: String
            if ["x","y","count"].contains(key) {
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw ControlError.invalidRequest }
                valueString = n.stringValue
            } else { guard let s = value as? String else { throw ControlError.invalidRequest }; valueString = s }
            args.append("--" + key); args.append(valueString)
        }
        let parsed = try ControlCLIParser.parse(args)
        return ControlRequest(requestID:id,operation:parsed.operation)
    }
}
