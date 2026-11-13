#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
import XCTest
@testable import Safarier

@MainActor
final class RegisteredWindowAdmissionTests: XCTestCase {
    func testOrdinaryTextInputClientWithoutCompositionIsNotRejected() {
        // NSTextView implements NSTextInputClient; conformance alone is not an edit.
        let responder = NSTextView(frame: .zero)
        responder.isFieldEditor = false
        XCTAssertFalse(responder.hasMarkedText())
        XCTAssertFalse(BrowserWindowController.registeredResponderHasEditingConflict(responder))
    }

    func testActiveFieldEditorIsRejected() {
        let editor = NSTextView(frame: .zero)
        editor.isFieldEditor = true
        XCTAssertTrue(BrowserWindowController.registeredResponderHasEditingConflict(editor))
    }
}
#endif
