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
        XCTAssertEqual(state.handle(.windowClosed(pendingCommands: 0)), [])
    }
    func testClosingPanelWithOrWithoutPendingWorkNeverTerminatesAndCanReopen() {
        var state = ManagerLaunchState()
        XCTAssertEqual(state.handle(.finishedLaunching), [])
        XCTAssertEqual(state.handle(.interactive), [.showManager])
        XCTAssertEqual(state.handle(.windowClosed(pendingCommands: 0)), [])
        XCTAssertEqual(state.handle(.interactive), [.showManager])
        XCTAssertEqual(state.handle(.windowClosed(pendingCommands: 3)), [])
        XCTAssertEqual(state.handle(.pendingCommandsChanged(0)), [])
        XCTAssertEqual(state.handle(.interactive), [.showManager])
    }
    func testExplicitExitRequiresIdleWorkAndVerifiedShutdown() {
        var exit = ManagerExplicitExitState()
        XCTAssertEqual(exit.request(pendingWork: 2), .refusePendingWork)
        XCTAssertEqual(exit.request(pendingWork: 0), .beginShutdown)
        XCTAssertEqual(exit.request(pendingWork: 0), .alreadyInFlight)
        exit.shutdownFailed()
        XCTAssertFalse(exit.isShutdownInFlight)
        XCTAssertFalse(exit.shutdownSucceeded())
        XCTAssertEqual(exit.request(pendingWork: 0), .beginShutdown)
        XCTAssertTrue(exit.shutdownSucceeded())
        XCTAssertFalse(exit.shutdownSucceeded())
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
