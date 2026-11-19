import Foundation
import Dispatch
import Darwin
import SafarierCore

enum RemoteControlPolicy {
    static func clientOptionsAllowed(_ options: ControlOptions) -> Bool {
        options.applicationPath == nil && options.runtimePath == nil
    }

    static func permits(_ operation: ControlOperation) -> Bool {
        switch operation {
        case .status, .capabilities, .connect, .state, .observe, .navigate,
             .clickTarget, .move, .mouseDown, .mouseUp, .click, .type, .press,
             .pressEnterAndWait, .clickAndWait, .cancel, .disconnect, .release:
            if case let .navigate(_, url) = operation { return safeURL(url) }
            return true
        case .authorizationRequest, .authorizationStatus,
             .help, .daemonStart, .daemonServe, .daemonStop, .selectFile, .typeFromStdin:
            return false
        }
    }

    static func connectUsesAllowedProfile(_ operation: ControlOperation, allowedProfile: UUID) -> Bool {
        guard case let .connect(profileID) = operation else { return true }
        return profileID == allowedProfile
    }

    static func connection(in operation: ControlOperation) -> UUID? {
        switch operation {
        case let .state(id), let .observe(id), let .navigate(id, _), let .clickTarget(id, _),
             let .selectFile(id, _), let .move(id, _, _, _), let .mouseDown(id, _, _, _),
             let .mouseUp(id, _, _, _), let .click(id, _, _, _, _), let .type(id, _, _),
             let .typeFromStdin(id, _), let .press(id, _, _, _), let .pressEnterAndWait(id, _),
             let .clickAndWait(id, _, _, _), let .cancel(id), let .disconnect(id), let .release(id):
            return id
        default:
            return nil
        }
    }

    static func targetBelongsToProfile(_ reply: ControlBrokerReply, profileID: UUID) -> Bool {
        guard reply.status == "ok", let state = reply.state, state.target.profileID == profileID else { return false }
        guard let url = state.url else { return true }
        return safeURL(url) || url.absoluteString == "about:blank"
    }

    static func safeURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    static func sanitizedRemoteReply(_ source: ControlBrokerReply) -> ControlBrokerReply {
        var reply = source
        if reply.screenshotPath != nil {
            reply.screenshotPath = nil
            reply.remoteScreenshotUnavailable = true
        }
        return reply
    }
}

@MainActor
enum RemoteControlCLI {
    static let usage = "用法：sfa --remote SSH_ALIAS control COMMAND [OPTIONS]"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 2, arguments[1] == "control" else {
            writeError(usage)
            return 64
        }
        let alias = arguments[0]
        var requestID: UUID?
        do {
            let parsed = try ControlCLIParser.parse(Array(arguments.dropFirst()))
            if case .help = parsed.operation {
                FileHandle.standardOutput.write(Data((usage + "\nRemote control uses the host's fixed app/runtime; only allowlisted controls are accepted. Screenshots are not transferred.\n").utf8))
                return 0
            }
            guard RemoteControlPolicy.clientOptionsAllowed(parsed.options) else {
                throw RemoteControlFailure.rejected("远程控制不接受 --app 或 --runtime。")
            }
            var operation = parsed.operation
            if case let .typeFromStdin(connection, frame) = operation {
                operation = .type(connection: connection, frame: frame, text: try readBoundedStdin())
            }
            guard RemoteControlPolicy.permits(operation) else {
                throw RemoteControlFailure.rejected("该 control 操作不在远程允许列表中。")
            }
            let request = ControlRequest(requestID: UUID(), operation: operation)
            requestID = request.requestID
            let payload = try ControlProtocol.encodeRequest(request)
            let framedRequest = try ControlProtocol.frame(payload)
            let replyData = try RemoteSSHTransport.exchange(alias: alias, request: framedRequest)
            let reply = try ControlCLI.decodeReply(replyData, requestID: request.requestID)
            guard reply.screenshotPath == nil else { throw RemoteControlFailure.uncertain }
            FileHandle.standardOutput.write(replyData)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return reply.status == "ok" ? 0 : 1
        } catch RemoteControlFailure.rejected(let message) {
            writeError(message)
            return 64
        } catch RemoteControlFailure.uncertain {
            writeError("control: remote result uncertain; no automatic retry", requestID: requestID)
            return 1
        } catch is ControlError {
            writeError("control: invalid or unsupported remote request")
            return 64
        } catch {
            // Once an SSH process has been launched, transport/protocol failure
            // cannot establish whether a mutating request reached the host.
            writeError("control: remote result uncertain; no automatic retry", requestID: requestID)
            return 1
        }
    }

    private static func readBoundedStdin() throws -> String {
        let data = try BoundedInput.read(FileHandle.standardInput, limit: AutomationLimits.textBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw RemoteControlFailure.rejected("stdin 必须是有效 UTF-8 文本。") }
        return text
    }

    private static func writeError(_ message: String, requestID: UUID? = nil) {
        let suffix = requestID.map { " (request \($0.uuidString))" } ?? ""
        FileHandle.standardError.write(Data((message + suffix + "\n").utf8))
    }
}

