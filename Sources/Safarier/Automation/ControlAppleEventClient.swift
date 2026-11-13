import AppKit
import Foundation
import SafarierCore
import SafarierControlSupport

/// One retained destination for the lifetime of a broker. A PID is sampled only
/// as part of the held handle's identity, never as an Apple Event address.
@MainActor
final class ControlAppleEventClient {
    enum Failure: Error { case unavailable, indeterminate }
    private enum DestinationCheck { case current, route, staticIdentity }

    private static func diagnostic(_ phase: String, status: Int32, sent: Bool, senderAudit: Bool) {
        // phase is selected exclusively from fixed labels below; no request data.
        let line = "CONTROL_AE phase=\(phase) osStatus=\(status) sent=\(sent) senderAudit=\(senderAudit)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    private static func phaseName(_ value: UInt32) -> String {
        switch value {
        case 0: return "deadline"
        case 1: return "preIdentity"
        case 2: return "address"
        case 3: return "permission"
        case 4: return "postPermissionIdentity"
        case 5: return "createEvent"
        case 6: return "parameter"
        case 7: return "preSendIdentity"
        case 8: return "send"
        case 9: return "postReplyIdentity"
        case 10: return "replyAudit"
        case 11: return "replyError"
        case 12: return "replyObject"
        case 13: return "complete"
        default: return "unknown"
        }
    }

    static func failureLabel(_ error: Error) -> String {
        if let error = error as? AutomationError { return error.code.rawValue }
        if let error = error as? Failure { return error == .unavailable ? "sender_unavailable" : "sender_indeterminate" }
        if error is CancellationError { return "cancellation_error" }
        if error is DecodingError { return "decoding_error" }
        if error is EncodingError { return "encoding_error" }
        switch (error as NSError).domain {
        case NSCocoaErrorDomain: return "ns_cocoa"
        case NSPOSIXErrorDomain: return "ns_posix"
        case NSOSStatusErrorDomain: return "ns_osstatus"
        case NSURLErrorDomain: return "ns_url"
        default: return "other"
        }
    }

    private let bundleURL: URL
    private let executable: String
    private let bundleID: String
    private let manager: NSRunningApplication
    private let launchDate: Date
    private let initial: CSControlManager

    init(applicationPath: String) throws {
        let bundleURL = URL(fileURLWithPath: applicationPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        let expectedID = "sh.safarier.testing"
        let executableRelative = "Contents/MacOS/Safarier AI"
        #else
        let expectedID = "sh.safarier.app"
        let executableRelative = "Contents/MacOS/Safarier"
        #endif
        guard Bundle(url: bundleURL)?.bundleIdentifier == expectedID else {
            Self.diagnostic("route", status: 0, sent: false, senderAudit: false); throw Failure.unavailable
        }
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: expectedID)
        guard matches.count == 1, let manager = matches.first, !manager.isTerminated,
              manager.isFinishedLaunching, let date = manager.launchDate,
              manager.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundleURL else {
            Self.diagnostic("route", status: 0, sent: false, senderAudit: false); throw Failure.unavailable
        }
        let executable = bundleURL.appendingPathComponent(executableRelative).resolvingSymlinksInPath().path
        guard manager.executableURL?.resolvingSymlinksInPath().path == executable else {
            Self.diagnostic("route", status: 0, sent: false, senderAudit: false); throw Failure.unavailable
        }
        var proof = CSControlManager()
        guard executable.withCString({ cs_control_capture_manager(manager.processIdentifier, $0, &proof) }) == 1 else {
            Self.diagnostic("staticIdentity", status: 0, sent: false, senderAudit: false); throw Failure.unavailable
        }
        self.bundleURL = bundleURL
        self.executable = executable
        self.bundleID = expectedID
        self.manager = manager
        self.launchDate = date
        self.initial = proof
        let check = destinationCheck()
        guard check == .current else {
            Self.diagnostic(check == .route ? "route" : "staticIdentity", status: 0, sent: false, senderAudit: false); throw Failure.unavailable
        }
    }

    private func destinationCheck() -> DestinationCheck {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard matches.count == 1, let only = matches.first, only == manager, !manager.isTerminated,
              manager.isFinishedLaunching, manager.launchDate == launchDate,
              manager.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundleURL,
              manager.executableURL?.resolvingSymlinksInPath().path == executable else { return .route }
        var captured = CSControlManager()
        guard executable.withCString({ cs_control_capture_manager(manager.processIdentifier, $0, &captured) }) == 1 else { return .staticIdentity }
        var original = initial
        return cs_control_manager_equal(&original, &captured) == 1 ? .current : .staticIdentity
    }

