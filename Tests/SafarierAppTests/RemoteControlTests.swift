import Foundation
import XCTest
import SafarierCore
@testable import Safarier

@MainActor
final class RemoteControlTests: XCTestCase {
    private let allowedProfile = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let otherProfile = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    func testRemoteAllowlistRejectsHostFilesAndManagement() throws {
        let connection = UUID()
        let frame = UUID()
        XCTAssertFalse(RemoteControlPolicy.permits(.selectFile(connection: connection, paths: ["/tmp/secret"])))
        XCTAssertFalse(RemoteControlPolicy.permits(.daemonStop))
        XCTAssertFalse(RemoteControlPolicy.permits(.daemonStart))
        XCTAssertFalse(RemoteControlPolicy.permits(.daemonServe))
        XCTAssertFalse(RemoteControlPolicy.permits(.authorizationRequest))
        XCTAssertFalse(RemoteControlPolicy.permits(.authorizationStatus(requestID: UUID())))
        XCTAssertFalse(RemoteControlPolicy.permits(.typeFromStdin(connection: connection, frame: frame)))
        XCTAssertFalse(RemoteControlPolicy.permits(.navigate(connection: connection, url: URL(string: "file:///etc/passwd")!)))
        XCTAssertTrue(RemoteControlPolicy.permits(.navigate(connection: connection, url: URL(string: "https://example.com/path")!)))
        XCTAssertFalse(RemoteControlPolicy.clientOptionsAllowed(ControlOptions(applicationPath: "/tmp/other.app")))
        XCTAssertFalse(RemoteControlPolicy.clientOptionsAllowed(ControlOptions(runtimePath: "/tmp/other-runtime")))
        XCTAssertTrue(RemoteControlPolicy.clientOptionsAllowed(ControlOptions()))
    }

