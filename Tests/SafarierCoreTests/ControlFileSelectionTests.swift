import Foundation
import XCTest
@testable import SafarierCore

final class ControlFileSelectionTests: XCTestCase {
    private let connection = UUID()
    private let paths = ["/tmp/封面 01.png", "/tmp/page \"02\".png"]

    func testCLIAndBrokerPreserveOrderedPathsWithoutAFrame() throws {
        let parsed = try ControlCLIParser.parse(["select-file", "--connection", connection.uuidString,
                                                 "--path", paths[0], "--path", paths[1]])
        guard case let .selectFile(id, selected) = parsed.operation else { return XCTFail("Wrong operation") }
        XCTAssertEqual(id, connection)
        XCTAssertEqual(selected, paths)
        let request = ControlRequest(requestID: UUID(), operation: parsed.operation)
        XCTAssertEqual(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(request)), request)
    }

    func testCLIRejectsMissingRelativeAndExcessPathsAndAFrame() {
        let args = ["select-file", "--connection", connection.uuidString]
        XCTAssertThrowsError(try ControlCLIParser.parse(args))
        XCTAssertThrowsError(try ControlCLIParser.parse(args + ["--path", "relative.png"]))
        XCTAssertThrowsError(try ControlCLIParser.parse(args + ["--path", "/tmp/a.png", "--frame", UUID().uuidString]))
        XCTAssertThrowsError(try ControlCLIParser.parse(args + Array(repeating: ["--path", "/tmp/a.png"], count: 21).flatMap { $0 }))
    }

    func testRunnerWireCarriesAnExplicitSelectionReceipt() throws {
        let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: try AutomationSessionToken.generate(),
                                        action: .selectFiles(paths))
        XCTAssertEqual(try AutomationCodec.decode(AutomationCodec.encodeRequest(request)), request)
        let reply = AutomationReply(requestID: request.requestID, outcome: .success(.filesSelected(count: paths.count)))
        XCTAssertEqual(try AutomationCodec.decodeReply(AutomationCodec.encode(reply)), reply)
    }
}
