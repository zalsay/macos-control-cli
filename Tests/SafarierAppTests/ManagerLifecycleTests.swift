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
    func testCancelledHostTerminationRestoresWindowAndQuitPolicy() {
        var state = ManagerLaunchState()
        XCTAssertEqual(state.handle(.finishedLaunching), [])
        XCTAssertEqual(state.handle(.interactive), [.showManager])
        XCTAssertEqual(state.handle(.quitRequested(pendingCommands: 0)), [.cancelPending, .terminate])

        XCTAssertEqual(state.handle(.terminationCancelled), [])
        XCTAssertEqual(state.handle(.interactive), [.showManager])
        XCTAssertEqual(state.handle(.windowClosed(pendingCommands: 0)), [.terminate])
    }
    func testCancelledHostTerminationCanReenterPendingCommandDrain() {
        var state = ManagerLaunchState()
        _ = state.handle(.finishedLaunching)
        _ = state.handle(.interactive)
        _ = state.handle(.quitRequested(pendingCommands: 0))
        _ = state.handle(.terminationCancelled)
        _ = state.handle(.interactive)

        XCTAssertEqual(state.handle(.quitRequested(pendingCommands: 1)), [.cancelPending, .deferTermination])
        XCTAssertEqual(state.handle(.pendingCommandsChanged(0)), [.replyToTermination])
    }
    func testRealApplicationEventOrderingRequiresIsolatedGUIAcceptance() throws {
        throw XCTSkip("Real application event ordering and window activation require isolated GUI acceptance")
    }
}
