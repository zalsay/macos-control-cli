import AppKit
import XCTest
@testable import Safarier

final class ManagerWindowSizeTests: XCTestCase {
    func testDefaultsAndScreenClamping() {
        XCTAssertEqual(ManagerWindowSize.resolve(nil, screen: NSSize(width: 1600, height: 1200)), NSSize(width: 1600, height: 1200))
        XCTAssertEqual(ManagerWindowSize.resolve(nil, screen: NSSize(width: 1599, height: 1200)), NSSize(width: 1280, height: 800))
        XCTAssertEqual(ManagerWindowSize.resolve(nil, screen: NSSize(width: 1100, height: 700)), NSSize(width: 1100, height: 700))
        XCTAssertEqual(ManagerWindowSize.resolve(nil, screen: NSSize(width: 700, height: 500)), NSSize(width: 920, height: 580))
        XCTAssertEqual(ManagerWindowSize.resolve(nil, screen: nil), NSSize(width: 1280, height: 800))
        XCTAssertEqual(ManagerWindowSize.resolve(NSSize(width: 1800, height: 1300), screen: NSSize(width: 1100, height: 700)), NSSize(width: 1100, height: 700))
        XCTAssertEqual(ManagerWindowSize.resolve(NSSize(width: 1, height: 1), screen: NSSize(width: 700, height: 500)), NSSize(width: 920, height: 580))
        XCTAssertEqual(ManagerWindowSize.resolve(NSSize(width: CGFloat.nan, height: 800), screen: NSSize(width: 1600, height: 1200)), NSSize(width: 1600, height: 1200))
    }

    func testNormalSizeAcrossCloseQuitAndFullScreenTransitions() throws {
        let name = "ManagerWindowSizeLifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ManagerWindowSize(defaults: defaults)
        var normal = ManagerNormalWindowSize(size: NSSize(width: 1280, height: 800))
        normal.observe(NSSize(width: 1350, height: 850), fullScreen: false, miniaturized: false)
        // Closing reads the final frame, even if no final resize notification arrived.
        normal.observe(NSSize(width: 1400, height: 900), fullScreen: false, miniaturized: false)
        store.save(normal.size)
        XCTAssertEqual(store.load(), NSSize(width: 1400, height: 900))
        let reopened = ManagerWindowSize.resolve(store.load(), screen: NSSize(width: 1200, height: 800))
        XCTAssertEqual(reopened, NSSize(width: 1200, height: 800))
        normal = ManagerNormalWindowSize(size: reopened)
        normal.changingFullScreen = true
        normal.observe(NSSize(width: 1600, height: 1200), fullScreen: false, miniaturized: false)
        normal.changingFullScreen = false
        normal.observe(NSSize(width: 1600, height: 1200), fullScreen: true, miniaturized: false)
        normal.observe(NSSize(width: 100, height: 100), fullScreen: false, miniaturized: true)
        store.save(normal.size) // quit while full screen or minimized
        XCTAssertEqual(store.load(), reopened)
        normal.changingFullScreen = true
        normal.observe(NSSize(width: 1500, height: 1100), fullScreen: false, miniaturized: false)
        normal.changingFullScreen = false
        normal.observe(NSSize(width: 1150, height: 750), fullScreen: false, miniaturized: false)
        store.save(normal.size)
        XCTAssertEqual(store.load(), NSSize(width: 1150, height: 750))
    }

    func testIsolatedPersistenceAndInvalidValues() throws {
        let name = "ManagerWindowSizeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ManagerWindowSize(defaults: defaults)
        XCTAssertNil(store.load())
        store.save(NSSize(width: 1100, height: 700))
        XCTAssertEqual(ManagerWindowSize(defaults: defaults).load(), NSSize(width: 1100, height: 700))
        defaults.set(["width": Double.infinity, "height": 700], forKey: ManagerWindowSize.key)
        XCTAssertNil(store.load())
        defaults.set(["width": -1, "height": 700], forKey: ManagerWindowSize.key)
        XCTAssertNil(store.load())
        defaults.set(["width": "1200", "height": 700], forKey: ManagerWindowSize.key)
        XCTAssertNil(store.load())
    }
}