    func authorization(request: Bool) async -> ControlAuthorization.Reply {
        let id = bundleID, path = executable, proof = initial
        return await ControlAuthorization.perform(request: request, targetCurrent: {
            self.destinationCheck() == .current
        }, permission: { ask in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var original = proof
                    var changed: Int32 = 0
                    let code = id.withCString { bid in
                        path.withCString { executable in
                            cs_control_authorization(bid, ask ? 1 : 0, &original, executable, &changed)
                        }
                    }
                    continuation.resume(returning: (code, changed != 0))
                }
            }
        })
    }

    func send(_ request: AutomationRequest) async throws -> AutomationReply {
        let timeout: UInt32
        if request.action.isNavigation { timeout = UInt32(AutomationLimits.navigationSeconds) + UInt32(AutomationLimits.actionSeconds) }
        else if case .openSession = request.action { timeout = UInt32(AutomationLimits.startupSeconds) + UInt32(AutomationLimits.actionSeconds) }
        else { timeout = UInt32(AutomationLimits.actionSeconds) + UInt32(AutomationLimits.actionSeconds) }
        NavigationDiagnostic.emit(request, "sender.begin")
        do {
        let start = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = start.addingReportingOverflow(UInt64(timeout) * 1_000_000_000)
        NavigationDiagnostic.emit(request, "sender.destination.before")
        let initialCheck = destinationCheck()
        NavigationDiagnostic.emit(request, "sender.destination.after")
        guard !overflow, initialCheck == .current, DispatchTime.now().uptimeNanoseconds < deadline else {
            NavigationDiagnostic.emit(request, "sender.destination.rejected", initialCheck == .route ? "route" : initialCheck == .staticIdentity ? "staticIdentity" : "deadline")
            Self.diagnostic(initialCheck == .route ? "route" : initialCheck == .staticIdentity ? "staticIdentity" : "deadline", status: 0, sent: false, senderAudit: false)
            throw Failure.unavailable
        }
        NavigationDiagnostic.emit(request, "sender.encode.before")
        let data = try AutomationCodec.encodeRequest(request)
        NavigationDiagnostic.emit(request, "sender.encode.after")
        let id = bundleID, executable = executable, initial = initial
        let (result, sent, senderAudit, phase, rawReply): (Int32, Int32, Int32, UInt32, Data) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                NavigationDiagnostic.emit(request, "sender.worker.begin")
                var output = [UInt8](repeating: 0, count: AutomationLimits.frameBytes)
                var written: UInt = 0, sent: Int32 = 0, senderAudit: Int32 = 0, phase: UInt32 = 0
                var proof = initial
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { continuation.resume(returning: (-1712, 0, 0, 0, Data())); return }
                let remaining = (deadline - now) / 1_000_000_000
                guard remaining > 0 else { continuation.resume(returning: (-1712, 0, 0, 0, Data())); return }
                var traceID = request.requestID.uuid
                NavigationDiagnostic.emit(request, "sender.native.before")
                let result: Int32 = id.withCString { bid in
                    executable.withCString { path in
                        data.withUnsafeBytes { raw in
                            output.withUnsafeMutableBufferPointer { buffer in
                                withUnsafeBytes(of: &traceID) { trace in
                                    cs_control_send_apple_event(bid, raw.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), UInt32(remaining), &proof, path, buffer.baseAddress, UInt(buffer.count), &written, &sent, &senderAudit, &phase, trace.bindMemory(to: UInt8.self).baseAddress)
                                }
                            }
                        }
                    }
                }
                NavigationDiagnostic.emit(request, "sender.native.after")
                let response = written <= output.count ? Data(output.prefix(Int(written))) : Data()
                continuation.resume(returning: (result, sent, senderAudit, phase, response))
            }
        }
        NavigationDiagnostic.emit(request, "sender.return", result == 0 && senderAudit == 1 ? "ok" : "error")
        guard result == 0, senderAudit == 1 else {
            NavigationDiagnostic.senderTransportFailure(request, phase: Self.phaseName(phase), status: result)
            Self.diagnostic(Self.phaseName(phase), status: result, sent: sent != 0, senderAudit: senderAudit == 1)
            throw sent == 0 ? Failure.unavailable : Failure.indeterminate
        }
        let finalCheck = destinationCheck()
        guard finalCheck == .current, DispatchTime.now().uptimeNanoseconds < deadline else {
            NavigationDiagnostic.emit(request, "sender.destination.rejected", finalCheck == .route ? "route" : finalCheck == .staticIdentity ? "staticIdentity" : "deadline")
            Self.diagnostic(finalCheck == .route ? "route" : finalCheck == .staticIdentity ? "staticIdentity" : "deadline", status: 0, sent: true, senderAudit: true)
            throw Failure.indeterminate
        }
        guard !rawReply.isEmpty,
              let reply = try? AutomationCodec.decodeReply(rawReply), reply.requestID == request.requestID else {
            Self.diagnostic("replyDecode", status: 0, sent: true, senderAudit: true); throw Failure.indeterminate
        }
        NavigationDiagnostic.emit(request, "sender.authenticatedReply", NavigationDiagnostic.result(reply.outcome))
        NavigationDiagnostic.emit(request, "sender.completed")
        return reply
        } catch {
            NavigationDiagnostic.emit(request, "sender.failed", Self.failureLabel(error))
            throw error
        }
    }
}
