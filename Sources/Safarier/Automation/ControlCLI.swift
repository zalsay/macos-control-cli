import Darwin
import Foundation
import SafarierCore

@MainActor
enum ControlCLI {
    private static let usage = """
    Usage: Safarier control [--app ABSOLUTE_APP] [--runtime ABSOLUTE_PRIVATE_DIRECTORY] COMMAND
      daemon start|serve|stop
      status | capabilities
      connect --profile PROFILE_UUID
      state|observe|cancel|disconnect|release --connection CONNECTION_UUID
      navigate --connection CONNECTION_UUID --url HTTPS_OR_HTTP_URL
      move|mouseDown|mouseUp --connection CONNECTION_UUID --frame FRAME_UUID --x PIXEL_X --y PIXEL_Y
      click --connection CONNECTION_UUID --frame FRAME_UUID --x PIXEL_X --y PIXEL_Y [--count 1|2] [--wait-navigation]
      click-target --connection CONNECTION_UUID --target TEXT
      type --connection CONNECTION_UUID --frame FRAME_UUID (--text TEXT | --text-stdin)
      press --connection CONNECTION_UUID --frame FRAME_UUID --key KEY [--shift]
      press --connection CONNECTION_UUID --frame FRAME_UUID --key Enter --wait-navigation

    Use the same --app and --runtime for every command. observe returns a frame UUID and screenshot path;
    observe also returns optional local Vision OCR; unavailable OCR does not prevent a screenshot.
    click-target sends the target and recognized candidate IDs/text to the configured HTTPS model;
    it never sends the screenshot or coordinates. Successful native delivery is not proof of page effect.
    Coordinates are screenshot pixels for that frame. A navigation requires a new observe before input.
    --wait-navigation is for Enter or a single click and uses the native navigation operation when supported.
    Wheel is unavailable. The original Runner binding expires after 90 seconds and cannot be renewed;
    the daemon has a bounded replay window and may require a clean stop and restart when it is full.
    """
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let parsed = try ControlCLIParser.parse(arguments)
            if case .help = parsed.operation { print(usage); return 0 }
            let app = parsed.options.applicationPath ?? Bundle.main.bundleURL.path
            let root = parsed.options.runtimePath ?? (NSHomeDirectory() + "/.safarier-control")
            switch parsed.operation {
            case .daemonServe:
                try ControlDaemon.serve(applicationPath: app, runtimePath: root)
                return 0
            case .daemonStart:
                return try start(applicationPath: app, runtimePath: root)
            default:
                let operation: ControlOperation
                if case let .typeFromStdin(connection, frame) = parsed.operation {
                    var input = Data()
                    while input.count <= AutomationLimits.textBytes {
                        let chunk = try FileHandle.standardInput.read(upToCount: AutomationLimits.textBytes + 1 - input.count) ?? Data()
                        if chunk.isEmpty { break }
                        input.append(chunk)
                    }
                    guard input.count <= AutomationLimits.textBytes, let text = String(data: input, encoding: .utf8) else { throw ControlError.invalidRequest }
                    operation = .type(connection: connection, frame: frame, text: text)
                } else { operation = parsed.operation }
                return try exchange(operation, applicationPath: app, runtimePath: root)
            }
        } catch ControlRuntime.Failure.indeterminate {
            FileHandle.standardError.write(Data("control: indeterminate result; no automatic retry\n".utf8)); return 1
        } catch {
            FileHandle.standardError.write(Data("control: unavailable or invalid request\n".utf8)); return 1
        }
    }
    private static func exchange(_ operation: ControlOperation, applicationPath: String, runtimePath: String) throws -> Int32 {
        let runtime = try ControlRuntime(path: runtimePath, create: false)
        let (fd, socketPin) = try runtime.connectSocket()
        defer { Darwin.close(fd) }
        let id = UUID()
        let diagnosticRequest = ControlRequest(requestID: id, operation: operation)
        NavigationDiagnostic.emit(diagnosticRequest, "cli.request")
        var replyReceived = false
        defer { if !replyReceived { NavigationDiagnostic.emit(diagnosticRequest, "cli.failure", "error") } }
        var validated: ControlBrokerReply?
        let data = try ControlRuntime.clientExchange(fd, request: ControlRequest(requestID: id, operation: operation), instance: ControlRuntime.applicationInstance(applicationPath), validatePath: {
            try runtime.validateSocket(socketPin)
        }, validateReply: { bytes in
            guard let reply = try? JSONDecoder().decode(ControlBrokerReply.self, from: bytes),
                  reply.version == 1, reply.requestID == id,
                  (reply.status == "ok" && reply.error == nil) || (reply.status == "error" && reply.error != nil) else {
                throw ControlRuntime.Failure.indeterminate
            }
            validated = reply
        })
        guard let reply = validated else { throw ControlRuntime.Failure.indeterminate }
        replyReceived = true
        NavigationDiagnostic.emit(diagnosticRequest, "cli.reply", reply.status == "ok" ? "ok" : (reply.error ?? "error"))
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        return reply.status == "ok" ? 0 : 1
    }
    private static func start(applicationPath: String, runtimePath: String) throws -> Int32 {
        _ = try ControlRuntime(path: runtimePath, create: true)
        var info = stat()
        let socketPath = runtimePath + "/control.sock"
        if lstat(socketPath, &info) == 0 { return try exchange(.status, applicationPath: applicationPath, runtimePath: runtimePath) }
        guard errno == ENOENT, let executable = Bundle.main.executableURL else { throw ControlRuntime.Failure.unsafe }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["control", "daemon", "serve", "--app", applicationPath, "--runtime", runtimePath]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(AutomationLimits.actionSeconds)
        while Date() < deadline, process.isRunning {
            if lstat(socketPath, &info) == 0 { return try exchange(.status, applicationPath: applicationPath, runtimePath: runtimePath) }
            guard errno == ENOENT else { throw ControlRuntime.Failure.unsafe }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ControlRuntime.Failure.indeterminate
    }
}
