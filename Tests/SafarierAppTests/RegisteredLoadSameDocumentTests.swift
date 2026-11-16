import XCTest
import AppKit
import WebKit
import Network
import SafarierObjCSupport
@testable import Safarier

#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
final class RegisteredLoadSameDocumentTests: XCTestCase {
    private let response = URL(string: "https://example.com/search?q=fixture")!
    private let updated = URL(string: "https://example.com/search?q=fixture&state=loaded")!

    func testCommittedLoadAcceptsHistoryUpdateAndStillWaitsForOriginalFinish() {
        let root = NSObject()
        var correlation = NavigationCorrelation()
        let epoch = correlation.begin(root)
        XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 2,
            response: response, request: updated, current: updated))
        XCTAssertTrue(correlation.noteCommitted(root, epoch: epoch))
        XCTAssertTrue(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 2,
            response: response, request: updated, current: updated))
        XCTAssertTrue(correlation.matches(root, epoch: epoch), "history update must retain the original load")
        XCTAssertTrue(correlation.noteFinished(root, epoch: epoch))
        XCTAssertTrue(correlation.finish(root, epoch: epoch))
        XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 2,
            response: response, request: updated, current: updated))
    }

    func testRejectsStaleLoadWrongOriginUnsupportedTypeAndURLMismatch() {
        let root = NSObject()
        var correlation = NavigationCorrelation()
        let epoch = correlation.begin(root)
        XCTAssertTrue(correlation.noteCommitted(root, epoch: epoch))
        XCTAssertFalse(correlation.acceptsLoadSameDocument(NSObject(), epoch: epoch, type: 2,
            response: response, request: updated, current: updated))
        XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch + 1, type: 2,
            response: response, request: updated, current: updated))
        for target in ["https://other.example/search", "http://example.com/search", "https://example.com:8443/search", "https://user:pass@example.com/search", "file:///tmp/fixture"] {
            let url = URL(string: target)!
            XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 2,
                response: response, request: url, current: url))
        }
        XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 3,
            response: response, request: updated, current: updated))
        XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 2,
            response: response, request: nil, current: updated))
        XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 2,
            response: response, request: updated, current: response))
        XCTAssertFalse(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 2,
            response: nil, request: updated, current: updated))
        XCTAssertTrue(correlation.acceptsLoadSameDocument(root, epoch: epoch, type: 1,
            response: response, request: response, current: response))
    }

    @MainActor func testRealWebKitHistoryCallbacksKeepWaitingForFullLoad() async throws {
        let server = try HistoryLoadHTTPFixture()
        defer { server.listener.cancel() }
        let deadline = ContinuousClock.now + .seconds(8)
        while !server.isReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let port = try XCTUnwrap(server.listener.port)
        XCTAssertNotEqual(port.rawValue, 0)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/result"))
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        let delegate = HistoryLoadDelegate(response: url)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        delegate.root = try XCTUnwrap(view.load(URLRequest(url: url)))
        delegate.epoch = delegate.correlation.begin(try XCTUnwrap(delegate.root))
        while !delegate.finished, delegate.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(delegate.failure)
        XCTAssertTrue(delegate.finished, "the original full load must still finish")
        XCTAssertEqual(delegate.acceptedTypes, [2, 1])
        XCTAssertTrue(delegate.callbacksBeforeFinish)
        XCTAssertEqual(view.url?.query, "state=finished")
    }
}

private final class HistoryLoadHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "safarier.history-load-fixture")
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock(); self.ready = true; self.lock.unlock()
        }
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let slow = data.map { String(decoding: $0, as: UTF8.self).hasPrefix("GET /slow") } ?? false
                let body = slow ? "<svg xmlns='http://www.w3.org/2000/svg'/>" : """
                    <!doctype html><title>History load fixture</title>
                    <script>history.replaceState(null,'','/result?state=ready');history.pushState(null,'','/result?state=finished');</script>
                    <img src='/slow.svg'>
                    """
                let mime = slow ? "image/svg+xml" : "text/html"
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)".utf8)
                queue.asyncAfter(deadline: .now() + (slow ? 0.3 : 0)) {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
    }
}

@MainActor private final class HistoryLoadDelegate: NSObject, WKNavigationDelegate {
    var root: WKNavigation?
    var correlation = NavigationCorrelation()
    var epoch: UInt64 = 0
    var response: URL
    var finished = false
    var failure: String?
    var acceptedTypes: [Int] = []
    var callbacksBeforeFinish = true
    init(response: URL) { self.response = response }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let root, root === navigation, correlation.noteCommitted(root, epoch: epoch) else {
            failure = "uncorrelated commit"; return
        }
    }
    @objc(_webView:navigation:didSameDocumentNavigation:)
    func sameDocument(_ view: WKWebView?, navigation: AnyObject?, type: Int) {
        var requestObject: AnyObject?
        guard let root, let navigation = navigation as? WKNavigation,
              SFRGetObject(navigation, "_request", &requestObject, nil).rawValue == 0,
              let request = requestObject as? NSURLRequest, let url = request.url,
              correlation.acceptsLoadSameDocument(root, epoch: epoch, type: type,
                  response: response, request: url, current: view?.url) else {
            failure = "real history callback was rejected"; return
        }
        callbacksBeforeFinish = callbacksBeforeFinish && !finished
        acceptedTypes.append(type); response = url
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let root, root === navigation, correlation.noteFinished(root, epoch: epoch) else {
            failure = "uncorrelated finish"; return
        }
        finished = true
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = "load failed" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = "provisional load failed" }
}
#endif
