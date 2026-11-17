import Foundation
import XCTest
import SafarierControlSupport

#if SAFARIER_CONTROL_TESTING
final class ControlBusinessPermissionTimeoutTests: XCTestCase {
    func testStalledPermissionQueryReturnsTimeoutWithoutWaitingForNativeCall() {
        let start = ContinuousClock.now
        XCTAssertEqual(cs_control_test_permission_timeout(), -1712)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(150))
    }
}
#endif