@MainActor
enum RemoteHostCLI {
    static let usage = "用法：sfa host serve --profile PROFILE_UUID（应作为专用 SSH key 的固定 forced command）"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 3, arguments[0] == "serve", arguments[1] == "--profile",
              let profileID = UUID(uuidString: arguments[2]) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
        do {
            let requestFrame = try BoundedInput.readFrame(FileHandle.standardInput)
            let request = try ControlProtocol.decodeRequest(ControlProtocol.unframe(requestFrame))
            guard RemoteControlPolicy.permits(request.operation) else {
                let denied = ControlBrokerReply(request.requestID, status: "error", error: "REMOTE_OPERATION_NOT_ALLOWED")
                FileHandle.standardOutput.write(try ControlProtocol.frame(JSONEncoder().encode(denied)))
                return 0
            }
            guard RemoteControlPolicy.connectUsesAllowedProfile(request.operation, allowedProfile: profileID) else {
                let denied = ControlBrokerReply(request.requestID, status: "error", error: "PROFILE_NOT_ALLOWED")
                FileHandle.standardOutput.write(try ControlProtocol.frame(JSONEncoder().encode(denied)))
                return 0
            }
            let workspace = try SafarierWorkspace.default()
            guard let profile = try workspace.profiles.record(id: profileID), profile.allowsAgentAccess else {
                throw RemoteControlFailure.rejected("configured profile is unavailable")
            }
            guard profile.startURL.map({ RemoteControlPolicy.safeURL($0) || $0.absoluteString == "about:blank" }) ?? true else {
                let denied = ControlBrokerReply(request.requestID, status: "error", error: "REMOTE_URL_NOT_ALLOWED")
                FileHandle.standardOutput.write(try ControlProtocol.frame(JSONEncoder().encode(denied)))
                return 0
            }
            let response = try handle(request, allowedProfile: profileID)
            let responseData = try JSONEncoder().encode(response)
            guard responseData.count <= AutomationLimits.frameBytes else { throw ControlError.frameTooLarge }
            let frame = try ControlProtocol.frame(responseData)
            FileHandle.standardOutput.write(frame)
            return 0
        } catch {
            FileHandle.standardError.write(Data("host: request rejected or control unavailable\n".utf8))
            return 1
        }
    }

    private static func handle(_ request: ControlRequest, allowedProfile: UUID) throws -> ControlBrokerReply {
        let appPath = Bundle.main.bundleURL.path
        let runtimePath = RemoteHostRuntime.path(for: allowedProfile)
        return RemoteHostExecutor.execute(request, allowedProfile: allowedProfile) { operationRequest in
            exchange(operationRequest, appPath: appPath, runtimePath: runtimePath)
        }
    }

    private static func exchange(_ request: ControlRequest, appPath: String, runtimePath: String) -> ControlBrokerReply {
        do {
            let data = try ControlCLI.exchange(request, applicationPath: appPath, runtimePath: runtimePath)
            return try ControlCLI.decodeReply(data, requestID: request.requestID)
        } catch ControlRuntime.Failure.indeterminate {
            return ControlBrokerReply(request.requestID, status: "error", error: "INDETERMINATE_RESULT")
        } catch {
            // No control command is sent if runtime/socket identity cannot be
            // established. Do not turn that into a retry or leak host paths.
            return ControlBrokerReply(request.requestID, status: "error", error: "UNAVAILABLE")
        }
    }
}

enum RemoteHostExecutor {
    static func execute(_ request: ControlRequest, allowedProfile: UUID,
                        exchange: (ControlRequest) -> ControlBrokerReply) -> ControlBrokerReply {
        let operation = request.operation
        guard RemoteControlPolicy.permits(operation) else {
            return ControlBrokerReply(request.requestID, status: "error", error: "REMOTE_OPERATION_NOT_ALLOWED")
        }
        guard RemoteControlPolicy.connectUsesAllowedProfile(operation, allowedProfile: allowedProfile) else {
            return ControlBrokerReply(request.requestID, status: "error", error: "PROFILE_NOT_ALLOWED")
        }

        if case .state = operation {
            let reply = exchange(request)
            guard RemoteControlPolicy.targetBelongsToProfile(reply, profileID: allowedProfile) else {
                let error = reply.status == "ok" ? "REMOTE_URL_NOT_ALLOWED" : (reply.error ?? "SESSION_NOT_FOUND")
                return ControlBrokerReply(request.requestID, status: "error", error: error)
            }
            return reply
        }
        if let connection = RemoteControlPolicy.connection(in: operation) {
            let stateRequest = ControlRequest(requestID: UUID(), operation: .state(connection: connection))
            let stateReply = exchange(stateRequest)
            guard stateReply.status == "ok" else {
                return ControlBrokerReply(request.requestID, status: "error", error: stateReply.error ?? "SESSION_NOT_FOUND")
            }
            guard RemoteControlPolicy.targetBelongsToProfile(stateReply, profileID: allowedProfile) else {
                return ControlBrokerReply(request.requestID, status: "error", error: "PROFILE_NOT_ALLOWED")
            }
        }

        return RemoteControlPolicy.sanitizedRemoteReply(exchange(request))
    }
}

