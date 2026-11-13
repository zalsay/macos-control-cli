import XCTest
import SafarierCore
@testable import Safarier

#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_NATIVE_INPUT_POLICY_TESTS
import AppKit
import WebKit
#endif

final class NativePageInputTests: XCTestCase {
    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_NATIVE_INPUT_POLICY_TESTS && !SAFARIER_WHEEL_OBSERVER_PROBE
    @MainActor func testRegisteredScrollRejectedBeforeTargetOrNativeActivity() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let webView = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: webView, window: window)
        let action = AutomationAction.scroll(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, deltaX: 0, deltaY: 1)
        do {
            _ = try await input.perform(action, viewVersion: 1)
            XCTFail("registered wheel must be rejected")
        } catch {
            XCTAssertEqual(error as? AutomationError, AutomationError(code: .uiPolicyUnavailable))
        }
        XCTAssertNil(input.activityLease)
        XCTAssertFalse(input.activityClosed)
        XCTAssertFalse(input.requiresOwnedTargetDestruction)
        XCTAssertEqual(input.buttonMask, 0)
        do {
            _ = try await input.perform(.move(point: ViewportPoint(x: 1, y: 1), viewVersion: 1), viewVersion: 1)
            XCTFail("an unstarted input must fail existing target checks")
        } catch {
            XCTAssertEqual(error as? AutomationError, AutomationError(code: .targetChanged))
        }
    }
    @MainActor func testDirectRegisteredScrollStopsBeforeTargetValidation() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let webView = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: webView, window: window)
        input.scroll(1, 1, delta: 1)
        XCTAssertEqual(input.policyTestFailure, "registered wheel unavailable")
        XCTAssertFalse(input.policyTestUncertainDispatch)
        XCTAssertNil(input.activityLease)
        XCTAssertEqual(input.buttonMask, 0)
    }

    @MainActor func testRegisteredNativeMoveChecksGenerationBeforeDispatch() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 120), configuration: WKWebViewConfiguration())
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: webView, window: window)
        var validations = 0
        input.registeredTargetValidator = { validations += 1; return false }
        input.move(1, 1)
        XCTAssertEqual(validations, 1)
        XCTAssertEqual(input.policyTestFailure, "registered presentation lease changed")
        XCTAssertFalse(input.policyTestUncertainDispatch)
        XCTAssertNil(input.activityLease)
    }
    #endif
    #if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_NATIVE_INPUT_POLICY_TESTS && SAFARIER_WHEEL_OBSERVER_PROBE
    @MainActor func testDedicatedWheelProbeKeepsExistingTargetPreflight() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let webView = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let input = NativePageInput.unstartedRegisteredInputForPolicyTest(webView: webView, window: window)
        let action = AutomationAction.scroll(point: ViewportPoint(x: 1, y: 1), viewVersion: 1, deltaX: 0, deltaY: 1)
        do {
            _ = try await input.perform(action, viewVersion: 1)
            XCTFail("an unstarted probe must fail existing target checks")
        } catch {
            XCTAssertEqual(error as? AutomationError, AutomationError(code: .targetChanged))
        }
        XCTAssertNil(input.activityLease)
    }
    #endif
    @MainActor func testShippingAdmissionIsUnavailableWithoutWebKitConstruction() {
        XCTAssertFalse(NativePageInput.shippingAdmissionAvailable)
        XCTAssertThrowsError(try NativePageInput.requireShippingAdmission()) {
            XCTAssertEqual($0 as? AutomationError, AutomationError(code: .uiPolicyUnavailable))
        }
    }
}
