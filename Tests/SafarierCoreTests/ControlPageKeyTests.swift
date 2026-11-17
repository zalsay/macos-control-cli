import XCTest
@testable import SafarierCore

final class ControlPageKeyTests: XCTestCase {
    func testPageKeysRoundTripThroughCLIAndBothProtocols() throws {
        for name in ["PageUp", "PageDown"] {
            let connection = UUID(), frame = UUID()
            let parsed = try ControlCLIParser.parse(["press", "--connection", connection.uuidString, "--frame", frame.uuidString, "--key", name])
            guard case let .press(c, f, key, shift) = parsed.operation else { return XCTFail("expected native press") }
            XCTAssertEqual(c, connection); XCTAssertEqual(f, frame)
            XCTAssertEqual(key.rawValue, name); XCTAssertFalse(shift)
            XCTAssertTrue(NativeInputPreflight.keyAllowed(name: key, shift: false))
            let control = ControlRequest(requestID: UUID(), operation: parsed.operation)
            XCTAssertEqual(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(control)), control)
            let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "A", count: 43), action: .key(name: key, shift: false))
            XCTAssertEqual(try AutomationCodec.decode(AutomationCodec.encodeRequest(request)), request)
        }
    }

    func testPageKeysDoNotAddNavigationWaitOrShiftShortcuts() throws {
        for name in ["PageUp", "PageDown"] {
            let key = try XCTUnwrap(AutomationKey(rawValue: name))
            XCTAssertFalse(NativeInputPreflight.keyAllowed(name: key, shift: true))
            let args = ["press", "--connection", UUID().uuidString, "--frame", UUID().uuidString, "--key", name]
            XCTAssertThrowsError(try ControlCLIParser.parse(args + ["--shift"]))
            XCTAssertThrowsError(try ControlCLIParser.parse(args + ["--wait-navigation"]))
        }
    }
}
