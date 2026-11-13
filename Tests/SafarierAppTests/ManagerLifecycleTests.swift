import XCTest
import SafarierCore
@testable import Safarier
final class ManagerLifecycleTests: XCTestCase {
    func testAutomationDoesNotShowOrHideHumanWindow() {
        var state = ManagerLaunchState()
        XCTAssertEqual(state.handle(.finishedLaunching), [])
        XCTAssertEqual(state.handle(.automation), [])
        XCTAssertEqual(state.handle(.interactive), [.showManager])
        XCTAssertEqual(state.handle(.automation), [])
        XCTAssertEqual(state.handle(.windowClosed(pendingCommands: 1)), [])
    }
    func testRealApplicationEventOrderingRequiresIsolatedGUIAcceptance() throws {
        throw XCTSkip("Real application event ordering and window activation require isolated GUI acceptance")
    }
}
