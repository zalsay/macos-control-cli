import AppKit
import XCTest
@testable import Safarier

@MainActor
final class BrowserDefaultWindowSizeTests: XCTestCase {
    func testDefaultFrameSelectionAndInvisibleWindowGeometry() {
        let cases: [(NSSize?, NSSize)] = [
            (NSSize(width: 3440, height: 1336), NSSize(width: 1600, height: 1200)),
            (NSSize(width: 1600, height: 1200), NSSize(width: 1600, height: 1200)),
            (NSSize(width: 1599, height: 1200), NSSize(width: 1280, height: 800)),
            (NSSize(width: 1600, height: 1199), NSSize(width: 1280, height: 800)),
            (nil, NSSize(width: 1280, height: 800)),
        ]
        _ = NSApplication.shared
        for (screen, expected) in cases {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "default-window-size-test")
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            let frameSize = BrowserSession.defaultWindowFrameSize(screen: screen)
            BrowserSession.applyDefaultWindowFrameSize(frameSize, to: window)
            XCTAssertEqual(window.frame.size, expected)
            XCTAssertEqual(window.contentView?.frame.size, window.contentRect(forFrameRect: window.frame).size)
            XCTAssertGreaterThan(window.frame.height, window.contentLayoutRect.height)
            XCTAssertFalse(window.isVisible)
            window.close()
        }
    }
}
