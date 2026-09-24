import AppKit
import SwiftUI
import WebKit

/// The message body, in a `WKWebView` that can neither run script nor remember anything.
///
/// - JavaScript off (`allowsContentJavaScript = false`), in addition to the CSP in `ReaderHTML`.
/// - A NON-PERSISTENT data store, a new one per reader: no cookies, no cache, no local storage on
///   disk. When the reader closes, the store and everything it held (remote images included, if
///   they were loaded) go with it.
/// - The one navigation allowed is the initial load of the document. A clicked link opens in the
///   default browser, which is the user's own act; everything else is refused.
struct MessageWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = true
        context.coordinator.load(html, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, into: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        // Drops the document, and with it the decoded images, before the view is released.
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded: String?

        func load(_ html: String, into view: WKWebView) {
            guard html != loaded else { return }
            loaded = html
            #if DEBUG
            FileHandle.standardError.write(Data("[reader] loading \(html.utf8.count) bytes\n".utf8))
            #endif
            // Measured afresh for every document ("Load images" reloads), so start from 1.
            view.pageZoom = 1
            view.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await fitToWidth(webView) }
        }

        /// Zooms a fixed-width message out until it fits the reader, the way Mail does.
        ///
        /// Newsletters and HR mail are laid out as a 600px table; the reader is 380pt wide, so
        /// without this the right side of the message sat off screen. `pageZoom` is browser zoom,
        /// not a bitmap scale: the page lays out again at width / zoom, so text stays sharp and
        /// a layout that can reflow still does.
        ///
        /// The width is read with one line of app-side script. That is not the page's script,
        /// which stays off: `allowsContentJavaScript = false` governs the message's own code, and
        /// this runs in the app's `.defaultClient` world, reading one number and changing nothing.
        private func fitToWidth(_ webView: WKWebView) async {
            let available = webView.bounds.width
            guard available > 0,
                  let measured = try? await webView.evaluateJavaScript(
                      "document.documentElement.scrollWidth", in: nil, contentWorld: .defaultClient),
                  let contentWidth = (measured as? NSNumber)?.doubleValue,
                  contentWidth > available + 1 else { return }
            // Floor, so a very wide message is scrollable rather than unreadably small.
            webView.pageZoom = max(0.45, available / contentWidth)
        }

        #if DEBUG
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            FileHandle.standardError.write(Data("[reader] didFail \(error)\n".utf8))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            FileHandle.standardError.write(Data("[reader] didFailProvisional \(error)\n".utf8))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            FileHandle.standardError.write(Data("[reader] content process terminated\n".utf8))
        }
        #endif

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            // The document itself, loaded from a string, arrives as about:blank.
            if url?.scheme == "about" || url == nil {
                decisionHandler(navigationAction.targetFrame?.isMainFrame == false ? .cancel : .allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
