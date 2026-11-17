#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
import WebKit
import XCTest
import ObjectiveC
import SafarierObjCSupport

@MainActor final class RegisteredActivityReleaseTests: XCTestCase {
    func testFinishRestoresLocalKeyWindowHookWithoutWaitingForPageUpdate() throws {
        let app = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -100000, y: -100000, width: 240, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = WKWebView(frame: window.contentView!.bounds, configuration: WKWebViewConfiguration())
        window.contentView = view
        let method = try XCTUnwrap(class_getInstanceMethod(object_getClass(app), #selector(getter: NSApplication.keyWindow)))
        let original = unsafeBitCast(method_getImplementation(method), to: UInt.self)
        var token: AnyObject?
        var detail: NSString?
        let started = SFRBeginBackgroundPageActivity(view, &token, {}, &detail)
        XCTAssertEqual(started, .OK, "\(detail ?? "")")
        guard started == .OK, let token else { return }
        var finished = false
        let result = SFRFinishBackgroundPageActivity(token, false, { finished = true }, &detail)
        XCTAssertEqual(result, .OK, "\(detail ?? "")")
        XCTAssertTrue(finished, "local release must not wait for a WebContent activity callback")
        XCTAssertEqual(unsafeBitCast(method_getImplementation(method), to: UInt.self), original)
    }
}
#endif
