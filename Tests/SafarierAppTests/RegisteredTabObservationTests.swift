#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
import WebKit
import XCTest
import SafarierCore
@testable import SafarierWebKit
@testable import Safarier

@MainActor
final class RegisteredTabObservationTests: XCTestCase {
    #if SAFARIER_REGISTERED_TAB_TESTS
    func testSessionSelectsOnlyCurrentTabAndRejectsMultipleGroups() throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(), report: PrivacyCapabilityReport(), executionPolicy: .interactive)
        let session = BrowserSession(profile: Profile(name: "isolated-tab", mode: .ephemeral), output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics())
        let a = session.makeRegisteredTestController(), b = session.makeRegisteredTestController()
        a.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        b.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        a.window.addTabbedWindow(b.window, ordered: .above)
        let group = try XCTUnwrap(a.window.tabGroup)
        group.selectedWindow = b.window
        let flag = TabRevocationFlag()
        let (selected, optionalMonitor) = try session.selectRegisteredTarget(first: a, onRevoke: { flag.mark() }, onInvalidated: {})
        let monitor = try XCTUnwrap(optionalMonitor)
        XCTAssertTrue(selected === b)
        XCTAssertTrue(session.registeredTargetValid(b, monitor: monitor))
        XCTAssertFalse(session.registeredTargetValid(a, monitor: monitor))
        session.setRegisteredPolicyTestTarget(b, monitor: monitor)
        var blocked = 0
        session.onAutomationUIBlocked = { _ in blocked += 1 }
        XCTAssertEqual(session.controllerPolicy(a), .interactive)
        XCTAssertEqual(session.controllerPolicy(b), .automationBackground)
        XCTAssertTrue(session.routeControllerUI(.alert, controller: a, perform: { true }, deny: { false }))
        XCTAssertFalse(session.routeControllerUI(.alert, controller: b, perform: { true }, deny: { false }))
        XCTAssertEqual(blocked, 1)
        group.selectedWindow = a.window
        XCTAssertTrue(flag.value)
        XCTAssertFalse(session.registeredTargetValid(b, monitor: monitor))
        group.selectedWindow = b.window
        XCTAssertFalse(session.registeredTargetValid(b, monitor: monitor))
        let c = session.makeRegisteredTestController()
        c.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        XCTAssertThrowsError(try session.selectRegisteredTarget(first: a, onRevoke: {}, onInvalidated: {}))
    }

    func testSessionNewSeparateWindowSynchronouslyRevokesSelectedGeneration() throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(), report: PrivacyCapabilityReport(), executionPolicy: .interactive)
        let session = BrowserSession(profile: Profile(name: "isolated-new-window", mode: .ephemeral), output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics())
        let a = session.makeRegisteredTestController(), b = session.makeRegisteredTestController()
        a.window.setFrameOrigin(NSPoint(x: -100000, y: -100000)); b.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        a.window.addTabbedWindow(b.window, ordered: .above)
        let group = try XCTUnwrap(a.window.tabGroup); group.selectedWindow = a.window
        let flag = TabRevocationFlag()
        let (_, optionalMonitor) = try session.selectRegisteredTarget(first: a, onRevoke: { flag.mark() }, onInvalidated: {})
        let monitor = try XCTUnwrap(optionalMonitor)
        session.setRegisteredPolicyTestTarget(a, monitor: monitor)
        XCTAssertFalse(flag.value)
        _ = session.makeRegisteredTestController()
        XCTAssertTrue(flag.value)
        XCTAssertFalse(monitor.isValid())
    }

    #if SAFARIER_NATIVE_INPUT_POLICY_TESTS
    func testSessionCleanupDrainsOriginalInputAndRestoresOriginalWindowAfterSwitch() async throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(), report: PrivacyCapabilityReport(), executionPolicy: .interactive)
        let session = BrowserSession(profile: Profile(name: "isolated-cleanup", mode: .ephemeral), output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics())
        let a = session.makeRegisteredTestController(), b = session.makeRegisteredTestController()
        a.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        b.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        a.window.addTabbedWindow(b.window, ordered: .above)
        let group = try XCTUnwrap(a.window.tabGroup)
        group.selectedWindow = a.window
        let (_, optionalMonitor) = try session.selectRegisteredTarget(first: a, onRevoke: {}, onInvalidated: {})
        let monitor = try XCTUnwrap(optionalMonitor)
        let window = try XCTUnwrap(a.window as? NonActivatingBrowserWindow)
        let lease = RegisteredPresentationLease(window: window)
        guard lease.acquire() else { throw XCTSkip("real policy acquisition unavailable in isolated test") }
        let generation = session.setRegisteredPolicyTestTarget(a, monitor: monitor, lease: lease)
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: a.webView, window: a.window)
        group.selectedWindow = b.window
        XCTAssertFalse(monitor.isValid())
        let cleaned = await session.quiesceAndRestoreRegisteredControl(controller: a, generation: generation, input: input)
        XCTAssertTrue(cleaned)
        XCTAssertTrue(input.activityClosed)
        XCTAssertTrue(a.window === lease.window)
        XCTAssertTrue(group.selectedWindow === b.window)
        XCTAssertEqual(session.executionPolicy, .interactive)
    }

    func testSessionCleanupFailsClosedWhenInputIsUncertain() async throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let output = WebViewConfigurationFactory.Output(configuration: WKWebViewConfiguration(), report: PrivacyCapabilityReport(), executionPolicy: .interactive)
        let session = BrowserSession(profile: Profile(name: "isolated-uncertain", mode: .ephemeral), output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics())
        let a = session.makeRegisteredTestController(), b = session.makeRegisteredTestController()
        a.window.setFrameOrigin(NSPoint(x: -100000, y: -100000)); b.window.setFrameOrigin(NSPoint(x: -100000, y: -100000))
        a.window.addTabbedWindow(b.window, ordered: .above)
        let group = try XCTUnwrap(a.window.tabGroup); group.selectedWindow = a.window
        let (_, optionalMonitor) = try session.selectRegisteredTarget(first: a, onRevoke: {}, onInvalidated: {})
        let monitor = try XCTUnwrap(optionalMonitor)
        let window = try XCTUnwrap(a.window as? NonActivatingBrowserWindow)
        let lease = RegisteredPresentationLease(window: window)
        guard lease.acquire() else { throw XCTSkip("real policy acquisition unavailable in isolated test") }
        let generation = session.setRegisteredPolicyTestTarget(a, monitor: monitor, lease: lease)
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: a.webView, window: a.window)
        input.markPolicyTestUncertainDispatch()
        let cleaned = await session.quiesceAndRestoreRegisteredControl(controller: a, generation: generation, input: input)
        XCTAssertFalse(cleaned)
        XCTAssertTrue(input.requiresOwnedTargetDestruction)
        XCTAssertEqual(session.executionPolicy, .automationBackground)
        // No event or native activity was sent in this synthetic test.
        XCTAssertTrue(lease.restore(inputDrained: true))
    }
    #endif
    #endif
    private func window() -> NonActivatingBrowserWindow {
        let window = NonActivatingBrowserWindow(contentRect: NSRect(x: -100000, y: -100000, width: 240, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testMonitorRevokesOnSwitchBackMembershipOrOverview() throws {
        let app = NSApplication.shared
        guard !app.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window(), extra = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        let aID = UUID(), bID = UUID()
        group.selectedWindow = a
        let first = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, aID), (b, bID)], onInvalidated: {}))
        XCTAssertEqual(first.selectedID, aID)
        XCTAssertTrue(first.isValid())
        group.selectedWindow = b
        XCTAssertFalse(first.isValid())
        group.selectedWindow = a
        XCTAssertFalse(first.isValid())
        let second = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, aID), (b, bID)], onInvalidated: {}))
        XCTAssertTrue(second.isValid())
        group.addWindow(extra)
        group.removeWindow(extra)
        XCTAssertFalse(second.isValid())
        XCTAssertFalse(first.isValid())
        XCTAssertNil(RegisteredTabMonitor(group: group, windows: [(a, aID)], onInvalidated: {}))
    }

    func testRealAppPolicyLeasePreservesOtherTabProperties() throws {
        let app = NSApplication.shared
        guard !app.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        let originalB = (b.manualInteractionEnabled, b.ignoresMouseEvents, b.tabbingMode)
        let originalPolicy = app.activationPolicy()
        let lease = RegisteredPresentationLease(window: a)
        guard lease.acquire() else { throw XCTSkip("real policy acquisition unavailable in isolated test") }
        XCTAssertTrue(a.tabGroup === group && b.tabGroup === group && group.selectedWindow === a)
        XCTAssertEqual(b.manualInteractionEnabled, originalB.0)
        XCTAssertEqual(b.ignoresMouseEvents, originalB.1)
        XCTAssertEqual(b.tabbingMode, originalB.2)
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertEqual(app.activationPolicy(), originalPolicy)
        XCTAssertTrue(a.tabGroup === group && b.tabGroup === group && group.selectedWindow === a)
        XCTAssertEqual(b.manualInteractionEnabled, originalB.0)
        XCTAssertEqual(b.ignoresMouseEvents, originalB.1)
        XCTAssertEqual(b.tabbingMode, originalB.2)
        XCTAssertFalse(app.isActive)
    }

    func testLeaseRestoreDoesNotRevokeUnchangedTabMonitor() throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        let flag = TabRevocationFlag()
        let monitor = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, UUID()), (b, UUID())], onRevoke: { flag.mark() }, onInvalidated: {}))
        let lease = RegisteredPresentationLease(window: a)
        guard lease.acquire() else { throw XCTSkip("real policy acquisition unavailable in isolated test") }
        XCTAssertTrue(monitor.isValid())
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertFalse(flag.value)
        XCTAssertTrue(monitor.isValid())
    }

    func testSelectionChangeRevokesMonitorAndRestoresOnlyOriginalLease() throws {
        let app = NSApplication.shared
        guard !app.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        let aID = UUID(), bID = UUID()
        let monitor = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, aID), (b, bID)], onInvalidated: {}))
        let beforeB = (b.manualInteractionEnabled, b.ignoresMouseEvents, b.tabbingMode)
        let lease = RegisteredPresentationLease(window: a)
        guard lease.acquire() else { throw XCTSkip("real policy acquisition unavailable in isolated test") }
        XCTAssertTrue(monitor.isValid())
        group.selectedWindow = b
        XCTAssertFalse(monitor.isValid())
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertTrue(group.selectedWindow === b)
        XCTAssertTrue(a.tabGroup === group && b.tabGroup === group)
        XCTAssertEqual(b.manualInteractionEnabled, beforeB.0)
        XCTAssertEqual(b.ignoresMouseEvents, beforeB.1)
        XCTAssertEqual(b.tabbingMode, beforeB.2)
        XCTAssertFalse(monitor.isValid())
        XCTAssertFalse(app.isActive)
    }

    func testSelectionChangeKeepsOriginalWebViewWindowForCleanup() throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 240, height: 160), configuration: WKWebViewConfiguration())
        a.contentView = view
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        XCTAssertTrue(view.window === a)
        let lease = RegisteredPresentationLease(window: a)
        guard lease.acquire() else { throw XCTSkip("real policy acquisition unavailable in isolated test") }
        group.selectedWindow = b
        XCTAssertTrue(view.window === a)
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertTrue(view.window === a)
        XCTAssertTrue(group.selectedWindow === b)
    }

    func testStoppedOldMonitorDoesNotDeliverQueuedInvalidation() async throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        var oldCallbacks = 0, newCallbacks = 0
        let ids = [(a as NSWindow, UUID()), (b as NSWindow, UUID())]
        let old = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: ids, onInvalidated: { oldCallbacks += 1 }))
        group.selectedWindow = b
        XCTAssertFalse(old.isValid())
        old.stop()
        let next = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: ids, onInvalidated: { newCallbacks += 1 }))
        await Task.yield()
        XCTAssertEqual(oldCallbacks, 0)
        XCTAssertEqual(newCallbacks, 0)
        XCTAssertTrue(next.isValid())
    }

    func testMultipleKVOEventsNotifyOnlyOnce() async throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        var callbacks = 0
        let monitor = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, UUID()), (b, UUID())], onInvalidated: { callbacks += 1 }))
        group.selectedWindow = b
        group.selectedWindow = a
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(callbacks, 1)
        XCTAssertFalse(monitor.isValid())
    }

    func testRevocationClosesAuthoritySynchronouslyBeforeCallback() async throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        let flag = TabRevocationFlag()
        var cleanupCalls = 0
        let monitor = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, UUID()), (b, UUID())], onRevoke: { flag.mark() }, onInvalidated: { cleanupCalls += 1 }))
        group.selectedWindow = b
        XCTAssertTrue(flag.value)
        XCTAssertFalse(monitor.isValid())
        XCTAssertEqual(cleanupCalls, 0)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(cleanupCalls, 1)
    }

    func testMonitorRevokesWhenSelectedTargetIsRemoved() throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        let monitor = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, UUID()), (b, UUID())], onInvalidated: {}))
        XCTAssertTrue(monitor.isValid())
        group.removeWindow(a)
        XCTAssertFalse(monitor.isValid())
    }

    func testMonitorRevokesWhenOverviewAppears() throws {
        guard !NSApplication.shared.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        group.selectedWindow = a
        let monitor = try XCTUnwrap(RegisteredTabMonitor(group: group, windows: [(a, UUID()), (b, UUID())], onInvalidated: {}))
        XCTAssertTrue(monitor.isValid())
        group.isOverviewVisible = true
        XCTAssertFalse(monitor.isValid())
    }

    func testTabGroupKVOAndLeasePreserveSelectedOriginalGroup() throws {
        let app = NSApplication.shared
        guard !app.isActive else { throw XCTSkip("test process is active") }
        let a = window(), b = window(), extra = window()
        a.addTabbedWindow(b, ordered: .above)
        let group = try XCTUnwrap(a.tabGroup)
        XCTAssertTrue(group === b.tabGroup)
        var selections = 0, members = 0, overviews = 0
        let selection = group.observe(\.selectedWindow, options: [.old, .new]) { _, _ in selections += 1 }
        let membership = group.observe(\.windows, options: [.old, .new]) { _, _ in members += 1 }
        let overview = group.observe(\.isOverviewVisible, options: [.old, .new]) { _, _ in overviews += 1 }
        group.selectedWindow = b
        XCTAssertTrue(group.selectedWindow === b)
        XCTAssertGreaterThan(selections, 0)
        let countAfterSwitch = selections
        group.selectedWindow = a
        XCTAssertGreaterThan(selections, countAfterSwitch)
        group.addWindow(extra)
        group.removeWindow(extra)
        XCTAssertGreaterThanOrEqual(members, 2)
        var policy = NSApplication.ActivationPolicy.regular
        let lease = RegisteredPresentationLease(window: a, readPolicy: { policy }, setPolicy: { policy = $0; return true }, isActive: { false })
        XCTAssertTrue(lease.acquire())
        XCTAssertTrue(group.selectedWindow === a)
        XCTAssertTrue(a.tabGroup === group && b.tabGroup === group)
        XCTAssertEqual(group.windows.count, 2)
        XCTAssertTrue(lease.restore(inputDrained: true))
        XCTAssertTrue(group.selectedWindow === a)
        XCTAssertTrue(a.tabGroup === group && b.tabGroup === group)
        group.isOverviewVisible = true
        XCTAssertGreaterThan(overviews, 0)
        XCTAssertFalse(app.isActive)
        withExtendedLifetime((selection, membership, overview)) {}
    }
}

private final class TabRevocationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); marked = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}
#endif
