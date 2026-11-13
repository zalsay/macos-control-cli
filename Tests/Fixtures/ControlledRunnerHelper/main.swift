import Foundation
import Darwin
import SafarierCore

@main struct ControlledRunnerHelper {
    static func main() async {
        Task.detached {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            exit(124)
        }
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let spec = try RunnerLaunchSpec.parse(args, environment: ProcessInfo.processInfo.environment)
            guard spec.backgroundAutomation, !spec.probe, spec.startURL == URL(string: "about:blank") else { exit(2) }
            if let raw = getenv("CONTROLLED_CHECK_FD"), let fd = Int32(String(cString: raw)),
               let inoRaw = getenv("CONTROLLED_CHECK_INO"), let ino = UInt64(String(cString: inoRaw)),
               let devRaw = getenv("CONTROLLED_CHECK_DEV"), let dev = Int32(String(cString: devRaw)) {
                var st = stat()
                if fstat(fd, &st) == 0 && st.st_dev == dev && st.st_ino == ino { exit(3) }
            }
            if getenv("CONTROLLED_EXEC") != nil {
                unsetenv("CONTROLLED_EXEC")
                let argv = CommandLine.arguments.map { strdup($0) } + [nil]
                argv.withUnsafeBufferPointer { _ = execv(argv[0]!, $0.baseAddress!) }
                exit(4)
            }
            var fixtureLock: ProfileLock?
            if let expectedRaw = getenv("CONTROLLED_EXPECT_HOME") {
                let expected = String(cString: expectedRaw)
                guard ProcessInfo.processInfo.environment["SAFARIER_HOME"] == expected else { exit(7) }
                let workspace = try SafarierWorkspace.default()
                guard workspace.root.standardizedFileURL == URL(fileURLWithPath: expected).standardizedFileURL,
                      try workspace.profiles.record(id: spec.profileID) != nil else { exit(8) }
                fixtureLock = try ProfileLock.acquire(profileID: spec.profileID, in: workspace.locksDirectory)
            }
            defer { fixtureLock?.release() }
            let channel = try AutomationChannel(adopting: FileHandle(fileDescriptor: STDIN_FILENO, closeOnDealloc: false))
            guard let modeRaw = getenv("CONTROLLED_BAD"), let mode = String(validatingUTF8: modeRaw) else {
                exit(await AutomationRunnerBootstrap.serveUnavailable(profileID: spec.profileID, channel: channel, idleSeconds: 5))
            }
            if mode == "multiplex" {
                let server = AutomationRunnerServer(profileID: spec.profileID, channel: channel, idleSeconds: 5, maxOrdinaryRequests: 8, handler: { request in
                    switch request.action {
                    case .capabilities:
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        return .success(.capabilities(AutomationCapabilities(backend: .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: "1", role: "runner", managerPID: Int(getppid()))))
                    case .cancel, .closeSession:
                        return .success(.sessionClosed(CleanupReceipt(cleaned: true, terminatedOwnedRunner: false)))
                    case .mouseDown:
                        if let marker = ProcessInfo.processInfo.environment["CONTROLLED_MUTATION_MARKER"] { try? Data().write(to: URL(fileURLWithPath: marker)) }
                        return .failure(AutomationError(code: .backendUnavailable))
                    default: return .failure(AutomationError(code: .backendUnavailable))
                    }
                }, shutdown: {})
                exit(await server.serve())
            }
            defer { channel.close() }
            guard let hello = try await channel.receive() else { exit(5) }
            let challenge = try AutomationHandshakeCodec.readChallenge(hello, expectedProfileID: spec.profileID)
            if mode == "stall" { _ = try await channel.receive(); exit(0) }
            let instance = UUID()
            try await channel.send(AutomationHandshakeCodec.makeResponse(challenge, runnerInstanceID: instance, runnerPID: getpid()))
            guard let frame = try await channel.receive() else { exit(6) }
            let request = try AutomationCodec.decode(frame)
            if mode == "drop-rpc" { exit(0) }
            if mode == "backend-failure" {
                let error = AutomationError(code: .backendUnavailable, retryable: true, sideEffects: .possible)
                try await channel.send(AutomationCodec.encode(AutomationReply(requestID: request.requestID, outcome: .failure(error))))
                _ = try await channel.receive(); exit(0)
            }
            if mode == "stall-rpc" {
                guard let path = getenv("CONTROLLED_READY_FILE") else { exit(9) }
                try Data().write(to: URL(fileURLWithPath: String(cString: path)))
                _ = try await channel.receive(); exit(0)
            }
            if mode == "late", let path = getenv("CONTROLLED_READY_FILE") {
                try Data().write(to: URL(fileURLWithPath: String(cString: path)))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let target = AutomationTargetIdentity(profileID: (mode == "bad-target" || mode == "bad-state") ? UUID() : spec.profileID, runnerInstanceID: mode == "bad-instance" ? UUID() : instance, windowID: UUID(), pageID: UUID())
            let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
            let result: AutomationResult
            if mode == "bad-role" || mode == "bad-id" || mode == "late" {
                result = .capabilities(AutomationCapabilities(backend: .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: "1", role: mode == "bad-role" ? "manager" : "runner", managerPID: Int(getppid())))
            } else if mode == "bad-target" || mode == "bad-instance" {
                result = .sessionOpened(sessionID: try AutomationSessionToken.generate(), target: target, viewport: viewport)
            } else {
                result = .stateRead(AutomationState(target: target, url: nil, loading: false, sessionState: .ready, viewVersion: 1))
            }
            try await channel.send(AutomationCodec.encode(AutomationReply(requestID: mode == "bad-id" ? UUID() : request.requestID, outcome: .success(result))))
            _ = try await channel.receive()
            exit(0)
        } catch { exit(1) }
    }
}
