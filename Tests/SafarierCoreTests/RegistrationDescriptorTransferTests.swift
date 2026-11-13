import XCTest
import Darwin
@testable import SafarierCore

#if SAFARIER_BOUND_LOCAL_CANDIDATE
final class RegistrationDescriptorTransferTests: XCTestCase {
    private func pair() throws -> (FileHandle, FileHandle) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true), FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    func testTransfersOnlyConnectedSocketAndClosesOnExec() throws {
        let (sender, receiver) = try pair(), (local, remote) = try pair()
        defer { try? sender.close(); try? receiver.close(); try? local.close(); try? remote.close() }
        try RegistrationDescriptorTransfer.send(stream: sender, descriptor: remote, timeout: 1)
        let received = try RegistrationDescriptorTransfer.receive(stream: receiver, timeout: 1)
        defer { try? received.close() }
        XCTAssertNotEqual(fcntl(received.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        try received.write(contentsOf: Data([0x51]))
        XCTAssertEqual(try local.read(upToCount: 1), Data([0x51]))
    }

    func testFailureInvalidatesTransport() throws {
        let (sender, receiver) = try pair()
        defer { try? sender.close(); try? receiver.close() }
        XCTAssertThrowsError(try RegistrationDescriptorTransfer.send(stream: sender, descriptor: .nullDevice, timeout: 1))
        XCTAssertNil(try receiver.read(upToCount: 1))
        XCTAssertThrowsError(try RegistrationDescriptorTransfer.receive(stream: receiver, timeout: 0))
    }

    func testChannelTransfersDescriptorUnderExclusiveReader() async throws {
        let root = try AutomationChannel.makePair()
        let peer = try AutomationChannel(adopting: root.child)
        let reader = try peer.claimExclusiveReader()
        let (local, remote) = try pair()
        defer { root.parent.close(); peer.close(); try? local.close(); try? remote.close() }
        try await root.parent.sendRegisteredDescriptor(remote, timeout: 1)
        let received = try await reader.receiveRegisteredDescriptor(timeout: 1)
        defer { try? received.close() }
        try received.write(contentsOf: Data([0x42]))
        XCTAssertEqual(try local.read(upToCount: 1), Data([0x42]))
    }

    func testFreshFrameDeadlineAllowsDescriptorSend() async throws {
        let root = try AutomationChannel.makePair()
        let peer = try AutomationChannel(adopting: root.child)
        let reader = try peer.claimExclusiveReader()
        let (local, remote) = try pair()
        defer { root.parent.close(); peer.close(); try? local.close(); try? remote.close() }
        let deadline = try RegistrationFrame.deadline()
        try await root.parent.sendRegisteredDescriptor(remote, timeout: try RegistrationFrame.descriptorTimeout(deadline))
        let received = try await reader.receiveRegisteredDescriptor(timeout: 1)
        defer { try? received.close() }
        try received.write(contentsOf: Data([0x53]))
        XCTAssertEqual(try local.read(upToCount: 1), Data([0x53]))
    }

    func testFreshFrameDeadlineAllowsDescriptorReceive() async throws {
        let root = try AutomationChannel.makePair()
        let peer = try AutomationChannel(adopting: root.child)
        let reader = try peer.claimExclusiveReader()
        let (local, remote) = try pair()
        defer { root.parent.close(); peer.close(); try? local.close(); try? remote.close() }
        try await root.parent.sendRegisteredDescriptor(remote, timeout: 1)
        let deadline = try RegistrationFrame.deadline()
        let received = try await reader.receiveRegisteredDescriptor(timeout: try RegistrationFrame.descriptorTimeout(deadline))
        defer { try? received.close() }
        try received.write(contentsOf: Data([0x52]))
        XCTAssertEqual(try local.read(upToCount: 1), Data([0x52]))
    }

    func testDirectTransfersRejectTimeoutBeyondFiveSeconds() throws {
        let (sender, receiver) = try pair(), (local, remote) = try pair()
        defer { try? sender.close(); try? receiver.close(); try? local.close(); try? remote.close() }
        XCTAssertThrowsError(try RegistrationDescriptorTransfer.send(stream: sender, descriptor: remote, timeout: 5.001)) {
            guard case RegistrationDescriptorTransfer.Failure.invalidTimeout = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try RegistrationDescriptorTransfer.receive(stream: receiver, timeout: 5.001)) {
            guard case RegistrationDescriptorTransfer.Failure.invalidTimeout = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testEpochCannotReplayOrBeEvictedAtCapacity() {
        var history = RegistrationEpochHistory(capacity: 2)
        let first = UUID(), second = UUID()
        XCTAssertTrue(history.accept(first))
        XCTAssertFalse(history.accept(first))
        XCTAssertTrue(history.accept(second))
        XCTAssertFalse(history.accept(first))
        XCTAssertFalse(history.accept(UUID()))
        XCTAssertNotEqual(RegistrationFrame.nonce(first), RegistrationFrame.nonce(second))
        XCTAssertTrue(AutomationSessionToken.isCanonical(RegistrationFrame.nonce(first)))
    }

    func testRetainedBrowserReceiptRoundTripKeepsOwnedCleanupFalse() throws {
        let target = AutomationTargetIdentity(profileID: UUID(), runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let retained = RetainedBrowserCleanup(target: target, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true)
        let receipt = CleanupReceipt(cleaned: false, terminatedOwnedRunner: false, retainedBrowser: retained)
        let reply = AutomationReply(requestID: UUID(), outcome: .success(.sessionClosed(receipt)))
        XCTAssertEqual(try AutomationCodec.decodeReply(AutomationCodec.encode(reply)), reply)
        XCTAssertTrue(retained.confirmed)
        XCTAssertFalse(RetainedBrowserCleanup(target: target, inputReleased: true, artifactsCleaned: false, browserRetained: true, manualInteractionEnabled: true).confirmed)
        let encoded = try AutomationCodec.encode(reply)
        for (cleaned, terminated) in [(true, false), (false, true), (true, true)] {
            let contradictory = AutomationReply(requestID: UUID(), outcome: .success(.sessionClosed(
                CleanupReceipt(cleaned: cleaned, terminatedOwnedRunner: terminated, retainedBrowser: retained))))
            XCTAssertThrowsError(try AutomationCodec.encode(contradictory))
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var result = try XCTUnwrap(root["result"] as? [String: Any])
            result["cleaned"] = cleaned; result["terminatedOwnedRunner"] = terminated
            root["result"] = result
            XCTAssertThrowsError(try AutomationCodec.decodeReply(JSONSerialization.data(withJSONObject: root)))
        }
    }
}
#endif