    func testSSHArgumentsAreFixedAndRejectOptionOrShellInjection() throws {
        let args = try RemoteSSHTransport.arguments(alias: "laptop.example")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("ControlMaster=no"))
        XCTAssertTrue(args.contains("ControlPath=none"))
        XCTAssertTrue(args.contains("ForwardAgent=no"))
        XCTAssertTrue(args.contains("ForwardX11=no"))
        XCTAssertEqual(args.suffix(3), ["--", "laptop.example", "sfa host serve"])
        for injected in ["--help", "host;touch /tmp/pwned", "host name", "-oProxyCommand=bad", "host\ncommand"] {
            XCTAssertThrowsError(try RemoteSSHTransport.arguments(alias: injected), injected)
        }
    }

    func testHostRejectsDifferentProfileBeforeCallingDaemon() throws {
        let request = ControlRequest(requestID: UUID(), operation: .connect(profileID: otherProfile))
        var calls = 0
        let reply = RemoteHostExecutor.execute(request, allowedProfile: allowedProfile) { _ in
            calls += 1
            return ControlBrokerReply(request.requestID, status: "ok")
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(reply.status, "error")
        XCTAssertEqual(reply.error, "PROFILE_NOT_ALLOWED")
        XCTAssertEqual(reply.requestID, request.requestID)
    }

    func testHostRejectsFileAndSelectFileOperationsBeforeDaemon() throws {
        let connection = UUID()
        let requests = [
            ControlRequest(requestID: UUID(), operation: .navigate(connection: connection, url: URL(string: "file:///Users/host/private.txt")!)),
            ControlRequest(requestID: UUID(), operation: .selectFile(connection: connection, paths: ["/Users/host/private.txt"])),
            ControlRequest(requestID: UUID(), operation: .daemonStop),
        ]
        for request in requests {
            var calls = 0
            let reply = RemoteHostExecutor.execute(request, allowedProfile: allowedProfile) { _ in
                calls += 1
                return ControlBrokerReply(request.requestID, status: "ok")
            }
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(reply.status, "error")
            XCTAssertEqual(reply.error, "REMOTE_OPERATION_NOT_ALLOWED")
        }
    }

    func testConnectionIsCheckedAgainstBoundProfileBeforeAction() throws {
        let connection = UUID()
        let original = ControlRequest(requestID: UUID(), operation: .observe(connection: connection))
        var seen: [ControlOperation] = []
        let reply = RemoteHostExecutor.execute(original, allowedProfile: allowedProfile) { request in
            seen.append(request.operation)
            return stateReply(request, profile: otherProfile, url: URL(string: "https://example.com")!)
        }
        XCTAssertEqual(seen.count, 1)
        guard case .state = seen[0] else { return XCTFail("expected profile preflight") }
        XCTAssertEqual(reply.error, "PROFILE_NOT_ALLOWED")
        XCTAssertEqual(reply.requestID, original.requestID)
    }

    func testAllowedOperationUsesOriginalRequestIDAndStripsScreenshotPath() throws {
        let connection = UUID()
        let original = ControlRequest(requestID: UUID(), operation: .observe(connection: connection))
        var seen: [ControlRequest] = []
        let reply = RemoteHostExecutor.execute(original, allowedProfile: allowedProfile) { request in
            seen.append(request)
            if case .state = request.operation {
                return stateReply(request, profile: allowedProfile, url: URL(string: "https://example.com")!)
            }
            var response = ControlBrokerReply(request.requestID, status: "ok")
            response.frame = UUID()
            response.screenshotPath = "/Users/host/Library/Caches/screenshot.png"
            return response
        }
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[1].requestID, original.requestID)
        XCTAssertNil(reply.screenshotPath)
        XCTAssertEqual(reply.remoteScreenshotUnavailable, true)
        XCTAssertNotNil(reply.frame)
    }

    func testRequestAndReplyAreVersionedAndRequestIDBound() throws {
        let request = ControlRequest(requestID: UUID(), operation: .status)
        let payload = try ControlProtocol.encodeRequest(request)
        XCTAssertEqual(try ControlProtocol.decodeRequest(payload), request)
        let reply = ControlBrokerReply(request.requestID, status: "error", error: "UNAVAILABLE")
        let encoded = try JSONEncoder().encode(reply)
        XCTAssertEqual(try ControlCLI.decodeReply(encoded, requestID: request.requestID).error, "UNAVAILABLE")
        XCTAssertThrowsError(try ControlCLI.decodeReply(encoded, requestID: UUID()))

        let invalidVersion = Data("{\"version\":2,\"requestID\":\"\(UUID().uuidString)\",\"operation\":\"status\",\"parameters\":{}}".utf8)
        XCTAssertThrowsError(try ControlProtocol.decodeRequest(invalidVersion))
    }

    func testAuthorizationOperationsAreStrictlyVersionedAndRoundTrip() throws {
        let authorizationID = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
        for operation in [ControlOperation.authorizationRequest, .authorizationStatus(requestID: authorizationID)] {
            let request = ControlRequest(requestID: UUID(), operation: operation)
            XCTAssertEqual(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(request)), request)
        }
        let requestID = UUID().uuidString
        let malformed = [
            "{\"version\":1,\"requestID\":\(requestID),\"operation\":\"authorizationStatus\",\"parameters\":{\"requestID\":\"\(authorizationID.uuidString)\"}}",
            "{\"version\":1,\"requestID\":\"\(requestID)\",\"operation\":\"authorizationStatus\",\"parameters\":{\"requestID\":17}}",
            "{\"version\":1,\"requestID\":\"\(requestID)\",\"operation\":\"authorizationStatus\",\"parameters\":{\"requestID\":\"not-a-uuid\"}}",
            "not-json",
        ]
        for raw in malformed { XCTAssertThrowsError(try ControlProtocol.decodeRequest(Data(raw.utf8)), raw) }
    }

    func testScreenshotPathIsAbsentFromSerializedRemoteReply() throws {
        var original = ControlBrokerReply(UUID(), status: "ok")
        original.screenshotPath = "/Users/host/private/frame.png"
        let sanitized = RemoteControlPolicy.sanitizedRemoteReply(original)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sanitized)) as? [String: Any])
        XCTAssertNil(value["screenshotPath"])
        XCTAssertEqual(value["remoteScreenshotUnavailable"] as? Bool, true)
        XCTAssertEqual(original.screenshotPath, "/Users/host/private/frame.png")
    }

    func testProfileRuntimeIsDedicatedAndCanonical() {
        let path = RemoteHostRuntime.path(for: allowedProfile, home: "/Users/host")
        XCTAssertEqual(path, "/Users/host/.safarier-control-host-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(RemoteHostRuntime.profileID(runtimePath: path, home: "/Users/host"), allowedProfile)
        XCTAssertNil(RemoteHostRuntime.profileID(runtimePath: path + "/..", home: "/Users/host"))
        XCTAssertNil(RemoteHostRuntime.profileID(runtimePath: "/tmp/safarier-control-host-\(allowedProfile.uuidString.lowercased())", home: "/Users/host"))
    }

    private func stateReply(_ request: ControlRequest, profile: UUID, url: URL?) -> ControlBrokerReply {
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let state = AutomationState(target: target, url: url, loading: false, sessionState: .ready, viewVersion: 1)
        var reply = ControlBrokerReply(request.requestID, status: "ok")
        reply.state = state
        return reply
    }
}
