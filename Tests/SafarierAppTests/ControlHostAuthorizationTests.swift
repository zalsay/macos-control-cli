#if SAFARIER_CONTROL_TESTING
import Foundation
import XCTest
import SafarierCore
@testable import Safarier

@MainActor
final class ControlHostAuthorizationTests: XCTestCase {
    func testExplicitAuthorizationReturnsPendingAndPollIsReadOnly() async throws {
        let profileID = UUID()
        var authorizationCalls = 0
        var completion: CheckedContinuation<ControlAuthorization.Reply, Never>?
        let broker = ControlBroker(testSender: { _ in throw ControlAppleEventClient.Failure.unavailable },
            testAuthorization: { request in
                authorizationCalls += 1
                XCTAssertTrue(request)
                return await withCheckedContinuation { completion = $0 }
            }, testHostProfileID: profileID)

        let requestID = UUID()
        let dispatched = try reply(await broker.handle(ControlRequest(requestID: requestID, operation: .authorizationRequest)))
        let pending = try XCTUnwrap(dispatched.authorization)
        XCTAssertEqual(dispatched.status, "ok")
        XCTAssertEqual(pending.requestID, requestID)
        XCTAssertEqual(pending.status, "pending")
        XCTAssertNil(pending.osStatus)
        XCTAssertFalse(pending.businessEventSent)

        for _ in 0..<10 where authorizationCalls == 0 { await Task.yield() }
        XCTAssertEqual(authorizationCalls, 1)

        let duplicateID = UUID()
        let duplicate = try reply(await broker.handle(ControlRequest(requestID: duplicateID, operation: .authorizationRequest)))
        XCTAssertEqual(duplicate.authorization?.requestID, requestID)
        XCTAssertEqual(duplicate.authorization?.status, "pending")
        XCTAssertEqual(authorizationCalls, 1, "a repeated request must not create another macOS prompt")

        let statusID = UUID()
        let stillPending = try reply(await broker.handle(ControlRequest(requestID: statusID, operation: .authorizationStatus(requestID: requestID))))
        XCTAssertEqual(stillPending.authorization, pending)
        let stopID = UUID()
        let stopped = try reply(await broker.handle(ControlRequest(requestID: stopID, operation: .daemonStop)))
        XCTAssertEqual(stopped.error, "SESSION_BUSY")
        XCTAssertFalse(broker.claimStopCommit())

        completion?.resume(returning: ControlAuthorization.Reply(status: "allowed", osStatus: 0))
        var completed: HostAuthorizationReceipt?
        for _ in 0..<100 {
            await Task.yield()
            let status = try reply(await broker.handle(ControlRequest(requestID: UUID(), operation: .authorizationStatus(requestID: requestID))))
            completed = status.authorization
            if completed?.status != "pending" { break }
        }
        let receipt = try XCTUnwrap(completed)
        XCTAssertEqual(receipt.status, "allowed")
        XCTAssertEqual(receipt.osStatus, 0)
        XCTAssertFalse(receipt.businessEventSent)
        XCTAssertTrue(receipt.statusDescription.contains("历史回执"))
        XCTAssertEqual(authorizationCalls, 1)
    }

    func testIdleStopCommitsOnceEvenWhenRequestIsReplayed() async throws {
        let broker = ControlBroker(testSender: { _ in throw ControlAppleEventClient.Failure.unavailable })
        XCTAssertFalse(broker.claimStopCommit())

        let request = ControlRequest(requestID: UUID(), operation: .daemonStop)
        let accepted = try reply(await broker.handle(request))
        XCTAssertEqual(accepted.status, "ok")
        XCTAssertTrue(broker.claimStopCommit())

        let replayed = try reply(await broker.handle(request))
        XCTAssertEqual(replayed.status, "ok")
        XCTAssertFalse(broker.claimStopCommit())
        let laterStatus = try reply(await broker.handle(ControlRequest(requestID: UUID(), operation: .status)))
        XCTAssertEqual(laterStatus.error, "SESSION_BUSY")
    }

    func testAuthorizationCannotRunOutsideDedicatedHostRuntime() async throws {
        var authorizationCalls = 0
        let broker = ControlBroker(testSender: { _ in throw ControlAppleEventClient.Failure.unavailable },
            testAuthorization: { _ in authorizationCalls += 1; return ControlAuthorization.Reply(status: "allowed", osStatus: 0) })
        let result = try reply(await broker.handle(ControlRequest(requestID: UUID(), operation: .authorizationRequest)))
        XCTAssertEqual(result.status, "error")
        XCTAssertEqual(result.error, "HOST_PROFILE_REQUIRED")
        XCTAssertNil(result.authorization)
        XCTAssertEqual(authorizationCalls, 0)
    }

    private func reply(_ value: (Data, UUID?)) throws -> ControlBrokerReply {
        try JSONDecoder().decode(ControlBrokerReply.self, from: value.0)
    }
}
#endif
