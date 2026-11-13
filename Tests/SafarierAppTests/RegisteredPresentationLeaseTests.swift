#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
import XCTest
@testable import Safarier

@MainActor final class RegisteredPresentationLeaseTests: XCTestCase {
    private func window() -> NonActivatingBrowserWindow {
        _ = NSApplication.shared
        let window = NonActivatingBrowserWindow(contentRect: .zero, styleMask: [.titled,.closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
    func testSameWindowLeaseDisablesAndRestoresOnlyAfterDrainAndCanReattach() {
        let window = window()
        XCTAssertTrue(window.manualInteractionEnabled)
        XCTAssertTrue(window.canBecomeKey)
        var policy = NSApplication.ActivationPolicy.regular
        for _ in 0..<2 {
            let lease = RegisteredPresentationLease(window: window, readPolicy: { policy }, setPolicy: { policy = $0; return true }, isActive: { false })
            XCTAssertTrue(lease.acquire())
            XCTAssertEqual(policy, .accessory)
            XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
            XCTAssertTrue(window.ignoresMouseEvents)
            XCTAssertFalse(lease.restore(inputDrained: false))
            XCTAssertEqual(policy, .accessory)
            XCTAssertTrue(lease.restore(inputDrained: true))
            XCTAssertEqual(policy, .regular)
            XCTAssertTrue(window.manualInteractionEnabled)
            XCTAssertFalse(window.ignoresMouseEvents)
            XCTAssertFalse(lease.restore(inputDrained: true), "old lease cannot restore a second time")
        }
        XCTAssertFalse(window.isVisible)
    }
    func testAlreadyAccessorySkipsRejectingSetterForAcquireAndRestore() {
        let window = window()
        var setterCalls = 0
        let lease = RegisteredPresentationLease(window: window, readPolicy: { .accessory }, setPolicy: { _ in
            setterCalls += 1
            return false
        }, isActive: { false })
        XCTAssertTrue(lease.acquire())
        XCTAssertFalse(window.manualInteractionEnabled)
        XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(lease.restore(inputDrained: false))
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertTrue(window.manualInteractionEnabled)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(setterCalls, 0)
    }
    func testRequiredPolicyChangeReturningFalseStillRejectsEvenIfPolicyChanges() {
        let window = window()
        var policy = NSApplication.ActivationPolicy.regular
        let lease = RegisteredPresentationLease(window: window, readPolicy: { policy }, setPolicy: {
            policy = $0
            return false
        }, isActive: { false })
        XCTAssertFalse(lease.acquire())
        XCTAssertEqual(policy, .accessory)
        XCTAssertFalse(lease.restore(inputDrained: true))
        XCTAssertEqual(policy, .regular)
        XCTAssertFalse(window.manualInteractionEnabled)
        XCTAssertTrue(window.ignoresMouseEvents)
    }
    func testFailedAcquireRetainsSnapshotForDrainThenRollback() {
        let window = window()
        var policy = NSApplication.ActivationPolicy.regular
        let lease = RegisteredPresentationLease(window: window, readPolicy: { policy }, setPolicy: {
            if $0 == .accessory { return false }; policy = $0; return true
        }, isActive: { false })
        XCTAssertFalse(lease.acquire())
        XCTAssertFalse(window.manualInteractionEnabled)
        XCTAssertFalse(lease.restore(inputDrained: false))
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertTrue(window.manualInteractionEnabled)
    }
    func testFailedRestoreRemainsBlockedAndForeignLeaseCannotRestore() {
        let window = window()
        var policy = NSApplication.ActivationPolicy.regular
        let lease = RegisteredPresentationLease(window: window, readPolicy: { policy }, setPolicy: {
            if $0 == .regular { return false }; policy = $0; return true
        }, isActive: { false })
        XCTAssertTrue(lease.acquire())
        XCTAssertFalse(lease.restore(inputDrained: true))
        XCTAssertFalse(window.manualInteractionEnabled)
        XCTAssertTrue(window.ignoresMouseEvents)
        let foreign = RegisteredPresentationLease(window: window, readPolicy: { policy }, setPolicy: { policy = $0; return true }, isActive: { false })
        XCTAssertFalse(foreign.acquire())
        XCTAssertFalse(foreign.restore(inputDrained: true))
    }
    func testPolicyRestoreThatActivatesAppDoesNotEnableManualInteraction() {
        let window = window()
        var policy = NSApplication.ActivationPolicy.regular
        var active = false
        let lease = RegisteredPresentationLease(window: window, readPolicy: { policy }, setPolicy: {
            policy = $0
            if $0 == .regular { active = true }
            return true
        }, isActive: { active })
        XCTAssertTrue(lease.acquire())
        XCTAssertFalse(lease.restore(inputDrained: true))
        XCTAssertFalse(window.manualInteractionEnabled)
        XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(active, "failure handling must not manipulate global focus")
    }

    func testPresentationRejectsUnacquiredAndHiddenWindowWithoutShowingIt() {
        let window = window()
        let lease = RegisteredPresentationLease(window: window, readPolicy: { .accessory }, setPolicy: { _ in false }, isActive: { false })
        XCTAssertFalse(lease.present())
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(lease.acquire())
        XCTAssertFalse(lease.present(), "hidden window must not be silently shown by attach")
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(lease.restore(inputDrained: true))
    }

    func testAcquiredLeaseConfirmsSameVisibleWindowOnlyOnce() throws {
        let window = window()
        window.setFrame(NSRect(x: 100, y: 100, width: 400, height: 300), display: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let lease = RegisteredPresentationLease(window: window, readPolicy: { .accessory }, setPolicy: { _ in false }, isActive: { false })
        XCTAssertTrue(lease.acquire())
        guard NSEvent.pressedMouseButtons == 0, !NSApp.isActive, !NSApp.isHidden else {
            throw XCTSkip("Desktop conflict; positive presentation path not verified")
        }
        let presented = lease.present()
        guard NSEvent.pressedMouseButtons == 0 else {
            throw XCTSkip("Desktop changed during presentation; positive path not verified")
        }
        XCTAssertFalse(NSApp.isActive)
        XCTAssertFalse(NSApp.isHidden)
        XCTAssertTrue(presented)
        XCTAssertTrue(lease.window === window)
        XCTAssertFalse(window.isKeyWindow); XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(lease.present(), "one confirmation per acquired lease")
        XCTAssertFalse(lease.restore(inputDrained: false))
        XCTAssertTrue(lease.restore(inputDrained: true))
    }

}
#endif
