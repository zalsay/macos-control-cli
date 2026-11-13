import XCTest
import SafarierCore
@testable import Safarier

final class ManagerMigrationAlertTests: XCTestCase {
    func testOnlyInteractiveMigrationFailureRequestsAlert() {
        XCTAssertNotNil(ManagerGUI.migrationAlertMessage(for: WorkspaceMigrationError.legacyPresent, quietStart: false))
        XCTAssertNil(ManagerGUI.migrationAlertMessage(for: WorkspaceMigrationError.legacyPresent, quietStart: true))
        XCTAssertNil(ManagerGUI.migrationAlertMessage(for: NSError(domain: "fixture", code: 1), quietStart: false))
    }
    func testMessageIncludesConflictAndMigrationInstructions() {
        let message = ManagerGUI.migrationAlertMessage(for: WorkspaceMigrationError.legacyPresent, quietStart: false) ?? ""
        XCTAssertTrue(message.contains("Safarier Test"))
        XCTAssertTrue(message.contains("退出"))
        XCTAssertTrue(message.contains("不再打开旧版"))
        XCTAssertTrue(message.contains("workspace migrate"))
        XCTAssertTrue(message.contains("合并"))
    }
    func testAlertRequiresInteractiveLaunchAndSuppressesAutomation() {
        var finder = ManagerMigrationFailureState()
        XCTAssertFalse(finder.handle(.openApplication))
        XCTAssertTrue(finder.handle(.finishedLaunching))
        var automation = ManagerMigrationFailureState()
        XCTAssertFalse(automation.handle(.openApplication))
        XCTAssertFalse(automation.handle(.automation))
        XCTAssertFalse(automation.handle(.finishedLaunching))
        var later = ManagerMigrationFailureState()
        XCTAssertFalse(later.handle(.finishedLaunching))
        XCTAssertTrue(later.handle(.interactive))
    }
}
