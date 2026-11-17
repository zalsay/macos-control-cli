import Foundation
import XCTest
@testable import SafarierCore

final class ControlBackCommandTests: XCTestCase {
    func testBackUsesTheExistingBackspaceWireOperation() throws {
        let connection = UUID(), frame = UUID()
        let parsed = try ControlCLIParser.parse(["control", "back", "--connection", connection.uuidString, "--frame", frame.uuidString])
        let press = try ControlCLIParser.parse(["press", "--connection", connection.uuidString, "--frame", frame.uuidString, "--key", "Backspace"])
        XCTAssertEqual(parsed.operation, .press(connection: connection, frame: frame, key: .backspace, shift: false))
        XCTAssertEqual(parsed.operation, press.operation)
        let request = ControlRequest(requestID: UUID(), operation: parsed.operation)
        XCTAssertEqual(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(request)), request)
    }

    func testBackRequiresFrameAndDoesNotAcceptDifferentKeysOrModifiers() {
        let args = ["back", "--connection", UUID().uuidString, "--frame", UUID().uuidString]
        for invalid in [Array(args.prefix(3)), args + ["--shift"], args + ["--key", "Delete"], args + ["--wait-navigation"]] {
            XCTAssertThrowsError(try ControlCLIParser.parse(invalid))
        }
    }
}
