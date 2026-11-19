import XCTest
import SafarierCore
@testable import Safarier

final class ManagerRemoteHostTests: XCTestCase {
    func testHostCommandsUseDedicatedRuntimeForTheSelectedProfile() {
        let first = UUID(uuidString: "A1234567-89AB-CDEF-0123-456789ABCDEF")!
        let second = UUID(uuidString: "B1234567-89AB-CDEF-0123-456789ABCDEF")!
        let app = "/Applications/Safarier.app"

        let start = ManagerHostDaemonService.arguments(for: .start, applicationPath: app, profileID: first)
        let status = ManagerHostDaemonService.arguments(for: .status, applicationPath: app, profileID: second)
        let stop = ManagerHostDaemonService.arguments(for: .stop, applicationPath: app, profileID: first)

        XCTAssertEqual(start, ["control", "daemon", "serve", "--app", app, "--runtime", RemoteHostRuntime.path(for: first)])
        XCTAssertEqual(status, ["control", "status", "--app", app, "--runtime", RemoteHostRuntime.path(for: second)])
        XCTAssertEqual(stop, ["control", "daemon", "stop", "--app", app, "--runtime", RemoteHostRuntime.path(for: first)])
        XCTAssertNotEqual(start.last, status.last, "不同 profile 必须使用隔离的 runtime")
    }

    func testRevokingAgentAccessBlocksStartButKeepsStatusAndStopAvailable() {
        let allowed = Profile(name: "allowed", mode: .ephemeral, allowsAgentAccess: true)
        let revoked = Profile(name: "revoked", mode: .ephemeral, allowsAgentAccess: false)

        XCTAssertTrue(ManagerHostMenuPolicy.enabled(.start, profile: allowed, busy: false))
        XCTAssertFalse(ManagerHostMenuPolicy.enabled(.start, profile: revoked, busy: false))
        XCTAssertTrue(ManagerHostMenuPolicy.enabled(.status, profile: revoked, busy: false))
        XCTAssertTrue(ManagerHostMenuPolicy.enabled(.stop, profile: revoked, busy: false))
        XCTAssertFalse(ManagerHostMenuPolicy.enabled(.status, profile: allowed, busy: true))
        XCTAssertFalse(ManagerHostMenuPolicy.enabled(.status, profile: nil, busy: false))
    }
}
