#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
import XCTest
@testable import Safarier

@MainActor final class RegisteredPresentationLeaseTests: XCTestCase {
    private func window() -> NonActivatingBrowserWindow {
        _ = NSApplication.shared
        let window = NonActivatingBrowserWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    func testLeasePreservesManualWindowAndApplicationPolicyAcrossReleaseAndReattach() {
        let window = window()
        let policy = NSApp.activationPolicy()
        let original = (window.manualInteractionEnabled, window.ignoresMouseEvents, window.tabbingMode)
        for _ in 0..<2 {
            let lease = RegisteredPresentationLease(window: window)
            XCTAssertTrue(lease.acquire())
            XCTAssertEqual(NSApp.activationPolicy(), policy)
            XCTAssertEqual(window.manualInteractionEnabled, original.0)
            XCTAssertEqual(window.ignoresMouseEvents, original.1)
            XCTAssertEqual(window.tabbingMode, original.2)
            XCTAssertTrue(lease.present())
            XCTAssertFalse(lease.present())
            XCTAssertFalse(lease.restore(inputDrained: false))
            XCTAssertTrue(lease.restore(inputDrained: true))
            XCTAssertFalse(lease.restore(inputDrained: true))
            XCTAssertEqual(NSApp.activationPolicy(), policy)
            XCTAssertEqual(window.manualInteractionEnabled, original.0)
            XCTAssertEqual(window.ignoresMouseEvents, original.1)
            XCTAssertEqual(window.tabbingMode, original.2)
        }
    }

    func testForeignLeaseCannotAcquireOrReleaseExistingLease() {
        let window = window()
        let owner = RegisteredPresentationLease(window: window)
        let other = RegisteredPresentationLease(window: window)
        XCTAssertTrue(owner.acquire())
        XCTAssertFalse(other.acquire())
        XCTAssertFalse(other.restore(inputDrained: true))
        XCTAssertTrue(owner.restore(inputDrained: true))
        XCTAssertTrue(other.acquire())
        XCTAssertTrue(other.restore(inputDrained: true))
    }

    func testHiddenWindowRemainsHidden() {
        let window = window()
        let lease = RegisteredPresentationLease(window: window)
        XCTAssertFalse(lease.present())
        XCTAssertTrue(lease.acquire())
        XCTAssertTrue(lease.present())
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(lease.restore(inputDrained: true))
    }

    func testReleaseEnablesManualInputBeforeConfirmingHandoff() {
        let window = window()
        let lease = RegisteredPresentationLease(window: window)
        XCTAssertTrue(lease.acquire())
        window.setManualInteractionEnabled(false)
        window.ignoresMouseEvents = true
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertTrue(window.manualInteractionEnabled)
        XCTAssertFalse(window.ignoresMouseEvents)
    }
}
#endif
