#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Darwin
import Foundation
import XCTest
@testable import SafarierCore

final class RegisteredRunnerRendezvousTests: XCTestCase {
    func testRendezvousIsScopedToWorkspaceProfileAndProcessBirth() throws {
        let profile = UUID()
        let a = SafarierWorkspace(root: URL(fileURLWithPath: "/test/a"))
        let b = SafarierWorkspace(root: URL(fileURLWithPath: "/test/b"))
        let first = try RegisteredRunnerRendezvous(workspace: a, profileID: profile, pid: 42, birth: 5, micros: 8)
        XCTAssertEqual(first.path, try RegisteredRunnerRendezvous(workspace: a, profileID: profile, pid: 42, birth: 5, micros: 8).path)
        XCTAssertNotEqual(first.path, try RegisteredRunnerRendezvous(workspace: b, profileID: profile, pid: 42, birth: 5, micros: 8).path)
        XCTAssertNotEqual(first.path, try RegisteredRunnerRendezvous(workspace: a, profileID: UUID(), pid: 42, birth: 5, micros: 8).path)
        XCTAssertNotEqual(first.path, try RegisteredRunnerRendezvous(workspace: a, profileID: profile, pid: 42, birth: 5, micros: 9).path)
    }

    func testPathCannotBeStolenOrRemovedBySecondListener() async throws {
        let endpoint = try RegisteredRunnerRendezvous(workspace: SafarierWorkspace(root: URL(fileURLWithPath: "/test/a")), profileID: UUID(), pid: getpid(), birth: 5, micros: 8)
        let listener = try endpoint.listen()
        XCTAssertThrowsError(try endpoint.listen())
        let client = try endpoint.connect()
        let server = try await listener.accept()
        defer { client.close(); server.close() }
        let frame = Data("registration-test".utf8)
        try await client.send(frame)
        let arrived = try await server.receive()
        XCTAssertEqual(arrived, frame)
    }
}
#endif