enum RemoteHostRuntime {
    static func path(for profileID: UUID, home: String = NSHomeDirectory()) -> String {
        home + "/.safarier-control-host-" + profileID.uuidString.lowercased()
    }

    static func profileID(runtimePath: String, home: String = NSHomeDirectory()) -> UUID? {
        let prefix = home + "/.safarier-control-host-"
        guard runtimePath.hasPrefix(prefix),
              let profileID = UUID(uuidString: String(runtimePath.dropFirst(prefix.count))),
              path(for: profileID, home: home) == runtimePath else { return nil }
        return profileID
    }
}

enum RemoteControlFailure: Error {
    case rejected(String)
    case uncertain
}

enum BoundedInput {
    static func read(_ handle: FileHandle, limit: Int) throws -> Data {
        var result = Data()
        while true {
            let remaining = limit + 1 - result.count
            let chunk = try handle.read(upToCount: max(1, min(8_192, remaining))) ?? Data()
            if chunk.isEmpty { break }
            guard result.count + chunk.count <= limit else { throw RemoteControlFailure.rejected("stdin 超出协议长度上限。") }
            result.append(chunk)
        }
        return result
    }

    static func readFrame(_ handle: FileHandle) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        var result = Data()
        while true {
            let remaining = AutomationLimits.frameBytes + 5 - result.count
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw RemoteControlFailure.rejected("request read timed out") }
                let timeout = Int32(min(15_000, max(1, (deadline - now) / 1_000_000)))
                let ready = Darwin.poll(&descriptor, 1, timeout)
                if ready > 0 { break }
                if ready == 0 { continue }
                if errno == EINTR { continue }
                throw RemoteControlFailure.rejected("request input unavailable")
            }
            let chunk = try handle.read(upToCount: max(1, min(8_192, remaining))) ?? Data()
            if chunk.isEmpty { break }
            guard result.count + chunk.count <= AutomationLimits.frameBytes + 4 else {
                throw RemoteControlFailure.rejected("request exceeds protocol size limit")
            }
            result.append(chunk)
        }
        return result
    }
}

enum RemoteSSHTransport {
    private static let executable = URL(fileURLWithPath: "/usr/bin/ssh")
    private static let timeout: TimeInterval = 95
    private static let maximumOutput = AutomationLimits.frameBytes + 4

    static func arguments(alias: String) throws -> [String] {
        guard validAlias(alias) else { throw RemoteControlFailure.rejected("SSH_ALIAS 格式无效。") }
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                "-o", "ConnectTimeout=15", "--", alias, "sfa host serve"]
    }

    private static func validAlias(_ value: String) -> Bool {
        guard let first = value.utf8.first, (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || (first >= 48 && first <= 57) || first == 95 else { return false }
        return value.utf8.count <= 255 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || [45, 46, 58, 64, 95].contains($0)
        }
    }

    static func exchange(alias: String, request: Data) throws -> Data {
        let args = try arguments(alias: alias)
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw RemoteControlFailure.rejected("无法安全初始化 OpenSSH stdin。")
        }
        process.executableURL = executable
        process.arguments = args
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw RemoteControlFailure.rejected("无法启动系统 OpenSSH 客户端。") }

        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let outputReader = BoundedPipeReader(stdout.fileHandleForReading, limit: maximumOutput)
        let errorReader = BoundedPipeReader(stderr.fileHandleForReading, limit: 4_096)
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { writer.leave() }
            do { try stdin.fileHandleForWriting.write(contentsOf: request) } catch { }
            try? stdin.fileHandleForWriting.close()
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
            throw RemoteControlFailure.uncertain
        }
        _ = writer.wait(timeout: .now() + 1)
        guard let output = outputReader.result(timeout: 2), errorReader.result(timeout: 2) != nil,
              process.terminationStatus == 0 else { throw RemoteControlFailure.uncertain }
        // Strictly one framed reply; trailing bytes and oversized output fail closed.
        do { return try ControlProtocol.unframe(output) }
        catch { throw RemoteControlFailure.uncertain }
    }
}

private final class BoundedPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var captured = Data()
    private var overflow = false

    init(_ handle: FileHandle, limit: Int) {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { done.signal() }
            while true {
                guard let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty else { break }
                lock.lock()
                if captured.count + chunk.count <= limit { captured.append(chunk) } else { overflow = true }
                lock.unlock()
            }
        }
    }

    func result(timeout: TimeInterval) -> Data? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return overflow ? nil : captured
    }
}
