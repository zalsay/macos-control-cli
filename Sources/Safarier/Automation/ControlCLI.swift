import Darwin
import Foundation
import SafarierControlSupport
import SafarierCore

@MainActor
enum ControlCLI {
    /// Authenticated identity for a particular local control endpoint. This is
    /// an observation pin only; it never grants authority to signal a process.
    struct EndpointIdentity: Sendable, Equatable {
        struct Peer: Sendable, Equatable {
            let pid: Int32
            let uid: UInt32
            let pidversion: UInt32
            let birthSeconds: UInt64
            let birthMicroseconds: UInt64
            let auditDigest: Data

            fileprivate init(_ proof: CSControlPeer) {
                pid = proof.pid
                uid = proof.uid
                pidversion = proof.pidversion
                birthSeconds = proof.birth_sec
                birthMicroseconds = proof.birth_usec
                auditDigest = withUnsafeBytes(of: proof.audit_digest) { Data($0) }
            }
        }

        let socketDevice: UInt64
        let socketInode: UInt64
        let socketMode: UInt32
        let socketOwner: UInt32
        let peer: Peer

        fileprivate init(socket: stat, peer: CSControlPeer) {
            socketDevice = UInt64(truncatingIfNeeded: socket.st_dev)
            socketInode = UInt64(truncatingIfNeeded: socket.st_ino)
            socketMode = UInt32(truncatingIfNeeded: socket.st_mode)
            socketOwner = UInt32(truncatingIfNeeded: socket.st_uid)
            self.peer = Peer(peer)
        }
    }

