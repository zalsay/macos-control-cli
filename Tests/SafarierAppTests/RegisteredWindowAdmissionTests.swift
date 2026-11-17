#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_REGISTERED_TAB_TESTS
import AppKit
import WebKit
import XCTest
import SafarierCore
@testable import SafarierWebKit
@testable import Safarier

@MainActor
final class RegisteredWindowAdmissionTests: XCTestCase {
    func testFocusedFieldEditorDoesNotBlockRegisteredAdmission() throws {
        _ = NSApplication.shared
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(), report: PrivacyCapabilityReport(), executionPolicy: .interactive)
        let session = BrowserSession(profile: Profile(name: "admission-field-editor", mode: .ephemeral), output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics())
        let controller = session.makeRegisteredTestController()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        editor.isFieldEditor = true
        controller.window.contentView?.addSubview(editor)
        XCTAssertTrue(controller.window.makeFirstResponder(editor))
        XCTAssertTrue(controller.window.firstResponder === editor)
        XCTAssertNoThrow(try controller.validateRegisteredAdmission())
    }
}
#endif
