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

    func testAcknowledgedGenerationSurvivesSenderCloseAndDelayedHelloRead() async throws {
        let root = try AutomationChannel.makePair()
        let peer = try AutomationChannel(adopting: root.child)
        let reader = try peer.claimExclusiveReader()
        defer { root.parent.close(); peer.close() }
        for _ in 0..<1000 {
            let generation = try AutomationChannel.makePair()
            generation.parent.labelRegistration(.generationManager)
            defer { generation.parent.close() }
            try await root.parent.sendRegisteredDescriptor(generation.child, timeout: 1)
            let received = try await reader.receiveRegisteredDescriptor(timeout: 1)
            let runner = try AutomationChannel(adopting: received)
            runner.labelRegistration(.generationRunner)
            defer { runner.close() }
            let runnerReader = try runner.claimExclusiveReader()
            let epoch = UUID()
            try await peer.send(RegistrationFrame.make("accepted", epoch))
            let ack = try await AutomationChannelDeadline.run(channel: root.parent, seconds: 1) {
                try await root.parent.receive()
            }
            XCTAssertEqual(try RegistrationFrame.read(XCTUnwrap(ack), kind: "accepted"), epoch)
            try generation.child.close()
            let hello = try AutomationHandshakeCodec.makeChallenge(profileID: UUID(), nonce: AutomationSessionToken.generate())
            try await generation.parent.send(hello)
            // Installation opens/closes many unrelated descriptors before hello.
            for _ in 0..<128 {
                let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(fd, 0)
                if fd >= 0 { Darwin.close(fd) }
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            let observed = try await AutomationChannelDeadline.run(channel: runner, seconds: 1) {
                try await runnerReader.receive()
            }
            XCTAssertEqual(observed, hello)
            try await runner.send(Data([0x52]))
            let reply = try await AutomationChannelDeadline.run(channel: generation.parent, seconds: 1) {
                try await generation.parent.receive()
            }
            XCTAssertEqual(reply, Data([0x52]))
        }
    }

    func testAcknowledgedGenerationTransferToAnotherProcessSurvivesSenderClose() async throws {
        let root = try AutomationChannel.makePair()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import socket, array, struct, os, fcntl
        root = socket.socket(fileno=0)
        marker, ancillary, flags, address = root.recvmsg(1, socket.CMSG_SPACE(4))
        assert marker == b'G' and len(ancillary) == 1
        descriptors = array.array('i'); descriptors.frombytes(ancillary[0][2])
        assert len(descriptors) == 1
        adopted = fcntl.fcntl(descriptors[0], fcntl.F_DUPFD_CLOEXEC, 0)
        os.close(descriptors[0])
        generation = socket.socket(fileno=adopted); generation.settimeout(2)
        root.sendall(struct.pack('!I', 1) + b'A')
        def exact(n):
            data = b''
            while len(data) < n:
                chunk = generation.recv(n-len(data))
                assert chunk, 'unexpected generation EOF'
                data += chunk
            return data
        size = struct.unpack('!I', exact(4))[0]
        assert size == 1 and exact(size) == b'H'
        generation.sendall(struct.pack('!I', 1) + b'R')
        """]
        process.standardInput = root.child
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        try root.child.close()
        defer { root.parent.close(); if process.isRunning { process.terminate() } }
        let generation = try AutomationChannel.makePair()
        defer { generation.parent.close() }
        try await root.parent.sendRegisteredDescriptor(generation.child, timeout: 1)
        let adopted = try await AutomationChannelDeadline.run(channel: root.parent, seconds: 2) {
            try await root.parent.receive()
        }
        XCTAssertEqual(adopted, Data([0x41]))
        try generation.child.close()
        // The real failure occurs when Runner reads before Manager sends hello.
        try await Task.sleep(nanoseconds: 100_000_000)
        try await generation.parent.send(Data([0x48]))
        let reply = try await AutomationChannelDeadline.run(channel: generation.parent, seconds: 2) {
            try await generation.parent.receive()
        }
        XCTAssertEqual(reply, Data([0x52]))
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
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