    private static let usage = """
    Usage: Safarier control [--app ABSOLUTE_APP] [--runtime ABSOLUTE_PRIVATE_DIRECTORY] COMMAND
      daemon start|serve|stop
      status | capabilities
      authorization-request
      authorization-status --request AUTHORIZATION_REQUEST_UUID
      connect --profile PROFILE_UUID
      state|observe|cancel|disconnect|release --connection CONNECTION_UUID
      navigate --connection CONNECTION_UUID --url ABSOLUTE_URL
      move|mouseDown|mouseUp --connection CONNECTION_UUID --frame FRAME_UUID --x PIXEL_X --y PIXEL_Y
      click --connection CONNECTION_UUID --frame FRAME_UUID --x PIXEL_X --y PIXEL_Y [--count 1|2] [--wait-navigation]
      click-target --connection CONNECTION_UUID --target TEXT
      select-file --connection CONNECTION_UUID --path ABSOLUTE_FILE [--path ABSOLUTE_FILE ...]
      type --connection CONNECTION_UUID --frame FRAME_UUID (--text TEXT | --text-stdin)
      press --connection CONNECTION_UUID --frame FRAME_UUID --key KEY [--shift]
      press --connection CONNECTION_UUID --frame FRAME_UUID --key Enter --wait-navigation
      back --connection CONNECTION_UUID --frame FRAME_UUID

    Use the same --app and --runtime for every command. observe returns a frame UUID and screenshot path;
    observe also returns optional local Vision OCR; unavailable OCR does not prevent a screenshot.
    click-target sends the target and recognized candidate IDs/text to the configured HTTPS model;
    it never sends the screenshot or coordinates. Successful native delivery is not proof of page effect.
    select-file supplies up to 20 local files to the open file chooser of the registered page.
    No frame is required. Use observe to confirm upload results.
    Coordinates are screenshot pixels for that frame; the latest 32 frames are retained.
    Use observe to judge page effects and decide when a fresh screenshot is needed.
    For registered browsers, --wait-navigation is a compatibility spelling for sending Enter or one click;
    it does not wait for navigation or verify its effect. Input replies report sent:true, effectVerified:false.
    back sends Backspace through the same native press path. In editable content it deletes text;
    otherwise the browser handles history back. Use observe to confirm the resulting page.
    PageUp and PageDown send native page keys to the focused content; use observe to confirm scrolling.
    Supported keys: Backspace, Delete, Enter, Tab, Escape, Left, Right, Up, Down, Home, End, PageUp, PageDown.
    PageUp/PageDown do not accept --shift or --wait-navigation.
    Wheel is unavailable. Registered control remains connected until release or a real connection failure;
    request IDs remain recorded to prevent duplicate execution.
    Host authorization requests are local-only and require an existing profile Host runtime. The request
    returns pending immediately; authorization-status only reads that request's receipt and never retries.
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
        } catch ControlRuntime.Failure.cleanupUnconfirmed {
            FileHandle.standardError.write(Data("control: daemon stop unconfirmed; no automatic retry\n".utf8)); return 1
        } catch ControlRuntime.Failure.indeterminate {
            FileHandle.standardError.write(Data("control: indeterminate result; no automatic retry\n".utf8)); return 1
        } catch {
            FileHandle.standardError.write(Data("control: unavailable or invalid request\n".utf8)); return 1
        }
    }
    private static func exchange(_ operation: ControlOperation, applicationPath: String, runtimePath: String) throws -> Int32 {
        let request = ControlRequest(requestID: UUID(), operation: operation)
        let data = try exchange(request, applicationPath: applicationPath, runtimePath: runtimePath)
        let reply = try decodeReply(data, requestID: request.requestID)
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        return reply.status == "ok" ? 0 : 1
    }

    /// Exchange a pre-validated request with the existing local daemon. Remote
    /// control uses this entry point so the daemon sees the original request ID
    /// and retains its normal identity checks and replay protection.
    nonisolated static func exchange(_ request: ControlRequest, applicationPath: String, runtimePath: String,
                                     expectedPeerPID: Int32? = nil,
                                     expectedEndpointIdentity: EndpointIdentity? = nil) throws -> Data {
        try exchangeWithEndpointIdentity(request, applicationPath: applicationPath, runtimePath: runtimePath,
                                         expectedPeerPID: expectedPeerPID,
                                         expectedEndpointIdentity: expectedEndpointIdentity).data
    }

    nonisolated static func exchangeWithEndpointIdentity(_ request: ControlRequest, applicationPath: String,
                                                         runtimePath: String, expectedPeerPID: Int32? = nil,
                                                         expectedEndpointIdentity: EndpointIdentity? = nil)
    throws -> (data: Data, endpointIdentity: EndpointIdentity) {
        let runtime = try ControlRuntime(path: runtimePath, create: false)
        let (fd, socketPin) = try runtime.connectSocket()
        defer { Darwin.close(fd) }
        let connectedPeer = try ControlRuntime.peer(fd)
        let endpointIdentity = EndpointIdentity(socket: socketPin, peer: connectedPeer)
        guard expectedEndpointIdentity == nil || expectedEndpointIdentity == endpointIdentity,
              expectedPeerPID == nil || connectedPeer.pid == expectedPeerPID else {
            throw ControlRuntime.Failure.unsafe
        }
        let pinnedPeerPID = expectedEndpointIdentity?.peer.pid ?? expectedPeerPID
        let diagnosticRequest = request
        NavigationDiagnostic.emit(diagnosticRequest, "cli.request")
        var replyReceived = false
        defer { if !replyReceived { NavigationDiagnostic.emit(diagnosticRequest, "cli.failure", "error") } }
        var validated: ControlBrokerReply?
        let data = try ControlRuntime.clientExchange(fd, request: request, instance: ControlRuntime.applicationInstance(applicationPath),
                                                     expectedPeerPID: pinnedPeerPID, validatePath: {
            try runtime.validateSocket(socketPin)
        }, validateReply: { bytes in
            guard let reply = try? JSONDecoder().decode(ControlBrokerReply.self, from: bytes),
                  reply.version == 1, reply.requestID == request.requestID,
                  (reply.status == "ok" && reply.error == nil) || (reply.status == "error" && reply.error != nil) else {
                throw ControlRuntime.Failure.indeterminate
            }
            validated = reply
        })
        guard let validated else { throw ControlRuntime.Failure.indeterminate }
        if case .daemonStop = request.operation, validated.status == "ok" {
            try runtime.waitForSocketRemoval(socketPin)
        }
        replyReceived = true
        NavigationDiagnostic.emit(diagnosticRequest, "cli.reply", validated.status == "ok" ? "ok" : (validated.error ?? "error"))
        return (data, endpointIdentity)
    }

    nonisolated static func decodeReply(_ data: Data, requestID: UUID) throws -> ControlBrokerReply {
        guard let reply = try? JSONDecoder().decode(ControlBrokerReply.self, from: data),
              reply.version == 1, reply.requestID == requestID,
              (reply.status == "ok" && reply.error == nil) || (reply.status == "error" && reply.error != nil) else {
            throw ControlRuntime.Failure.indeterminate
        }
        return reply
    }
    private static func start(applicationPath: String, runtimePath: String) throws -> Int32 {
        let runtime = try ControlRuntime(path: runtimePath, create: true)
        guard let executable = Bundle.main.executableURL else { throw ControlRuntime.Failure.unsafe }

        // A participating daemon holds this lock for its complete lifetime.
        // While it is held, only an authenticated status exchange can prove
        // the existing endpoint; a refused/absent probe never authorizes spawn.
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(Int(AutomationLimits.actionSeconds)))
        var startupLock = try runtime.acquireStartupLock(waitSeconds: 0)
        while startupLock == nil && ContinuousClock.now < startupDeadline {
            if try runtime.endpointIsConnectable() {
                return try exchange(.status, applicationPath: applicationPath, runtimePath: runtimePath)
            }
            Thread.sleep(forTimeInterval: 0.05)
            startupLock = try runtime.acquireStartupLock(waitSeconds: 0)
        }
        guard let lock = startupLock else { throw ControlRuntime.Failure.indeterminate }
        defer { lock.release() }

        switch try runtime.startupSocketState(lockedBy: lock) {
        case .active:
            // Preserve the existing authenticated status contract. In
            // particular, a pathname alone never adopts or validates a daemon.
            return try exchange(.status, applicationPath: applicationPath, runtimePath: runtimePath)
        case .absent, .stale(_):
            break // Only the serving process may recover a proven stale socket.
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["control", "daemon", "serve", "--app", applicationPath, "--runtime", runtimePath]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        // The child is now waiting for this lock. Release it before polling.
        lock.release()
        while ContinuousClock.now < startupDeadline, process.isRunning {
            if try runtime.endpointIsConnectable() {
                return try exchange(.status, applicationPath: applicationPath, runtimePath: runtimePath)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ControlRuntime.Failure.indeterminate
    }
}
