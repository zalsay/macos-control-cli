import Foundation
@testable import SafarierCore

public enum ControlCommandCases {
    public static func run() throws -> Int {
        var n = 0
        func check(_ v: Bool) throws { n += 1; if !v { throw Failure() } }
        let c = UUID(), f = UUID(), r = UUID()
        try check((try? ControlCLIParser.parse(["control", "release", "--connection", c.uuidString]))?.operation == .release(connection: c))
        let releaseRequest = ControlRequest(requestID: r, operation: .release(connection: c))
        try check(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(releaseRequest)) == releaseRequest)
        let args = ["control", "--runtime", "/tmp/control", "click", "--connection", c.uuidString, "--frame", f.uuidString, "--x", "3.5", "--y", "7", "--count", "2"]
        let parsed = try ControlCLIParser.parse(args)
        try check(parsed.operation == .click(connection: c, frame: f, x: 3.5, y: 7, count: 2))
        try check(parsed.options.runtimePath == "/tmp/control")
        try check((try? ControlCLIParser.parse(["control", "--help"]))?.operation == .help)
        try check((try? ControlCLIParser.parse(["control", "type", "--connection", c.uuidString, "--frame", f.uuidString, "--text-stdin"]))?.operation == .typeFromStdin(connection: c, frame: f))
        for bad in [args + ["--x", "3"], args.map { $0 == "3.5" ? "nan" : $0 }, args.map { $0 == "2" ? "3" : $0 }, ["control", "--app", "relative", "status"], ["control", "state", "--connection", "secret"]] {
            try check((try? ControlCLIParser.parse(bad)) == nil)
        }
        try check((try? ControlCLIParser.parse(["control", "type", "--connection", c.uuidString, "--frame", f.uuidString, "--text", String(repeating: "a", count: 16385)])) == nil)
        try check((try? ControlCLIParser.parse(["control", "type", "--connection", c.uuidString, "--frame", f.uuidString, "--text", "--literal"]))?.operation == .type(connection: c, frame: f, text: "--literal"))
        for text in ["--app", "--runtime"] {
            let literal = try ControlCLIParser.parse(["control", "type", "--connection", c.uuidString, "--text", text, "--app", "/tmp/real.app", "--frame", f.uuidString, "--runtime", "/tmp/real-runtime"])
            try check(literal.operation == .type(connection: c, frame: f, text: text) && literal.options.applicationPath == "/tmp/real.app" && literal.options.runtimePath == "/tmp/real-runtime")
            let request = ControlRequest(requestID: r, operation: literal.operation)
            try check(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(request)) == request)
        }
        try check((try? ControlCLIParser.parse(["control", "--app", "/a", "--app", "/b", "status"])) == nil)
        try check((try? ControlCLIParser.parse(["control", "--runtime", "--app", "/a", "status"])) == nil)
        try check((try? ControlCLIParser.parse(["control", "state", "--connection", "--runtime", "/tmp/x"])) == nil)
        for coordinate in ["x", "y"] {
            let negative = args.map { $0 == (coordinate == "x" ? "3.5" : "7") ? "-1" : $0 }
            try check((try? ControlCLIParser.parse(negative)) == nil)
            let x = coordinate == "x" ? -1 : 1, y = coordinate == "y" ? -1 : 1
            let wire = Data("{\"version\":1,\"requestID\":\"\(r)\",\"operation\":\"clickAndWait\",\"parameters\":{\"connection\":\"\(c)\",\"frame\":\"\(f)\",\"x\":\(x),\"y\":\(y)}}".utf8)
            try check((try? ControlProtocol.decodeRequest(wire)) == nil)
        }
        let pressWait = ["control", "press", "--connection", c.uuidString, "--frame", f.uuidString, "--key", "Enter", "--wait-navigation"]
        let shiftedTab = ["control", "press", "--connection", c.uuidString, "--frame", f.uuidString, "--key", "Tab", "--shift"]
        try check((try? ControlCLIParser.parse(shiftedTab))?.operation == .press(connection: c, frame: f, key: .tab, shift: true))
        try check((try? ControlCLIParser.parse(shiftedTab.map { $0 == "Tab" ? "Enter" : $0 })) == nil)
        let shiftedBackspace = Data("{\"version\":1,\"requestID\":\"\(r)\",\"operation\":\"press\",\"parameters\":{\"connection\":\"\(c)\",\"frame\":\"\(f)\",\"key\":\"Backspace\",\"shift\":true}}".utf8)
        try check((try? ControlProtocol.decodeRequest(shiftedBackspace)) == nil)
        let clickWait = ["control", "click", "--connection", c.uuidString, "--frame", f.uuidString, "--x", "3", "--y", "4", "--wait-navigation"]
        try check((try? ControlCLIParser.parse(pressWait))?.operation == .pressEnterAndWait(connection: c, frame: f))
        try check((try? ControlCLIParser.parse(clickWait))?.operation == .clickAndWait(connection: c, frame: f, x: 3, y: 4))
        try check((try? ControlCLIParser.parse(pressWait + ["--shift"])) == nil)
        try check((try? ControlCLIParser.parse(pressWait.map { $0 == "Enter" ? "Tab" : $0 })) == nil)
        try check((try? ControlCLIParser.parse(clickWait + ["--count", "2"])) == nil)
        try check((try? ControlCLIParser.parse(clickWait + ["--count", "1"]))?.operation == .clickAndWait(connection: c, frame: f, x: 3, y: 4))
        for op in [ControlOperation.pressEnterAndWait(connection:c, frame:f), .clickAndWait(connection:c, frame:f, x:3, y:4)] {
            let request = ControlRequest(requestID:r, operation:op)
            try check(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(request)) == request)
        }
        let msg = ControlRequest(requestID: r, operation: parsed.operation)
        let stop = ControlRequest(requestID: r, operation: .daemonStop)
        try check(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(stop)) == stop)
        for name in ["daemonStart", "daemonServe", "daemon", "unknown"] {
            let data = Data("{\"version\":1,\"requestID\":\"\(r)\",\"operation\":\"\(name)\",\"parameters\":{}}".utf8)
            try check((try? ControlProtocol.decodeRequest(data)) == nil)
        }
        let stopExtra = Data("{\"version\":1,\"requestID\":\"\(r)\",\"operation\":\"daemonStop\",\"parameters\":{\"pid\":1}}".utf8)
        try check((try? ControlProtocol.decodeRequest(stopExtra)) == nil)
        for op in [ControlOperation.help, .daemonStart, .daemonServe, .typeFromStdin(connection: c, frame: f)] {
            try check((try? ControlProtocol.encodeRequest(ControlRequest(requestID: r, operation: op))) == nil)
        }
        let wire = try ControlProtocol.encodeRequest(msg)
        try check(try ControlProtocol.decodeRequest(wire) == msg)
        try check(try ControlProtocol.unframe(ControlProtocol.frame(wire)) == wire)
        let hello = ControlHello(nonce: c, instance: f)
        try check(try ControlProtocol.decodeHello(ControlProtocol.encodeHello(hello)) == hello)
        let bad = Data("{\"version\":1,\"requestID\":\"\(r)\",\"operation\":\"status\",\"parameters\":{},\"sessionID\":\"secret\"}".utf8)
        try check((try? ControlProtocol.decodeRequest(bad)) == nil)
        let duplicate = Data("{\"version\":1,\"vers\\u0069on\":1,\"requestID\":\"\(r)\",\"operation\":\"status\",\"parameters\":{}}".utf8)
        try check((try? ControlProtocol.decodeRequest(duplicate)) == nil)
        try check((try? ControlProtocol.frame(Data(repeating: 1, count: 65537))) == nil)
        try check((try? ControlProtocol.unframe(Data([0, 1, 0, 1]))) == nil)
        try check(!String(describing: ControlError.invalidRequest).contains("secret"))
        return n
    }
    struct Failure: Error {}
}
