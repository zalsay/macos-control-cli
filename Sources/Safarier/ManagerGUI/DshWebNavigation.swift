import AppKit
import WebKit

/// Routes user navigation from the DSH workbench, without turning its embedded
/// WebView into a second browser or altering its internal routes and storage.
@MainActor
final class DshWebNavigation: NSObject, WKUIDelegate, WKNavigationDelegate {
    var serviceURL: URL
    private let openExternal: (URL) -> Void

    init(serviceURL: URL, openExternal: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.serviceURL = serviceURL
        self.openExternal = openExternal
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = webOrigin(lhs), let b = webOrigin(rhs) else { return false }
        return a == b
    }

    private static func webOrigin(_ url: URL) -> (String, String, Int)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80))
    }

    private func webURLFromWorkbench(_ action: WKNavigationAction) -> URL? {
        guard action.sourceFrame.isMainFrame, let source = action.sourceFrame.request.url,
              Self.sameOrigin(source, serviceURL), let url = action.request.url,
              Self.webOrigin(url) != nil else { return nil }
        return url
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // DSH uses both target=_blank and window.open on a user gesture.
        // WebKit filters unsolicited script popups via the page preference.
        guard navigationAction.targetFrame == nil, let url = webURLFromWorkbench(navigationAction) else { return nil }
        if Self.sameOrigin(url, serviceURL) {
            webView.load(navigationAction.request)
        } else {
            openExternal(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
              let url = webURLFromWorkbench(navigationAction), !Self.sameOrigin(url, serviceURL) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openExternal(url)
    }
}
