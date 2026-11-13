#if SAFARIER_CONTROL_TESTING
import XCTest
import Darwin
import Foundation
import SafarierCore
@testable import Safarier

@MainActor final class ControlDisconnectAcknowledgementTests: XCTestCase {
    @MainActor private final class Fixture {
        let profile = UUID()
        let token = String(repeating: "A", count: 43)
        let runner = UUID(), window = UUID(), page = UUID()
        var closeCalls = 0
        var pendingClose: CheckedContinuation<Void, Never>?
        var pendingState: CheckedContinuation<Void, Never>?
        var holdClose = false
        var cleanupSuccess = true
        var target: AutomationTargetIdentity { AutomationTargetIdentity(profileID: profile, runnerInstanceID: runner, windowID: window, pageID: page) }
        var viewport: AutomationViewport { AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1) }
        func broker() -> ControlBroker {
            ControlBroker(testSender: { request in
                let result: AutomationResult
                switch request.action {
                case .openSession: result = .sessionOpened(sessionID: self.token, target: self.target, viewport: self.viewport)
                case .getState:
                    await withCheckedContinuation { self.pendingState = $0 }
                    result = .stateRead(AutomationState(target: self.target, url: nil, loading: false, sessionState: .ready, viewVersion: 1))
                case .closeSession, .cancel:
                    XCTAssertEqual(request.sessionID, self.token)
                    self.closeCalls += 1
                    if self.holdClose { await withCheckedContinuation { self.pendingClose = $0 } }
                    let retained = self.cleanupSuccess ? RetainedBrowserCleanup(target: self.target, inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true) : nil
                    result = .sessionClosed(CleanupReceipt(cleaned: false, terminatedOwnedRunner: false, retainedBrowser: retained))
                default: throw AutomationError(code: .invalidRequest)
                }
                return AutomationReply(requestID: request.requestID, outcome: .success(result))
            })
        }
    }
    private func send(_ broker: ControlBroker, _ request: ControlRequest) async throws -> (ControlBrokerReply, UUID?) {
        let (data, ack) = await broker.handle(request)
        return (try JSONDecoder().decode(ControlBrokerReply.self, from: data), ack)
    }
    private func request(_ operation: ControlOperation) -> ControlRequest { ControlRequest(requestID: UUID(), operation: operation) }
    private func connect(_ fixture: Fixture, _ broker: ControlBroker) async throws -> UUID {
        let (reply, ack) = try await send(broker, request(.connect(profileID: fixture.profile)))
        let connection = try XCTUnwrap(reply.connection)
        broker.acknowledgement(try XCTUnwrap(ack), received: true)
        return connection
    }
    func testDisconnectAckControlsStopAndLostAckFailsClosed() async throws {
        for received in [true, false] {
            let fixture = Fixture(), broker = fixture.broker()
            let connection = try await connect(fixture, broker)
            let (closed, ack) = try await send(broker, request(.disconnect(connection: connection)))
            XCTAssertEqual(closed.status, "ok")
            XCTAssertEqual(closed.retainedBrowser?.target, fixture.target)
            let ackID = try XCTUnwrap(ack)
            let (before, _) = try await send(broker, request(.daemonStop))
            XCTAssertEqual(before.error, "SESSION_BUSY")
            broker.acknowledgement(ackID, received: received)
            let (after, _) = try await send(broker, request(.daemonStop))
            XCTAssertEqual(after.status, received ? "ok" : "error")
            if !received { XCTAssertEqual(after.error, "SESSION_BUSY") }
            let (state, _) = try await send(broker, request(.state(connection: connection)))
            XCTAssertEqual(state.error, received ? "SESSION_BUSY" : "SESSION_NOT_FOUND")
            XCTAssertEqual(fixture.closeCalls, 1)
        }
    }
    func testCancelAckControlsStopAndLostAckFailsClosed() async throws {
        for received in [true, false] {
            let fixture = Fixture(), broker = fixture.broker()
            let connection = try await connect(fixture, broker)
            let cancel = request(.cancel(connection: connection))
            let (closed, ack) = try await send(broker, cancel)
            XCTAssertEqual(closed.status, "ok")
            XCTAssertEqual(closed.retainedBrowser?.target, fixture.target)
            let ackID = try XCTUnwrap(ack)
            let (replay, replayAck) = try await send(broker, cancel)
            XCTAssertEqual(replay.status, "ok")
            XCTAssertNil(replayAck)
            let (before, _) = try await send(broker, request(.daemonStop))
            XCTAssertEqual(before.error, "SESSION_BUSY")
            broker.acknowledgement(ackID, received: received)
            let (after, _) = try await send(broker, request(.daemonStop))
            XCTAssertEqual(after.status, received ? "ok" : "error")
            if !received { XCTAssertEqual(after.error, "SESSION_BUSY") }
            XCTAssertEqual(fixture.closeCalls, 1)
        }
    }
    func testUnconfirmedCancelDoesNotCreateAcknowledgement() async throws {
        let fixture = Fixture(), broker = fixture.broker()
        let connection = try await connect(fixture, broker)
        fixture.cleanupSuccess = false
        let (closed, ack) = try await send(broker, request(.cancel(connection: connection)))
        XCTAssertEqual(closed.error, "CLEANUP_UNCONFIRMED")
        XCTAssertNil(ack)
        let (stop, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(stop.error, "SESSION_BUSY")
    }
    func testConcurrentAndRepeatedDisconnectUsesOneCloseAndKeepsOriginalAck() async throws {
        let fixture = Fixture(), broker = fixture.broker()
        let connection = try await connect(fixture, broker)
        fixture.holdClose = true
        let close = request(.disconnect(connection: connection))
        let task = Task { try await self.send(broker, close) }
        while fixture.pendingClose == nil { await Task.yield() }
        let (duplicate, duplicateAck) = try await send(broker, close)
        XCTAssertEqual(duplicate.error, "SESSION_BUSY")
        XCTAssertNil(duplicateAck)
        let (stopDuring, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(stopDuring.error, "SESSION_BUSY")
        fixture.pendingClose?.resume()
        let (closed, ack) = try await task.value
        XCTAssertEqual(closed.status, "ok")
        let (replayed, replayAck) = try await send(broker, close)
        XCTAssertEqual(replayed.status, "ok")
        XCTAssertNil(replayAck)
        XCTAssertEqual(fixture.closeCalls, 1)
        let (stopBeforeAck, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(stopBeforeAck.error, "SESSION_BUSY")
        broker.acknowledgement(try XCTUnwrap(ack), received: true)
        let (stopAfterAck, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(stopAfterAck.status, "ok")
    }
    func testCancelRemainsReservedWhileDisconnectIsInFlight() async throws {
        let fixture = Fixture(), broker = fixture.broker()
        let connection = try await connect(fixture, broker)
        fixture.holdClose = true
        let task = Task { try await self.send(broker, self.request(.disconnect(connection: connection))) }
        while fixture.pendingClose == nil { await Task.yield() }
        fixture.holdClose = false
        let (cancelled, cancelAck) = try await send(broker, request(.cancel(connection: connection)))
        XCTAssertEqual(cancelled.status, "ok")
        let ack = try XCTUnwrap(cancelAck)
        XCTAssertEqual(fixture.closeCalls, 2)
        fixture.pendingClose?.resume()
        let (closed, closeAck) = try await task.value
        XCTAssertEqual(closed.error, "SESSION_NOT_FOUND")
        XCTAssertNil(closeAck)
        let (before, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(before.error, "SESSION_BUSY")
        broker.acknowledgement(ack, received: true)
        let (after, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(after.status, "ok")
    }
    func testDisconnectAckDoesNotClearAnotherInFlightAcknowledgement() async throws {
        let fixture = Fixture(), broker = fixture.broker()
        let connection = try await connect(fixture, broker)
        let stateTask = Task { try await self.send(broker, self.request(.state(connection: connection))) }
        while fixture.pendingState == nil { await Task.yield() }
        let (closed, closeAck) = try await send(broker, request(.disconnect(connection: connection)) )
        XCTAssertEqual(closed.status, "ok")
        broker.acknowledgement(try XCTUnwrap(closeAck), received: true)
        let (before, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(before.error, "SESSION_BUSY")
        fixture.pendingState?.resume()
        let (state, stateAck) = try await stateTask.value
        XCTAssertEqual(state.error, "SESSION_NOT_FOUND")
        broker.acknowledgement(try XCTUnwrap(stateAck), received: true)
        let (after, _) = try await send(broker, request(.daemonStop))
        XCTAssertEqual(after.status, "ok")
    }
    func testRealSocketHandshakeAcknowledgesOrLosesDisconnectReply() async throws {
        for acknowledge in [true, false] {
            let fixture = Fixture(), broker = fixture.broker()
            let connection = try await connect(fixture, broker)
            var fds: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
            let serverFD = fds[0], clientFD = fds[1], instance = UUID()
            do { _ = try ControlRuntime.peer(serverFD); _ = try ControlRuntime.peer(clientFD) }
            catch {
                Darwin.close(serverFD); Darwin.close(clientFD)
                throw XCTSkip("XCTest host did not pass the real socket peer identity gate")
            }
            let close = request(.disconnect(connection: connection))
            let server = Task.detached {
                defer { Darwin.close(serverFD) }
                let (request, peer, hello) = try ControlRuntime.serverReceive(serverFD, instance: instance)
                let (reply, ack) = await broker.handle(request)
                var received = false
                do { try ControlRuntime.serverReply(serverFD, reply: reply, peer: peer, hello: hello); received = true } catch { }
                if let ack { await broker.acknowledgement(ack, received: received) }
                return received
            }
            let client = Task.detached {
                defer { Darwin.close(clientFD) }
                if acknowledge {
                    return try ControlRuntime.clientExchange(clientFD, request: close, instance: instance, validatePath: {}, validateReply: { _ in })
                }
                let hello = try ControlProtocol.encodeHello(ControlHello(nonce: UUID(), instance: instance))
                try ControlRuntime.sendFrame(clientFD, hello)
                _ = try ControlRuntime.receiveFrame(clientFD)
                try ControlRuntime.sendFrame(clientFD, ControlProtocol.encodeRequest(close))
                return try ControlRuntime.receiveFrame(clientFD)
            }
            let reply = try JSONDecoder().decode(ControlBrokerReply.self, from: await client.value)
            XCTAssertEqual(reply.status, "ok")
            let delivered = try await server.value
            XCTAssertEqual(delivered, acknowledge)
            let (stop, _) = try await send(broker, request(.daemonStop))
            XCTAssertEqual(stop.status, acknowledge ? "ok" : "error")
            if !acknowledge { XCTAssertEqual(stop.error, "SESSION_BUSY") }
        }
    }
}
#endif
