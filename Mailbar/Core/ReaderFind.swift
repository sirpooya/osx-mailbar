import Foundation

/// Find in the open message (M22): the app's own scripts, run in the `.defaultClient` world like
/// the search marks (`SearchHighlight.bodyScript`), so the message's own script stays off.
/// Matching folds case and the Arabic ye and kaf, as the search marks do.
enum ReaderFind {

    /// "2 of 7", "No matches", or nothing while the field is empty.
    static func countLabel(index: Int, total: Int, query: String) -> String {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard total > 0 else { return "No matches" }
        return "\(min(index, total - 1) + 1) of \(total)"
    }

    /// The next match, wrapping round at either end.
    static func step(_ index: Int, by delta: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return ((index + delta) % total + total) % total
    }

    /// Takes the find marks out again, leaving the text as it was. Called as a function body.
    static let clearScript = """
    const marks = document.querySelectorAll('mark[data-mailbar-find]');
    marks.forEach(m => {
      const parent = m.parentNode;
      if (!parent) { return; }
      parent.replaceChild(document.createTextNode(m.textContent), m);
      parent.normalize();
    });
    return marks.length;
    """

    /// Clears the last find, then marks every match of `query` in the body. Returns the count.
    /// Text inside a search mark is still searched; text inside a find mark never is twice.
    static let markScript = clearScript.replacingOccurrences(of: "return marks.length;", with: "") + """
    const fold = s => s.replace(/[\\u064A\\u0649]/g, '\\u06CC').replace(/\\u0643/g, '\\u06A9').toLowerCase();
    const want = fold(query);
    const body = document.body;
    if (!body || want.length === 0) { return 0; }
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, {
      acceptNode: n => {
        const p = n.parentElement;
        if (!p || /^(SCRIPT|STYLE|TITLE)$/.test(p.tagName) || p.hasAttribute('data-mailbar-find')) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    const nodes = [];
    while (walker.nextNode() && nodes.length < 20000) { nodes.push(walker.currentNode); }
    let count = 0;
    for (const node of nodes) {
      if (count >= 1000) { break; }
      const text = node.nodeValue, folded = fold(text);
      if (folded.length !== text.length) { continue; }
      const hits = [];
      for (let i = folded.indexOf(want); i >= 0; i = folded.indexOf(want, i + want.length)) { hits.push(i); }
      if (hits.length === 0) { continue; }
      const fragment = document.createDocumentFragment();
      let at = 0;
      for (const start of hits) {
        if (start > at) { fragment.appendChild(document.createTextNode(text.slice(at, start))); }
        const mark = document.createElement('mark');
        mark.setAttribute('data-mailbar-find', '');
        mark.textContent = text.slice(start, start + want.length);
        mark.style.setProperty('background', '#fde68a', 'important');
        mark.style.setProperty('color', '#000', 'important');
        mark.style.setProperty('border-radius', '2px');
        fragment.appendChild(mark);
        at = start + want.length;
        count++;
      }
      if (at < text.length) { fragment.appendChild(document.createTextNode(text.slice(at))); }
      node.parentNode.replaceChild(fragment, node);
    }
    return count;
    """

    /// Makes match `index` the current one, in Safari's orange, and scrolls it to the middle.
    static let selectScript = """
    const marks = document.querySelectorAll('mark[data-mailbar-find]');
    marks.forEach((m, k) => m.style.setProperty('background', k === index ? '#ff9f0a' : '#fde68a', 'important'));
    const current = marks[index];
    if (current) { current.scrollIntoView({ block: 'center', inline: 'nearest' }); }
    return marks.length;
    """

    /// The reader's text selection as plain text, for quoting it in a reply.
    static let selectionScript = """
    const selection = window.getSelection();
    return selection ? selection.toString() : '';
    """
}

/// The reader's text size on top of the fit to width (M22): browser-style steps, kept for the
/// app's run and never saved.
enum ReaderZoom {
    static let steps: [Double] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func larger(than factor: Double) -> Double {
        steps.first { $0 > factor + 0.001 } ?? steps.last!
    }

    static func smaller(than factor: Double) -> Double {
        steps.last { $0 < factor - 0.001 } ?? steps.first!
    }

    /// "125%".
    static func label(_ factor: Double) -> String {
        "\(Int((factor * 100).rounded()))%"
    }

    /// The page zoom the web view gets: the fit's factor times the user's.
    static func pageZoom(fit: Double, user: Double) -> Double {
        fit * user
    }
}
