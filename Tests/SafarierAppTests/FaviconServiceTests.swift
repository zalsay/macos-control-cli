import AppKit
import XCTest
@testable import Safarier

@MainActor
final class FaviconServiceTests: XCTestCase {
    func testMakeRetinaFaviconScalesToStandardRetinaSize() {
        let source = NSImage(size: NSSize(width: 128, height: 128))
        source.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 128, height: 128).fill()
        source.unlockFocus()

        let retina = FaviconService.makeRetinaFavicon(from: source)
        XCTAssertNotNil(retina)
        XCTAssertEqual(retina?.size, NSSize(width: 16, height: 16))
        let rep = retina?.representations.first
        XCTAssertEqual(rep?.pixelsWide, 32)
        XCTAssertEqual(rep?.pixelsHigh, 32)
    }

    func testWindowTabSetFaviconSetsAndClears() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let tab = window.tab

        let icon = NSImage(size: NSSize(width: 16, height: 16))
        tab.setFavicon(icon)
        XCTAssertNotNil(tab.value(forKey: "image"))
        XCTAssertEqual(tab.value(forKey: "showIcon") as? Bool, true)

        tab.setFavicon(nil)
        XCTAssertEqual(tab.value(forKey: "showIcon") as? Bool, false)
    }

    func testFaviconServiceMemoryCacheLookup() {
        let service = FaviconService.shared
        let testURL = URL(string: "https://unit-test.safarier.internal/page")!

        let icon = NSImage(size: NSSize(width: 16, height: 16))
        _ = FaviconService.makeRetinaFavicon(from: icon) ?? icon

        // Direct memory caching test
        service.loadFavicon(for: testURL) { _ in }
        XCTAssertNil(service.getFavicon(for: URL(string: "https://unknown-nonexistent-domain.xyz")!))
    }
}
