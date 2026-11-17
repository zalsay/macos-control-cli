import Foundation
import XCTest
@testable import SafarierCore

final class ControlNavigationURLTests: XCTestCase {
    func testAbsoluteBrowserURLsAreForwardedWithoutSchemeOrCredentialPolicy() throws {
        let connection = UUID()
        for raw in ["about:blank", "file:///tmp/example.html", "custom-browser:example", "https://user:password@example.com/path"] {
            let parsed = try ControlCLIParser.parse(["navigate", "--connection", connection.uuidString, "--url", raw])
            guard case let .navigate(_, url) = parsed.operation else { return XCTFail("Expected navigate") }
            XCTAssertEqual(url.absoluteString, raw)
            let request = AutomationRequest(version: 1, requestID: UUID(), sessionID: String(repeating: "A", count: 43), action: .navigate(url: url))
            XCTAssertEqual(try AutomationCodec.decode(AutomationCodec.encodeRequest(request)).action, request.action)
        }
    }

    func testRelativeAndControlCharacterURLsRemainInvalidRequests() {
        for raw in ["/relative", "", "https://example.com/\npath", "http:///path", "https://%20"] {
            XCTAssertThrowsError(try ControlCLIParser.parse(["navigate", "--connection", UUID().uuidString, "--url", raw]))
        }
    }
}
