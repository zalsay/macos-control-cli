import Foundation
import XCTest
@testable import SafarierCore

final class AutomationProtocolTests: XCTestCase {
    func testInsertTextAIRoundTripsWithCanonicalSession() throws {
        let token = try AutomationSessionToken.generate()
        XCTAssertTrue(AutomationSessionToken.isCanonical(token))
        let id = try XCTUnwrap(UUID(uuidString: "80266ABD-638A-455C-8F88-D238C1852DA3"))
        for text in ["AI", "ai"] {
            let request = AutomationRequest(version: 1, requestID: id, sessionID: token, action: .insertText(text))
            do {
                let data = try AutomationCodec.encodeRequest(request)
                XCTAssertEqual(try AutomationCodec.decode(data), request)
            } catch {
                XCTFail("text=\(text) error type=\(type(of: error)) error=\(error)")
            }
        }
    }
    func testSharedProtocolCases() throws {
        XCTAssertGreaterThan(try AutomationProtocolCases.run(), 0)
    }
    func testSuccessRequiresRequestIDButFailureMayEncodeNull() throws {
        let success = AutomationReply(requestID: nil, outcome: .success(.nativeDelivered(sequence: 1, buttons: 0, viewVersion: 1)))
        XCTAssertThrowsError(try AutomationCodec.encode(success))
        let failure = AutomationReply(requestID: nil, outcome: .failure(AutomationError(code: .invalidRequest)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: AutomationCodec.encode(failure)) as? [String: Any])
        XCTAssertTrue(json["requestID"] is NSNull)
        XCTAssertEqual(json["status"] as? String, "error")
    }

}
