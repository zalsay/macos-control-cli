import XCTest
@testable import SafarierCore

final class NavigationDiagnosticTests: XCTestCase {
    func testActionClassificationNeverIncludesPayloads() {
        let secret = "private-text-https://example.test/token"
        let point = ViewportPoint(x: 123, y: 456)
        let cases: [(AutomationAction, String?)] = [
            (.openSession(profileID: UUID()), "connect"), (.screenshot, "observe"),
            (.click(point: point, viewVersion: 2, count: 1), "click"),
            (.insertText(secret), "type"), (.releaseControl, "release"),
            (.commitControlRelease(transferID: UUID()), "release"),
            (.closeSession, "close"), (.cancel, "cancel"),
            (.navigate(url: URL(string: "https://example.test/token")!), "navigate"),
            (.getState, "state"), (.capabilities, nil)
        ]
        for (action, expected) in cases {
            let category = NavigationDiagnostic.category(action)
            XCTAssertEqual(category, expected)
            XCTAssertFalse((category ?? "").contains(secret))
        }
    }

    func testControlClassificationAndUntrustedErrorFiltering() {
        let id = UUID()
        XCTAssertEqual(NavigationDiagnostic.category(.type(connection: id, frame: id, text: "secret")), "type")
        XCTAssertEqual(NavigationDiagnostic.category(.clickTarget(connection: id, target: "secret")), "click")
        XCTAssertEqual(NavigationDiagnostic.safeResult("INVALID_FRAME"), "INVALID_FRAME")
        XCTAssertEqual(NavigationDiagnostic.safeResult("https://private.test/token"), "other")
        for label in ["sender_unavailable", "sender_indeterminate", "cancellation_error", "decoding_error", "encoding_error", "ns_cocoa", "ns_posix", "ns_osstatus", "ns_url"] {
            XCTAssertEqual(NavigationDiagnostic.safeResult(label), label)
        }
    }

    func testNativeInputCategoriesMatchControlOperations() {
        let id = UUID(), point = ViewportPoint(x: 123, y: 456)
        let actions: [(AutomationAction, String)] = [
            (.move(point: point, viewVersion: 1), "move"),
            (.mouseDown(point: point, viewVersion: 1), "mouseDown"),
            (.mouseUp(point: point, viewVersion: 1), "mouseUp"),
            (.scroll(point: point, viewVersion: 1, deltaX: 2, deltaY: 3), "scroll"),
            (.key(name: .enter, shift: true), "press"),
            (.navigateByInput(input: .click(point: point), viewVersion: 1), "click"),
            (.navigateByInput(input: .enter, viewVersion: 1), "navigate")
        ]
        for (action, expected) in actions { XCTAssertEqual(NavigationDiagnostic.category(action), expected) }
        let operations: [(ControlOperation, String)] = [
            (.move(connection: id, frame: id, x: 123, y: 456), "move"),
            (.mouseDown(connection: id, frame: id, x: 123, y: 456), "mouseDown"),
            (.mouseUp(connection: id, frame: id, x: 123, y: 456), "mouseUp"),
            (.press(connection: id, frame: id, key: .enter, shift: true), "press"),
            (.clickAndWait(connection: id, frame: id, x: 123, y: 456), "click"),
            (.pressEnterAndWait(connection: id, frame: id), "navigate")
        ]
        for (operation, expected) in operations { XCTAssertEqual(NavigationDiagnostic.category(operation), expected) }
    }

    func testOutcomeIsOnlyKnownErrorCodeOrSuccess() {
        XCTAssertEqual(NavigationDiagnostic.result(.failure(AutomationError(code: .timeout))), "TIMEOUT")
        XCTAssertEqual(NavigationDiagnostic.result(.success(.navigationFinished(viewVersion: 1))), "ok")
    }
}
