#if SAFARIER_CONTROL_TESTING
import Foundation
import XCTest
import SafarierCore
@testable import Safarier

@MainActor final class ControlExecutionReceiptTests: XCTestCase {
    @MainActor private final class Fixture {
        let profile = UUID()
        lazy var target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        var width = 100
        var version: UInt64 = 1
        var calls: [AutomationRequest] = []
        var viewport: AutomationViewport {
            AutomationViewport(viewportWidthPoints: Double(width), viewportHeightPoints: 100,
                pixelWidth: width * 2, pixelHeight: 200, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: version)
        }
        lazy var broker = ControlBroker(testSender: { request in
            self.calls.append(request)
            let result: AutomationResult
            switch request.action {
            case .openSession: result = .sessionOpened(sessionID: String(repeating: "A", count: 43), target: self.target, viewport: self.viewport)
            case .screenshot: result = .snapshotWritten(path: "/fixture", viewport: self.viewport)
            case .navigate: result = .navigationSubmitted(viewVersion: self.version)
            case .click, .insertText, .navigateByInput:
                result = .nativeDelivered(sequence: 7, buttons: 0, viewVersion: self.version)
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }, testOCR: { _, _ in SemanticOCRResult(status: "unavailable", items: [], truncated: false) })
        func send(_ operation: ControlOperation, id: UUID = UUID()) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: id, operation: operation))
            if let ack { broker.acknowledgement(ack, received: true) }
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        func connect() async throws -> UUID {
            let result = try await send(.connect(profileID: profile))
            return try XCTUnwrap(result.connection)
        }
    }

    func testObservationAcceptsResizeAndRetainedFrameUsesItsOwnPixelScale() async throws {
        let f = Fixture(), c = try await f.connect()
        let initial = try await f.send(.observe(connection: c))
        let frame = try XCTUnwrap(initial.frame)
        f.width = 160; f.version = 4
        let resized = try await f.send(.observe(connection: c))
        XCTAssertEqual(resized.status, "ok")
        XCTAssertEqual(resized.viewport?.pixelWidth, 320)
        let click = try await f.send(.click(connection: c, frame: frame, x: 60, y: 40, count: 1))
        XCTAssertEqual(click.sent, true)
        XCTAssertEqual(click.effectVerified, false)
        guard case let .click(point, _, _) = f.calls.last?.action else { return XCTFail("Expected one native click") }
        XCTAssertEqual(point.x, 30); XCTAssertEqual(point.y, 20)
        XCTAssertNil(f.calls.last?.expectedViewVersion)
    }

    func testWaitNavigationCompatibilityReportsInputWithoutClaimingNavigation() async throws {
        let f = Fixture(), c = try await f.connect()
        let observation = try await f.send(.observe(connection: c))
        let frame = try XCTUnwrap(observation.frame)
        for operation in [ControlOperation.pressEnterAndWait(connection: c, frame: frame),
                          .clickAndWait(connection: c, frame: frame, x: 10, y: 10)] {
            let id = UUID()
            let sent = try await f.send(operation, id: id)
            XCTAssertEqual(sent.status, "ok")
            XCTAssertEqual(sent.sent, true)
            XCTAssertEqual(sent.effectVerified, false)
            XCTAssertNil(sent.navigationSubmitted)
            let replay = try await f.send(operation, id: id)
            XCTAssertEqual(replay.sequence, 7)
            XCTAssertEqual(f.calls.filter { $0.requestID == id }.count, 1)
        }
    }

    func testSubmissionDoesNotRequireDocumentVersionIncrease() async throws {
        let f = Fixture(), c = try await f.connect()
        let sent = try await f.send(.navigate(connection: c, url: URL(string: "https://example.com/")!))
        XCTAssertEqual(sent.status, "ok")
        XCTAssertEqual(sent.navigationSubmitted, true)
        XCTAssertEqual(sent.effectVerified, false)
    }

    func testFrameRetentionIsBoundedAndUnknownFramesDoNotSendInput() async throws {
        let f = Fixture(), c = try await f.connect()
        var frames: [UUID] = []
        for _ in 0..<33 {
            let result = try await f.send(.observe(connection: c))
            frames.append(try XCTUnwrap(result.frame))
        }
        let count = f.calls.count
        for frame in [frames[0], UUID()] {
            let invalid = try await f.send(.type(connection: c, frame: frame, text: "x"))
            XCTAssertEqual(invalid.error, "INVALID_FRAME")
        }
        XCTAssertEqual(f.calls.count, count)
        let retained = try await f.send(.type(connection: c, frame: frames[1], text: "x"))
        XCTAssertEqual(retained.sent, true)
    }

    func testLongConnectionDoesNotExhaustReplayCapacityOrReplayOldInput() async throws {
        let f = Fixture(), c = try await f.connect()
        let firstID = UUID()
        let operation = ControlOperation.navigate(connection: c, url: URL(string: "https://example.com/")!)
        let first = try await f.send(operation, id: firstID)
        XCTAssertEqual(first.status, "ok")
        for _ in 0..<260 {
            let reply = try await f.send(operation)
            XCTAssertEqual(reply.status, "ok")
        }
        let replay = try await f.send(operation, id: firstID)
        XCTAssertEqual(replay.navigationSubmitted, true)
        XCTAssertEqual(f.calls.filter { $0.requestID == firstID }.count, 1)
        let reused = try await f.send(.observe(connection: c), id: firstID)
        XCTAssertEqual(reused.error, "REQUEST_ID_REUSED")
    }

    func testReleaseReachesManagerWhileObservationIsPending() async throws {
        let profile = UUID()
        let target = AutomationTargetIdentity(profileID: profile, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 10, viewportHeightPoints: 10,
            pixelWidth: 10, pixelHeight: 10, scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        var observation: CheckedContinuation<Void, Never>?
        var releaseCalls = 0
        let broker = ControlBroker(testSender: { request in
            let result: AutomationResult
            switch request.action {
            case .openSession:
                result = .sessionOpened(sessionID: String(repeating: "A", count: 43), target: target, viewport: viewport)
            case .screenshot:
                await withCheckedContinuation { observation = $0 }
                result = .snapshotWritten(path: "/fixture", viewport: viewport)
            case .releaseControl:
                releaseCalls += 1
                result = .controlReleased(ControlReleaseReceipt(target: target, transferID: UUID(), inputReleased: true,
                    artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true))
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        }, testOCR: { _, _ in SemanticOCRResult(status: "unavailable", items: [], truncated: false) })
        func send(_ operation: ControlOperation) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: operation))
            if let ack { broker.acknowledgement(ack, received: true) }
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        let connected = try await send(.connect(profileID: profile))
        let connection = try XCTUnwrap(connected.connection)
        let pending = Task { try await send(.observe(connection: connection)) }
        while observation == nil { await Task.yield() }
        let released = try await send(.release(connection: connection))
        observation?.resume()
        _ = try await pending.value
        XCTAssertEqual(released.status, "ok")
        XCTAssertEqual(released.controlReleased?.inputReleased, true)
        XCTAssertEqual(releaseCalls, 1)
    }
}
#endif
