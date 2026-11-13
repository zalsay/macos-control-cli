#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
import WebKit
import XCTest
import SafarierCore
@testable import SafarierWebKit
@testable import Safarier

@MainActor final class RegisteredInitialPresentationTests: XCTestCase {
    private func session(quiet: Bool = false) -> BrowserSession {
        _ = NSApplication.shared
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(), report: PrivacyCapabilityReport(), executionPolicy: .interactive)
        return BrowserSession(profile: Profile(name: "offline-initial-presentation", mode: .ephemeral), output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics(), promoteOnActivation: quiet)
    }
    func testInitialWindowIsNotPresentedBeforeFinishedLaunch() {
        let session = session()
        session.startRegisteredInteractive(url: nil)
        guard let controller = session.openControllers.first else { return XCTFail("missing original window") }
        defer { controller.window.orderOut(nil) }
        XCTAssertFalse(controller.window.isVisible, "initial registered presentation must wait for confirmed finished launch")
        XCTAssertFalse(controller.window.isKeyWindow)
        XCTAssertFalse(controller.window.isMainWindow)
    }
    func testCLIStartupRequestsForegroundAndKeyWindow() throws {
        let session = session(quiet: true)
        session.startRegisteredInteractive(url: nil)
        let window = session.openControllers[0].window
        defer { window.orderOut(nil) }
        try requireIdleDesktop()
        session.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let active = expectation(for: NSPredicate { _, _ in NSApp.isActive && window.isKeyWindow }, evaluatedWith: nil)
        wait(for: [active], timeout: 3)
        XCTAssertTrue(session.registeredInitialPresentationConfirmed)
    }
    private func requireIdleDesktop() throws {
        guard NSEvent.pressedMouseButtons == 0, !NSApp.isActive, !NSApp.isHidden else {
            throw XCTSkip("Desktop input/presentation conflict; positive path not verified")
        }
    }

    private func verifyAfterPresentation(_ window: NSWindow, quiet: Bool = true) throws {
        guard NSEvent.pressedMouseButtons == 0 else {
            throw XCTSkip("Concurrent mouse input; positive path not verified")
        }
        XCTAssertFalse(NSApp.isHidden)
        if quiet {
            XCTAssertFalse(NSApp.isActive)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertFalse(window.isMainWindow)
        }
    }

    func testFinishedLaunchPresentsOriginalWindowOnlyOnce() throws {
        let session = session()
        session.startRegisteredInteractive(url: nil)
        let original = session.openControllers[0].window
        defer { original.orderOut(nil) }
        XCTAssertFalse(session.registeredInitialPresentationConfirmed)
        try requireIdleDesktop()
        session.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try verifyAfterPresentation(original)
        XCTAssertTrue(session.openControllers[0].window === original)
        XCTAssertTrue(original.isVisible)
        XCTAssertTrue(session.registeredInitialPresentationConfirmed)
        XCTAssertFalse(original.isKeyWindow); XCTAssertFalse(original.isMainWindow)
        original.orderOut(nil)
        try requireIdleDesktop()
        session.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try verifyAfterPresentation(original)
        XCTAssertFalse(original.isVisible, "duplicate launch notification must not reorder")
    }

    func testManualStartupKeepsPolicyAndAlsoWaitsForFinishedLaunch() throws {
        let session = session(quiet: false)
        let policy = NSApp.activationPolicy()
        session.startRegisteredInteractive(url: nil)
        let original = session.openControllers[0].window
        defer { original.orderOut(nil) }
        XCTAssertFalse(original.isVisible)
        try requireIdleDesktop()
        session.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try verifyAfterPresentation(original, quiet: false)
        XCTAssertTrue(original.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), policy)
    }

    func testBlockedInitialPresentationRemainsPendingUntilSafe() throws {
        let session = session()
        session.startRegisteredInteractive(url: nil)
        let window = session.openControllers[0].window
        let frame = window.frame
        defer { window.orderOut(nil) }
        window.setFrame(NSRect(x: -100000, y: -100000, width: 400, height: 300), display: false)
        try requireIdleDesktop()
        session.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try verifyAfterPresentation(window)
        XCTAssertFalse(session.registeredInitialPresentationConfirmed)
        XCTAssertFalse(window.isVisible)
        window.setFrame(frame, display: false)
        try requireIdleDesktop()
        session.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try verifyAfterPresentation(window)
        XCTAssertTrue(session.registeredInitialPresentationConfirmed)
        XCTAssertTrue(window.isVisible)
    }



}
#endif
