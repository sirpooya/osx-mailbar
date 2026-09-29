import AppKit
import SwiftUI

/// Where a search's words appear, marked in yellow as Outlook marks them: in the rows (sender,
/// subject, preview), the reader's subject, and the message body.
///
/// Matching ignores case and diacritics and folds the Arabic ye and kaf into the Persian ones, the
/// same rule the room search uses, so a query typed on either keyboard marks the same words.
enum SearchHighlight {

    /// The words of a query. Quotes and search operators ("from:", AND, OR, NOT) are not words
    /// anyone expects to see marked.
    static func terms(in query: String) -> [String] {
        let operators: Set<String> = ["and", "or", "not"]
        let words = query.split(whereSeparator: \.isWhitespace).compactMap { raw -> String? in
            var word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
            if let colon = word.firstIndex(of: ":") { word = String(word[word.index(after: colon)...]) }
            return word.isEmpty || operators.contains(word.lowercased()) ? nil : word
        }
        // Longest first, so "design" is not marked inside a longer term that already covers it.
        return Array(Set(words)).sorted { $0.count > $1.count }
    }

    /// Each place a term appears in `text`, merged where they overlap, in order.
    static func ranges(of terms: [String], in text: String) -> [Range<String.Index>] {
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        // Folding swaps one UTF-16 unit for another, so offsets in the folded copy are offsets
        // in the original.
        let folded = fold(text)
        var found: [Range<Int>] = []
        for term in terms.map(fold) where !term.isEmpty {
            var from = folded.startIndex
            while let hit = folded.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                         range: from..<folded.endIndex) {
                found.append(hit.lowerBound.utf16Offset(in: folded)..<hit.upperBound.utf16Offset(in: folded))
                from = hit.upperBound
            }
        }
        var merged: [Range<Int>] = []
        for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.map { String.Index(utf16Offset: $0.lowerBound, in: text)..<String.Index(utf16Offset: $0.upperBound, in: text) }
    }

    /// The text with every match on the find highlight, dark text on it in either appearance.
    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString(text)
        for range in ranges(of: terms, in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = Color(nsColor: .findHighlightColor)
            result[lower..<upper].foregroundColor = .black
        }
        return result
    }

    static func fold(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar {
            case "\u{064A}", "\u{0649}": return "\u{06CC}"
            case "\u{0643}": return "\u{06A9}"
            default: return scalar
            }
        }))
    }

    /// Marks the terms in the reader's document, in the app's own script world (the message's own
    /// script stays off), and brings the first mark into view when it is below the fold. Called as
    /// a function body with `terms`; returns how many were marked.
    static let bodyScript = """
    const fold = s => s.replace(/[\\u064A\\u0649]/g, '\\u06CC').replace(/\\u0643/g, '\\u06A9').toLowerCase();
    const body = document.body;
    const want = terms.map(fold).filter(t => t.length > 0);
    if (!body || want.length === 0) { return 0; }
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, {
      acceptNode: n => (n.parentElement && /^(SCRIPT|STYLE|TITLE|MARK)$/.test(n.parentElement.tagName))
        ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
    });
    const nodes = [];
    while (walker.nextNode() && nodes.length < 20000) { nodes.push(walker.currentNode); }
    let count = 0;
    for (const node of nodes) {
      const text = node.nodeValue, folded = fold(text);
      if (folded.length !== text.length) { continue; }
      const hits = [];
      for (const t of want) {
        for (let i = folded.indexOf(t); i >= 0; i = folded.indexOf(t, i + t.length)) { hits.push([i, i + t.length]); }
      }
      if (hits.length === 0) { continue; }
      hits.sort((a, b) => a[0] - b[0]);
      const merged = [];
      for (const h of hits) {
        const last = merged[merged.length - 1];
        if (last && h[0] <= last[1]) { last[1] = Math.max(last[1], h[1]); } else { merged.push(h.slice()); }
      }
      const fragment = document.createDocumentFragment();
      let at = 0;
      for (const [start, end] of merged) {
        if (start > at) { fragment.appendChild(document.createTextNode(text.slice(at, start))); }
        const mark = document.createElement('mark');
        mark.textContent = text.slice(start, end);
        mark.style.setProperty('background', '#ffe45c', 'important');
        mark.style.setProperty('color', '#000', 'important');
        mark.style.setProperty('border-radius', '2px');
        fragment.appendChild(mark);
        at = end;
        count++;
      }
      if (at < text.length) { fragment.appendChild(document.createTextNode(text.slice(at))); }
      node.parentNode.replaceChild(fragment, node);
    }
    const first = document.querySelector('mark');
    if (first) { first.scrollIntoView({ block: 'nearest' }); }
    return count;
    """
}
