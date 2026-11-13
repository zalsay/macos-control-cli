import Foundation
import AppKit
import Darwin

#if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
private let bid = "sh.safarier.testing"
#else
private let bid = "sh.safarier.boundcandidate"
#endif
#if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
private func isExpectedGoogleHost(_ host: String) -> Bool {
    host == "google.com" || host.hasSuffix(".google.com") ||
    host == "google.com.hk" || host.hasSuffix(".google.com.hk")
}
#endif
private enum Stop: Error { case unsafe, preflight, appleScript, protocolFailure, timeout }
private func emit(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line); fflush(stdout)
}
private func managerLogFiles(in results: String) throws -> (FileHandle, FileHandle) {
    let dir = open(results, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard dir >= 0 else { throw Stop.unsafe }
    defer { close(dir) }
    var directory = stat()
    guard fstat(dir, &directory) == 0, directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          directory.st_uid == geteuid(), directory.st_mode & 0o7777 == 0o700 else { throw Stop.unsafe }
    func create(_ name: String) throws -> FileHandle {
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Stop.unsafe }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              file.st_uid == geteuid(), file.st_mode & 0o7777 == 0o600, file.st_nlink == 1 else {
            close(fd); throw Stop.unsafe
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    return try (create("manager.stdout"), create("manager.stderr"))
}
#if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
private final class WorkspaceLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var returned: NSRunningApplication?
    private var failure: Error?
    func finish(_ app: NSRunningApplication?, _ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        returned = app; failure = error; completed = true
    }
    func snapshot() -> (Bool, NSRunningApplication?, Error?) {
        lock.lock(); defer { lock.unlock() }
        return (completed, returned, failure)
    }
}
#endif

private enum OwnedManager {
    case child(Process)
    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    case workspace(NSRunningApplication, Date)
    #endif
    var processIdentifier: pid_t {
        switch self {
        case .child(let process): return process.processIdentifier
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        case .workspace(let app, _): return app.processIdentifier
        #endif
        }
    }
    var isRunning: Bool {
        switch self {
        case .child(let process): return process.isRunning
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        case .workspace(let app, _): return !app.isTerminated
        #endif
        }
    }
    func handleMatches(appURL: URL, executable: String) -> Bool {
        switch self {
        case .child: return true
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        case .workspace(let app, let launched):
            return !app.isTerminated && app.launchDate == launched && app.bundleIdentifier == bid &&
                app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == appURL.resolvingSymlinksInPath().standardizedFileURL &&
                app.executableURL?.resolvingSymlinksInPath().path == executable
        #endif
        }
    }
    func terminate() {
        switch self {
        case .child(let process): process.terminate()
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        case .workspace(let app, _): _ = app.terminate()
        #endif
        }
    }
}

private func mainHost() throws {
    let args = CommandLine.arguments
    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    guard (args.count == 6 || (args.count == 7 && args[5] == "--preflight-only" && args[6] == "--request-consent-once")),
          (args[5] == "--testing-smoke" || args[5] == "--testing-input" || args[5] == "--testing-google" || args[5] == "--preflight-only"),
          let profileID = UUID(uuidString: args[3]) else { throw Stop.unsafe }
    let preflightOnly = args[5] == "--preflight-only"
    let testingInput = args[5] == "--testing-input"
    let testingGoogle = args[5] == "--testing-google"
    let requestConsent = args.count == 7
    var consentRequested = false
    #elseif SAFARIER_WHEEL_OBSERVER_PROBE
    guard args.count == 6, args[5] == "--wheel-observer-smoke",
          let profileID = UUID(uuidString: args[3]) else { throw Stop.unsafe }
    let preflightOnly = false
    #else
    guard (args.count == 6 || (args.count == 7 && args[5] == "--smoke" && args[6] == "--request-consent-once")),
          (args[5] == "--preflight-only" || args[5] == "--smoke" || args[5] == "--form-a-smoke"),
          let profileID = UUID(uuidString: args[3]) else { throw Stop.unsafe }
    let preflightOnly = args[5] == "--preflight-only"
    let formAScenario = args[5] == "--form-a-smoke"
    let requestConsent = args.count == 7
    var consentRequested = false
    #endif
    let app = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    let mainExecutableRelative = "Contents/MacOS/Safarier AI"
    let fixtureRelative = "Contents/Helpers/Safarier AI Browser.app/Contents/Resources/control-fixture.html"
    #else
    let mainExecutableRelative = "Contents/MacOS/Safarier"
    let fixtureRelative = "Contents/Helpers/SafarierRunner.app/Contents/Resources/control-fixture.html"
    #endif
    let exe = app.appendingPathComponent(mainExecutableRelative).resolvingSymlinksInPath().path
    let workspace = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL.path
    let results = URL(fileURLWithPath: args[4], isDirectory: true).standardizedFileURL.path
    func startChildManager() throws -> OwnedManager {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        var env = ProcessInfo.processInfo.environment
        env["SAFARIER_HOME"] = workspace
        process.environment = env
        let (managerStdout, managerStderr) = try managerLogFiles(in: results)
        process.standardOutput = managerStdout
        process.standardError = managerStderr
        try process.run()
        return .child(process)
    }
    let manager: OwnedManager
    let expectedParent: pid_t
    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    if testingGoogle || testingInput {
        let resolvedApp = app.resolvingSymlinksInPath().standardizedFileURL
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty,
              !NSWorkspace.shared.runningApplications.contains(where: {
                  $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == resolvedApp
              }) else { throw Stop.unsafe }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.allowsRunningApplicationSubstitution = false
        config.activates = false
        config.environment = ["SAFARIER_HOME":workspace]
        config.appleEvent = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x6e6f6f70,
                                                   targetDescriptor: nil, returnID: -1, transactionID: 0)
        let launch = WorkspaceLaunchState()
        emit(["status":"manager_stdio_not_captured", "mode":"workspace"])
        NSWorkspace.shared.openApplication(at: app, configuration: config) { returned, error in
            launch.finish(returned, error)
        }
        let launchDeadline = Date().addingTimeInterval(10)
        while !launch.snapshot().0 && Date() < launchDeadline {
            RunLoop.current.run(until: min(launchDeadline, Date().addingTimeInterval(0.1)))
        }
        let (completed, returned, error) = launch.snapshot()
        guard completed, error == nil, let returned, let date = returned.launchDate else {
            emit(["status":"cleanup_unconfirmed", "ownedManagerExited":false]); throw Stop.unsafe
        }
        manager = .workspace(returned, date)
        expectedParent = 1
    } else {
        manager = try startChildManager()
        expectedParent = getpid()
    }
    #else
    manager = try startChildManager()
    expectedParent = getpid()
    #endif
    var birth = BIProcess()
    guard manager.isRunning, manager.handleMatches(appURL:app, executable:exe),
          host_capture(manager.processIdentifier, &birth) != 0,
          host_expected(&birth, expectedParent, getuid(), exe) != 0 else {
        emit(["status":"cleanup_unconfirmed", "ownedManagerExited":false]); throw Stop.unsafe
    }
    var session: String?
    var smokePhase = "startup"
    func ownerAndRoute(_ failureCheckpoint: String? = nil) -> Bool {
        func failed(_ reason: String) -> Bool {
            if let failureCheckpoint {
                emit(["status":"owner_route_failed", "phase":smokePhase, "checkpoint":failureCheckpoint, "reason":reason])
            }
            return false
        }
        guard manager.isRunning else { return failed("manager_not_running") }
        guard manager.handleMatches(appURL:app, executable:exe) else { return failed("owned_handle_mismatch") }
        var now = BIProcess()
        guard host_capture(manager.processIdentifier, &now) != 0 else { return failed("metadata_unavailable") }
        guard host_equal(&birth, &now) != 0 else { return failed("birth_mismatch") }
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        let singleMatchSatisfied = matches.count == 1 && matches[0].processIdentifier == manager.processIdentifier &&
            matches[0].isFinishedLaunching && !matches[0].isActive && matches[0].activationPolicy == .accessory &&
            matches[0].bundleURL?.resolvingSymlinksInPath().standardizedFileURL == app.resolvingSymlinksInPath().standardizedFileURL
        if !singleMatchSatisfied, let failureCheckpoint {
            let expectedManagerPresent = matches.contains { $0.processIdentifier == manager.processIdentifier }
            var diagnostic: [String:Any] = ["status":"owner_route_failed", "phase":smokePhase, "checkpoint":failureCheckpoint, "reason":"route_mismatch",
                "matchCount":matches.count, "expectedManagerPresent":expectedManagerPresent, "singleMatchSatisfied":singleMatchSatisfied]
            if matches.count == 1 {
                let match = matches[0]
                diagnostic["pidMatchesExpected"] = match.processIdentifier == manager.processIdentifier
                diagnostic["isFinishedLaunching"] = match.isFinishedLaunching
                diagnostic["isActive"] = match.isActive
                diagnostic["activationPolicy"] = match.activationPolicy.rawValue
                diagnostic["bundleURLMatchesExpected"] = match.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == app.resolvingSymlinksInPath().standardizedFileURL
                diagnostic["isTerminated"] = match.isTerminated
            }
            emit(diagnostic)
        }
        return singleMatchSatisfied
    }
    func send(_ action: AutomationAction, token: String?) throws -> AutomationResult {
        #if SAFARIER_WHEEL_OBSERVER_PROBE
        switch action {
        case .capabilities, .openSession, .getState, .closeSession: break
        default: throw Stop.unsafe
        }
        #endif
        guard ownerAndRoute("before_permission") else { throw Stop.unsafe }
        let permission = g1_permission_bid()
        guard permission == 0 else { emit(["status":"permission_stopped", "errorNumber":permission]); throw Stop.preflight }
        guard ownerAndRoute("after_permission") else { throw Stop.unsafe }
        let id = UUID()
        let request = AutomationRequest(version: 1, requestID: id, sessionID: token, action: action)
        let data = try AutomationCodec.encodeRequest(request)
        guard let json = String(data: data, encoding: .utf8) else { throw Stop.protocolFailure }
        let escaped = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var timeoutSeconds: UInt32 = 10
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        if case .navigate = action { timeoutSeconds = UInt32(AutomationLimits.navigationSeconds) + 5 }
        #endif
        let script = "with timeout of \(timeoutSeconds) seconds\n tell application id \"\(bid)\" to automation request \"\(escaped)\"\nend timeout"
        var output = [UInt8](repeating: 0, count: AutomationLimits.frameBytes)
        var written = 0
        var scriptError: Int32 = 0
        var rejectedClass: UInt32 = 0, rejectedID: UInt32 = 0
        var rejectedStatus: Int32 = 0
        let status = Array(script.utf8).withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { dest in
                host_osa_script(source.baseAddress, source.count, &birth, timeoutSeconds, dest.baseAddress, dest.count, &written, &scriptError, &rejectedClass, &rejectedID, &rejectedStatus)
            }
        }
        if status != 0 {
            var record: [String:Any] = ["requestID":id.uuidString, "status":"osa_error", "errorNumber":scriptError, "osStatus":status]
            if rejectedStatus != 0 {
                // Exactly four bytes represented as hex; never event payload.
                record["rejectedEventClassHex"] = String(format:"%08X", rejectedClass)
                record["rejectedEventIDHex"] = String(format:"%08X", rejectedID)
                record["rejectedOSStatus"] = rejectedStatus
            }
            emit(record)
            if status == -1712 || scriptError == -1712 { throw Stop.timeout }
            throw Stop.appleScript
        }
        let raw = Data(output.prefix(written))
        let decoded = try? AutomationCodec.decodeReply(raw)
        guard let reply = decoded, reply.requestID == id else {
            emit(["status":"reply_decode_or_id_failed", "phase":smokePhase,
                  "decodeSucceeded":decoded != nil, "requestIDMatches":decoded.map { $0.requestID == id } ?? false,
                  "byteCount":raw.count])
            throw Stop.protocolFailure
        }
        switch reply.outcome {
        case .failure(let failure):
            emit(["requestID":id.uuidString,"status":"error","errorCode":failure.code.rawValue])
            throw Stop.protocolFailure
        case .success(let result):
            var record: [String:Any] = ["requestID":id.uuidString,"status":"ok"]
            switch result {
            case .sessionOpened(_, let target, let viewport):
                record["target"] = ["profileID":target.profileID.uuidString,"runnerInstanceID":target.runnerInstanceID.uuidString,"windowID":target.windowID.uuidString,"pageID":target.pageID.uuidString]
                record["viewport"] = ["width":viewport.viewportWidthPoints,"height":viewport.viewportHeightPoints,"viewVersion":viewport.viewVersion]
            case .stateRead(let state):
                record["target"] = ["profileID":state.target.profileID.uuidString,"runnerInstanceID":state.target.runnerInstanceID.uuidString,"windowID":state.target.windowID.uuidString,"pageID":state.target.pageID.uuidString]
                record["viewport"] = ["viewVersion":state.viewVersion]
            #if !SAFARIER_WHEEL_OBSERVER_PROBE
            case .nativeDelivered(let sequence, let buttons, let version):
                record["sequence"] = sequence; record["buttons"] = buttons; record["viewport"] = ["viewVersion":version]
            #endif
            default: break
            }
            emit(record); return result
        }
    }
    var success = false
    do {
        // Allow registration to settle only for this exact bundle identifier.
        let deadline = Date().addingTimeInterval(10)
        while !ownerAndRoute() && manager.isRunning && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        guard ownerAndRoute() else { throw Stop.unsafe }
        if preflightOnly {
            smokePhase = "preflight"
            var permission = g1_permission_bid()
            #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
            if requestConsent && permission == -1744 && !consentRequested {
                guard ownerAndRoute() else { throw Stop.unsafe }
                guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String,
                      !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    emit(["status":"consent_usage_description_missing"])
                    throw Stop.preflight
                }
                consentRequested = true
                emit(["status":"consent_request_start"])
                permission = g1_request_permission_bid()
                guard ownerAndRoute() else { throw Stop.unsafe }
            }
            #endif
            guard permission == 0 else {
                emit(["status":"permission_stopped", "errorNumber":permission])
                throw Stop.preflight
            }
            guard ownerAndRoute() else { throw Stop.unsafe }
            emit(["status":"permission_allowed"])
            success = true
        } else {
        #if !SAFARIER_WHEEL_OBSERVER_PROBE && !SAFARIER_INTERNAL_TEST_APP
        if requestConsent {
            var permission = g1_permission_bid()
            if permission == -1744 && !consentRequested {
                guard ownerAndRoute() else { throw Stop.unsafe }
                guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String,
                      !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    emit(["status":"consent_usage_description_missing"])
                    throw Stop.preflight
                }
                consentRequested = true
                emit(["status":"consent_request_start"])
                permission = g1_request_permission_bid()
            }
            guard permission == 0 else {
                emit(["status":"permission_stopped", "errorNumber":permission])
                throw Stop.preflight
            }
            guard ownerAndRoute() else { throw Stop.unsafe }
        }
        #endif
        smokePhase = "capabilities"
        guard case .capabilities = try send(.capabilities, token:nil) else { throw Stop.protocolFailure }
        smokePhase = "openSession"
        guard case let .sessionOpened(token, target, viewport) = try send(.openSession(profileID:profileID), token:nil), target.profileID == profileID else { throw Stop.protocolFailure }
        session = token
        smokePhase = "getState"
        guard case let .stateRead(state) = try send(.getState, token:token), state.target == target, state.sessionState == .ready, !state.loading,
              state.url?.standardizedFileURL == app.appendingPathComponent(fixtureRelative).standardizedFileURL else { throw Stop.protocolFailure }
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        if testingGoogle {
            // Only expose a public, stripped summary. It is not origin identity or proof of results.
            func publicGoogleURL(_ url: URL?) throws -> (String, Bool) {
                guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
                      parts.port == nil, let host = parts.host?.lowercased(), host.utf8.count <= 253,
                      host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                      isExpectedGoogleHost(host) else { throw Stop.protocolFailure }
                let path: String
                switch parts.path {
                case "", "/": path = "/"
                case "/search": path = "/search"
                default: path = "/<redacted>"
                }
                let queryItems = (parts.queryItems ?? []).filter { $0.name == "q" }
                let queryConfirmed = queryItems.count == 1 && queryItems[0].value == "AI"
                return ("https://" + host + path + (queryConfirmed ? "?q=AI" : ""), queryConfirmed)
            }
            let requests: [(String, URL)] = [
                ("search", URL(string:"https://www.google.com/search?q=AI")!)
            ]
            var previousVersion = state.viewVersion
            for (label, url) in requests {
                smokePhase = "google_" + label + "_navigate"
                let started = DispatchTime.now().uptimeNanoseconds
                emit(["status":"google_navigation_start", "stage":label, "elapsedMs":0])
                let response: AutomationResult
                do {
                    response = try send(.navigate(url:url), token:token)
                } catch {
                    let now = DispatchTime.now().uptimeNanoseconds
                    emit(["status":"google_navigation_return", "stage":label, "result":"error",
                          "elapsedMs":now >= started ? (now - started) / 1_000_000 : 0])
                    throw error
                }
                let now = DispatchTime.now().uptimeNanoseconds
                emit(["status":"google_navigation_return", "stage":label, "result":"reply",
                      "elapsedMs":now >= started ? (now - started) / 1_000_000 : 0])
                guard case let .navigationFinished(version) = response,
                      version > previousVersion else { throw Stop.protocolFailure }
                smokePhase = "google_" + label + "_state"
                guard case let .stateRead(pageState) = try send(.getState, token:token),
                      pageState.target == target, pageState.sessionState == .ready, !pageState.loading,
                      pageState.viewVersion == version else { throw Stop.protocolFailure }
                let (publicURL, queryConfirmed) = try publicGoogleURL(pageState.url)
                emit(["status":"google_url_observed", "stage":label, "publicURL":publicURL,
                      "queryAI":queryConfirmed ? "confirmed" : "unconfirmed", "viewVersion":version])
                smokePhase = "google_" + label + "_screenshot"
                guard case let .snapshotWritten(path, snapshotViewport) = try send(.screenshot, token:token),
                      snapshotViewport.viewVersion == version else { throw Stop.protocolFailure }
                let copied = label == "home" ? host_copy_hover_png(workspace, path, results) : host_copy_form_png(workspace, path, results)
                guard copied != 0 else { throw Stop.protocolFailure }
                emit(["status":"google_snapshot_saved", "stage":label, "file":label == "home" ? "hover.png" : "form.png"])
                previousVersion = version
            }
        } else {
        smokePhase = "navigate"
        let site = URL(string: "https://www.selenium.dev/selenium/web/web-form.html")!
        guard case let .navigationFinished(version) = try send(.navigate(url:site), token:token), version > state.viewVersion else { throw Stop.protocolFailure }
        smokePhase = "siteState"
        guard case let .stateRead(siteState) = try send(.getState, token:token), siteState.target == target,
              siteState.sessionState == .ready, !siteState.loading, siteState.viewVersion == version,
              siteState.url == site else { throw Stop.protocolFailure }
        smokePhase = "siteScreenshot"
        guard case let .snapshotWritten(path, snapshotViewport) = try send(.screenshot, token:token),
              snapshotViewport.viewVersion == version, host_copy_hover_png(workspace, path, results) != 0 else { throw Stop.protocolFailure }
        if testingInput {
            let point = ViewportPoint(x:180, y:106)
            guard version == 2, snapshotViewport.viewportWidthPoints == 1280,
                  snapshotViewport.viewportHeightPoints == 772, snapshotViewport.pixelWidth == 1280,
                  snapshotViewport.pixelHeight == 772, snapshotViewport.contains(point) else { throw Stop.protocolFailure }
            let actions: [(String, AutomationAction)] = [
                ("move", .move(point:point, viewVersion:version)),
                ("clickText", .click(point:point, viewVersion:version, count:1)),
                ("insertText", .insertText("Safarier Test 123中文")),
                ("backspace", .key(name:.backspace, shift:false)),
                ("left", .key(name:.left, shift:false)),
                ("right", .key(name:.right, shift:false)),
                ("insertExclamation", .insertText("!"))
            ]
            var previousSequence: UInt64 = 0
            for (name, action) in actions {
                smokePhase = name
                guard case let .nativeDelivered(sequence, buttons, next) = try send(action, token:token),
                      sequence > previousSequence, buttons == 0, next == version else { throw Stop.protocolFailure }
                previousSequence = sequence
            }
            smokePhase = "finalScreenshot"
            guard case let .snapshotWritten(finalPath, finalViewport) = try send(.screenshot, token:token),
                  finalViewport == snapshotViewport,
                  host_copy_form_png(workspace, finalPath, results) != 0 else { throw Stop.protocolFailure }
            emit(["status":"testing_input_snapshot_saved"])
        } else {
            emit(["status":"testing_screenshot_saved_input_not_attempted"])
        }
        }
        #elseif !SAFARIER_WHEEL_OBSERVER_PROBE
        if formAScenario {
            let button = ViewportPoint(x:100,y:70), text = ViewportPoint(x:100,y:160)
            guard viewport.contains(button), viewport.contains(text), viewport.viewVersion == state.viewVersion else { throw Stop.protocolFailure }
            let version = state.viewVersion
            let actions: [(String, AutomationAction)] = [
                ("clickButton", .click(point:button,viewVersion:version,count:1)),
                ("clickText", .click(point:text,viewVersion:version,count:1)),
                ("insertASCII", .insertText("native-123")),
                ("backspace", .key(name:.backspace,shift:false)),
                ("left", .key(name:.left,shift:false)),
                ("right", .key(name:.right,shift:false)),
                ("insertChinese", .insertText("中文"))
            ]
            for (index, step) in actions.enumerated() {
                smokePhase = step.0
                guard case let .nativeDelivered(sequence, buttons, next) = try send(step.1, token:token),
                      sequence == UInt64(index + 1), buttons == 0, next == version else { throw Stop.protocolFailure }
            }
            smokePhase = "formSnapshot"
            guard case let .snapshotWritten(path, snapshotViewport) = try send(.screenshot, token:token),
                  snapshotViewport.viewVersion == version,
                  host_copy_form_png(workspace, path, results) != 0 else { throw Stop.protocolFailure }
            emit(["status":"form_a_snapshot_saved"])
        } else {
            guard viewport.contains(ViewportPoint(x:700,y:260)), viewport.contains(ViewportPoint(x:280,y:70)) else { throw Stop.protocolFailure }
            var version = state.viewVersion
            let actions: [(String, ViewportPoint)] = [("move", .init(x:280,y:70)), ("move", .init(x:620,y:260)), ("down", .init(x:620,y:260)), ("move", .init(x:700,y:260)), ("up", .init(x:700,y:260))]
            var priorSequence: UInt64 = 0
            for (name, point) in actions {
                if name == "down" { smokePhase = "mouseDown" }
                else if name == "up" { smokePhase = "mouseUp" }
                else if point.x == 280 && point.y == 70 { smokePhase = "hover" }
                else if point.x == 700 && point.y == 260 { smokePhase = "heldMove" }
                else { smokePhase = "dragStartMove" }
                let action: AutomationAction = name == "down" ? .mouseDown(point:point,viewVersion:version) : name == "up" ? .mouseUp(point:point,viewVersion:version) : .move(point:point,viewVersion:version)
                guard case let .nativeDelivered(sequence, buttons, next) = try send(action, token:token), sequence > priorSequence,
                      buttons == ((name == "down" || (name == "move" && point.x == 700)) ? 1 : 0) else { throw Stop.protocolFailure }
                priorSequence = sequence; version = next
                if name == "move" && point.x == 280 && point.y == 70 {
                    smokePhase = "screenshot"
                    guard case let .snapshotWritten(path, snapshotViewport) = try send(.screenshot, token:token),
                          snapshotViewport.viewVersion == version,
                          host_copy_hover_png(workspace, path, results) != 0 else { throw Stop.protocolFailure }
                    emit(["status":"hover_snapshot_saved"])
                }
            }
        }
        #endif
        smokePhase = "closeSession"
        guard case let .sessionClosed(receipt) = try send(.closeSession, token:token), receipt.cleaned else { throw Stop.protocolFailure }
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        if testingGoogle {
            guard receipt.terminatedOwnedRunner else { throw Stop.protocolFailure }
            emit(["status":"google_close_proof", "cleaned":receipt.cleaned, "terminatedOwnedRunner":receipt.terminatedOwnedRunner])
        } else if testingInput {
            guard receipt.terminatedOwnedRunner else { throw Stop.protocolFailure }
            emit(["status":"testing_close_proof", "cleaned":receipt.cleaned, "terminatedOwnedRunner":receipt.terminatedOwnedRunner])
        }
        #endif
        session = nil
        success = true
        }
    } catch let failure as Stop {
        // Failure or unknown business outcome never triggers another Apple Event.
        let reason: String
        switch failure {
        case .unsafe: reason = "unsafe"
        case .preflight: reason = "preflight"
        case .appleScript: reason = "appleScript"
        case .protocolFailure: reason = "protocolFailure"
        case .timeout: reason = "timeout"
        }
        emit(["status":preflightOnly ? "preflight_failed" : "smoke_failed", "phase":smokePhase, "reason":reason])
    } catch {
        emit(["status":preflightOnly ? "preflight_failed" : "smoke_failed", "phase":smokePhase, "reason":"unknown"])
    }
    _ = session // Only held in memory; never serialized.
    // Cleanup authority is the retained child plus its original birth proof, not
    // the business result, response, registration list or a PID file.
    if manager.isRunning {
        var fresh = BIProcess()
        guard manager.handleMatches(appURL:app, executable:exe),
              host_capture(manager.processIdentifier, &fresh) != 0, host_equal(&birth, &fresh) != 0, manager.isRunning else {
            emit(["status":"cleanup_unconfirmed", "ownedManagerExited":false]); throw Stop.unsafe
        }
        manager.terminate()
        let deadline = Date().addingTimeInterval(5)
        while manager.isRunning && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }
    guard !manager.isRunning else {
        emit(["status":"cleanup_unconfirmed", "ownedManagerExited":false]); throw Stop.timeout
    }
    switch manager {
    case .child(let process):
        emit(["status":"owned_manager_exited", "ownedManagerExited":true, "terminationStatus":process.terminationStatus])
    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    case .workspace:
        emit(["status":"owned_manager_exited", "ownedManagerExited":true, "exitStatusAvailable":false])
    #endif
    }
    guard success else { throw Stop.unsafe }
    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    emit(["status":preflightOnly ? "preflight_complete" : testingGoogle ? "testing_google_navigation_complete" : testingInput ? "testing_native_input_complete" : "testing_navigation_snapshot_complete_input_pending"])
    #elseif SAFARIER_WHEEL_OBSERVER_PROBE
    emit(["status":"wheel_observer_smoke_complete"])
    #else
    emit(["status":preflightOnly ? "preflight_complete" : formAScenario ? "form_a_smoke_complete" : "smoke_complete"])
    #endif
}

@main
struct Entry { static func main() { do { try mainHost() } catch { exit(1) } } }
