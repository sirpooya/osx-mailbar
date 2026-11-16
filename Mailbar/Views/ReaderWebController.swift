import Foundation
import Observation
import WebKit

/// What the reader asks of its message web view (M22): find in the body, the text size, and the
/// text selection. One per open reader, held in its state; it holds the web view weakly, so it
/// keeps nothing of the message once the reader closes.
///
/// For the composer: `await ReaderWebController.active?.selectedText()` is the open message's
/// selected text as plain text, or "" when nothing is selected or no message is open.
@MainActor
@Observable
final class ReaderWebController {
    /// The controller of the reader on screen, if any. Set when its web view appears.
    static weak var active: ReaderWebController?

    /// The user's text size for this run of the app, on top of each message's fit. Never saved.
    private static var sessionZoom: Double = 1

    @ObservationIgnored private weak var webView: WKWebView?
    /// The fit to width's factor for the document showing, measured after each load.
    @ObservationIgnored private var fitZoom: Double = 1

    private(set) var zoom: Double = ReaderWebController.sessionZoom

    /// The find bar's words, the number of matches and the current one (from 0).
    private(set) var findQuery = ""
    private(set) var findTotal = 0
    private(set) var findIndex = 0

    func attach(_ view: WKWebView) {
        webView = view
        Self.active = self
    }

    // MARK: - Selection

    /// The selected text in the message body, as plain text; "" when there is none.
    func selectedText() async -> String {
        guard let webView else { return "" }
        let result = try? await webView.callAsyncJavaScript(ReaderFind.selectionScript, arguments: [:],
                                                            in: nil, contentWorld: .defaultClient)
        return (result as? String) ?? ""
    }

    // MARK: - Zoom

    func zoomIn() { setZoom(ReaderZoom.larger(than: zoom)) }
    func zoomOut() { setZoom(ReaderZoom.smaller(than: zoom)) }
    func resetZoom() { setZoom(1) }

    func setZoom(_ factor: Double) {
        zoom = factor
        Self.sessionZoom = factor
        applyZoom()
    }

    /// Called by the web view after each load: the fit was measured at the user's 100 percent.
    func documentDidFit(fitZoom: Double) async {
        self.fitZoom = fitZoom
        applyZoom()
        if !findQuery.isEmpty { await find(findQuery) }
    }

    /// Called as a new document starts loading: the fit is measured again from 1.
    func documentWillLoad() {
        fitZoom = 1
    }

    private func applyZoom() {
        webView?.pageZoom = ReaderZoom.pageZoom(fit: fitZoom, user: zoom)
    }

    // MARK: - Find

    var findLabel: String {
        ReaderFind.countLabel(index: findIndex, total: findTotal, query: findQuery)
    }

    /// Marks every match and makes the first one current.
    func find(_ query: String) async {
        findQuery = query
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let webView else { return }
        let count = try? await webView.callAsyncJavaScript(ReaderFind.markScript, arguments: ["query": words],
                                                           in: nil, contentWorld: .defaultClient)
        // A newer search has started meanwhile: its answer is the one to keep.
        guard query == findQuery else { return }
        findTotal = (count as? NSNumber)?.intValue ?? 0
        findIndex = 0
        await select(0)
    }

    /// The next match (1) or the one before (-1), round at the ends.
    func step(_ delta: Int) async {
        guard findTotal > 0 else { return }
        findIndex = ReaderFind.step(findIndex, by: delta, total: findTotal)
        await select(findIndex)
    }

    /// Closes the find: its marks come out, the search's marks stay.
    func endFind() async {
        findQuery = ""
        findTotal = 0
        findIndex = 0
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(ReaderFind.clearScript, arguments: [:],
                                                   in: nil, contentWorld: .defaultClient)
    }

    private func select(_ index: Int) async {
        guard let webView, findTotal > 0 else { return }
        _ = try? await webView.callAsyncJavaScript(ReaderFind.selectScript, arguments: ["index": index],
                                                   in: nil, contentWorld: .defaultClient)
    }
}
