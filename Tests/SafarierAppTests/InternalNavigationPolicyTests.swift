#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
import XCTest
@testable import Safarier

final class InternalNavigationPolicyTests: XCTestCase {
    func testWebAndSubframeSchemes() throws {
        for text in ["https://example.com/", "http://example.com/"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertTrue(InternalNavigationPolicy.isWebURL(url))
            XCTAssertTrue(InternalNavigationPolicy.allowsFrameURL(url))
        }
        let blank = try XCTUnwrap(URL(string: "about:blank"))
        XCTAssertFalse(InternalNavigationPolicy.isWebURL(blank))
        XCTAssertTrue(InternalNavigationPolicy.allowsFrameURL(blank))
        for text in ["file:///tmp/test", "data:text/plain,test", "javascript:alert(1)", "about:srcdoc", "https://user:pass@example.com/"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertFalse(InternalNavigationPolicy.isWebURL(url))
            XCTAssertFalse(InternalNavigationPolicy.allowsFrameURL(url))
        }
    }
}
#endif
