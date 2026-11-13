import AppKit
import WebKit
import SafarierObjCSupport
import SafarierCore

/// Diagnostic adapter: stub sends nothing; fixed forwards to the production event path.
@MainActor
final class NativeEvents {
    let webView: BrowserWebView
    let window: NSWindow
    let mode: String
    private let driver: NativePageInput?
    private var stubClosed = false
    private var unsupportedInput = false
    var activityReady: Bool { mode == "stub" || (driver?.activityReady ?? false) }
    var activityClosed: Bool { mode == "stub" ? stubClosed : (driver?.activityClosed ?? false) }
    var activityStatus: SFRCallStatus { driver?.activityStatus ?? (mode == "stub" ? .OK : .missingSelector) }
    var buttonMask: UInt { driver?.buttonMask ?? 0 }
    var trace: [[String: Any]] { driver?.trace ?? [] }
    init(webView: BrowserWebView, window: NSWindow, mode: String) {
        self.webView = webView; self.window = window; self.mode = mode
        self.driver = mode == "fixed" ? NativePageInput(diagnosticWebView: webView, window: window) : nil
    }
    func move(_ x: Double, _ y: Double) { driver?.move(x, y) }
    func press(_ x: Double, _ y: Double, count: Int = 1) { driver?.press(x, y, count: count) }
    func release(_ x: Double, _ y: Double, count: Int = 1) { driver?.release(x, y, count: count) }
    func click(_ x: Double, _ y: Double, count: Int = 1) { driver?.click(x, y, count: count) }
    func drag(_ start: NSPoint, _ end: NSPoint) { driver?.drag(start, end) }
    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard characters == "\u{8}", code == 51, flags.isEmpty else { unsupportedInput = true; driver?.rejectDiagnosticInput(); return }
        driver?.key(.backspace)
    }
    func type(_ text: String) { driver?.type(text) }
    func scroll(_ x: Double, _ y: Double, delta: Int32) { driver?.scroll(x, y, delta: delta) }
    func drain() async throws {
        guard !unsupportedInput, mode == "stub" || mode == "fixed" else { throw AutomationError(code: .invalidRequest) }
        try await driver?.drain()
    }
    func closeActivity() {
        guard let driver else { stubClosed = true; return }
        driver.closeActivity()
        if driver.requiresOwnedTargetDestruction { window.close() }
    }
}
