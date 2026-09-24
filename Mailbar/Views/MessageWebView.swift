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

        /// Makes the message fit the reader's width with no sideways scroll, the way Mail does.
        ///
        /// Two kinds of wide content need different treatment:
        /// - **Large images** (a 1600px photo in an otherwise plain email). These are shrunk to the
        ///   width the rest of the message occupies, with width AND height set together from the
        ///   image's rendered size, so each keeps exactly the proportions the sender gave it,
        ///   spacers and deliberately stretched images included.
        /// - **Fixed-width layouts** (a 600px newsletter table). These are zoomed as a whole with
        ///   `pageZoom`, which is browser zoom, not a bitmap scale: the page lays out again at
        ///   width / zoom, so text stays sharp and everything shrinks by the same factor.
        ///
        /// Images go first, because a large image is what made a plain email look like a wide layout
        /// and pushed the zoom to its floor, leaving a sideways scroll (reported 2026-09-24).
        ///
        /// This is the app's own script, in the `.defaultClient` world, not the page's: the
        /// message's code stays off (`allowsContentJavaScript = false`).
        private func fitToWidth(_ webView: WKWebView) async {
            let available = webView.bounds.width
            guard available > 0,
                  let measured = try? await webView.evaluateJavaScript(
                      Self.fitImagesScript, in: nil, contentWorld: .defaultClient),
                  let contentWidth = (measured as? NSNumber)?.doubleValue,
                  contentWidth > available + 1 else { return }
            // Floor, so a very wide layout scrolls rather than turning unreadably small.
            webView.pageZoom = max(0.45, available / contentWidth)
        }

        /// Shrinks every image wider than the message's own layout to that layout's width,
        /// proportionally, and returns the document width that is left for the zoom.
        ///
        /// The layout width is measured with the oversized images taken out, so a 600px table
        /// keeps its 600px banner untouched, while a lone photo in a plain email is fitted to the
        /// text column.
        static let fitImagesScript = """
        (() => {
          const root = document.documentElement, body = document.body;
          if (!body) { return root.scrollWidth; }
          const viewport = root.clientWidth, column = body.clientWidth;
          const big = Array.from(document.images).filter(i => i.getBoundingClientRect().width > column + 0.5);
          if (big.length === 0) { return root.scrollWidth; }
          const sizes = big.map(i => { const r = i.getBoundingClientRect(); return [r.width, r.height]; });
          big.forEach(i => i.style.setProperty('display', 'none', 'important'));
          const layout = root.scrollWidth;
          const cap = layout <= viewport + 1 ? column : layout - body.offsetLeft;
          big.forEach((img, k) => {
            img.style.removeProperty('display');
            const [w, h] = sizes[k];
            if (w > cap) {
              img.style.setProperty('width', cap + 'px', 'important');
              img.style.setProperty('height', (h * cap / w) + 'px', 'important');
              img.style.setProperty('max-width', 'none', 'important');
            }
          });
          return root.scrollWidth;
        })()
        """

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
