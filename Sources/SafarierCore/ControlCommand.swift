import Foundation

public enum ControlError: Error, Equatable, Sendable { case invalidRequest, unsupportedVersion, frameTooLarge }
public struct ControlOptions: Equatable, Sendable {
    public let applicationPath: String?, runtimePath: String?
    public init(applicationPath: String? = nil, runtimePath: String? = nil) { self.applicationPath = applicationPath; self.runtimePath = runtimePath }
}
public enum ControlOperation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case help, daemonStart, daemonServe, daemonStop, status, capabilities
    case connect(profileID: UUID), state(connection: UUID), observe(connection: UUID), navigate(connection: UUID, url: URL)
    case clickTarget(connection: UUID, target: String)
    case move(connection: UUID, frame: UUID, x: Double, y: Double)
    case mouseDown(connection: UUID, frame: UUID, x: Double, y: Double)
    case mouseUp(connection: UUID, frame: UUID, x: Double, y: Double)
    case click(connection: UUID, frame: UUID, x: Double, y: Double, count: Int)
    case type(connection: UUID, frame: UUID, text: String), typeFromStdin(connection: UUID, frame: UUID)
    case press(connection: UUID, frame: UUID, key: AutomationKey, shift: Bool)
    case pressEnterAndWait(connection: UUID, frame: UUID)
    case clickAndWait(connection: UUID, frame: UUID, x: Double, y: Double)
    case cancel(connection: UUID), disconnect(connection: UUID), release(connection: UUID)
    public var description: String { "ControlOperation(redacted)" }
    public var debugDescription: String { description }
}
public struct ParsedControlCommand: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let options: ControlOptions, operation: ControlOperation
    public var description: String { "ParsedControlCommand(redacted)" }
    public var debugDescription: String { description }
}
public enum ControlCLIParser {
    public static func parse(_ arguments: [String]) throws -> ParsedControlCommand {
        var args = arguments
        if args.first == "control" { args.removeFirst() }
        var globals: [String: String] = [:], rest: [String] = []
        let valuedOptions: Set<String> = ["--profile", "--connection", "--frame", "--url", "--x", "--y", "--count", "--text", "--key", "--target"]
        var i = 0
        while i < args.count {
            let item = args[i]
            if item == "--app" || item == "--runtime" {
                guard globals[item] == nil, i + 1 < args.count else { throw ControlError.invalidRequest }
                let value = args[i+1]
                guard value.hasPrefix("/"), !value.utf8.contains(0) else { throw ControlError.invalidRequest }
                globals[item] = value; i += 2
            } else if valuedOptions.contains(item) {
                guard i + 1 < args.count, item == "--text" || !args[i+1].hasPrefix("--") else { throw ControlError.invalidRequest }
                rest.append(item); rest.append(args[i+1]); i += 2
            } else { rest.append(item); i += 1 }
        }
        let options = ControlOptions(applicationPath: globals["--app"], runtimePath: globals["--runtime"])
        if rest.isEmpty || rest == ["help"] || rest == ["--help"] || rest == ["-h"] { return ParsedControlCommand(options: options, operation: .help) }
        let command = rest.removeFirst()
        if command == "daemon" {
            guard rest.count == 1 else { throw ControlError.invalidRequest }
            let op: ControlOperation
            switch rest[0] { case "start": op = .daemonStart; case "serve": op = .daemonServe; case "stop": op = .daemonStop; default: throw ControlError.invalidRequest }
            return ParsedControlCommand(options: options, operation: op)
        }
        var values: [String:String] = [:], flags = Set<String>()
        i = 0
        while i < rest.count {
            let key = rest[i]
            guard key.hasPrefix("--"), values[key] == nil, !flags.contains(key) else { throw ControlError.invalidRequest }
            if key == "--shift" || key == "--text-stdin" || key == "--wait-navigation" { flags.insert(key); i += 1 }
            else { guard i+1 < rest.count, (key == "--text" || !rest[i+1].hasPrefix("--")) else { throw ControlError.invalidRequest }; values[key] = rest[i+1]; i += 2 }
        }
        func require(_ keys: Set<String>, flags expected: Set<String> = []) throws {
            guard Set(values.keys) == keys, flags == expected else { throw ControlError.invalidRequest }
        }
        func uuid(_ key: String) throws -> UUID { guard let s = values[key], let v = UUID(uuidString:s) else { throw ControlError.invalidRequest }; return v }
        func number(_ key: String) throws -> Double { guard let s = values[key], let n = Double(s), n.isFinite, n >= 0 else { throw ControlError.invalidRequest }; return n }
        let op: ControlOperation
        switch command {
        case "status": try require([]); op = .status
        case "capabilities": try require([]); op = .capabilities
        case "connect": try require(["--profile"]); op = .connect(profileID: try uuid("--profile"))
        case "state", "observe", "cancel", "disconnect", "release":
            try require(["--connection"]); let c = try uuid("--connection")
            switch command { case "state": op = .state(connection:c); case "observe": op = .observe(connection:c); case "cancel": op = .cancel(connection:c); case "release": op = .release(connection:c); default: op = .disconnect(connection:c) }
        case "click-target":
            try require(["--connection","--target"])
            guard let target = values["--target"], !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.unicodeScalars.count <= 512, target.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw ControlError.invalidRequest }
            op = .clickTarget(connection:try uuid("--connection"),target:target)
        case "navigate":
            try require(["--connection","--url"]); guard let raw = values["--url"], let url = URL(string:raw), let scheme = url.scheme?.lowercased(), ["http","https"].contains(scheme), let host = url.host, !host.isEmpty, host != ".", url.user == nil, url.password == nil, host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { throw ControlError.invalidRequest }; op = .navigate(connection:try uuid("--connection"),url:url)
        case "move", "mouseDown", "mouseUp", "click":
            let keys: Set<String> = ["--connection","--frame","--x","--y"]
            let waitFlags: Set<String> = command == "click" && flags.contains("--wait-navigation") ? ["--wait-navigation"] : []
            if command == "click", values["--count"] != nil { try require(keys.union(["--count"]), flags: waitFlags) } else { try require(keys, flags: waitFlags) }
            let c = try uuid("--connection"), f = try uuid("--frame"), x = try number("--x"), y = try number("--y")
            switch command { case "move": op = .move(connection:c,frame:f,x:x,y:y); case "mouseDown": op = .mouseDown(connection:c,frame:f,x:x,y:y); case "mouseUp": op = .mouseUp(connection:c,frame:f,x:x,y:y); default: let count = values["--count"].flatMap(Int.init) ?? (values["--count"] == nil ? 1 : 0); guard count == 1 || count == 2 else { throw ControlError.invalidRequest }; if flags.contains("--wait-navigation") { guard count == 1 else { throw ControlError.invalidRequest }; op = .clickAndWait(connection:c,frame:f,x:x,y:y) } else { op = .click(connection:c,frame:f,x:x,y:y,count:count) } }
        case "type":
            if flags.contains("--text-stdin") { try require(["--connection","--frame"], flags:["--text-stdin"]); op = .typeFromStdin(connection:try uuid("--connection"),frame:try uuid("--frame")) }
            else { try require(["--connection","--frame","--text"]); guard let text = values["--text"], text.utf8.count <= AutomationLimits.textBytes else { throw ControlError.invalidRequest }; op = .type(connection:try uuid("--connection"),frame:try uuid("--frame"),text:text) }
        case "press":
            if flags.contains("--wait-navigation") {
                try require(["--connection","--frame","--key"], flags:["--wait-navigation"])
                guard values["--key"] == AutomationKey.enter.rawValue else { throw ControlError.invalidRequest }
                op = .pressEnterAndWait(connection:try uuid("--connection"),frame:try uuid("--frame"))
            } else {
                try require(["--connection","--frame","--key"], flags:flags.contains("--shift") ? ["--shift"] : [])
                guard let raw = values["--key"], let key = AutomationKey(rawValue:raw) else { throw ControlError.invalidRequest }
                guard !flags.contains("--shift") || [.tab, .left, .right, .up, .down, .home, .end].contains(key) else { throw ControlError.invalidRequest }
                op = .press(connection:try uuid("--connection"),frame:try uuid("--frame"),key:key,shift:flags.contains("--shift"))
            }
        default: throw ControlError.invalidRequest
        }
        return ParsedControlCommand(options:options,operation:op)
    }
}
