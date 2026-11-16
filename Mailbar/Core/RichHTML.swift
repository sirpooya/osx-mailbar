import AppKit

/// The rich editor's text as the HTML body Exchange receives (M25), and back.
///
/// Only what the formatting bar makes is carried: bold, italic, underline, links, and lists.
/// Lists are typed markers ("• " and "1. " at a paragraph's start), so they also survive plain
/// text and look the same in the editor as in the sent mail. Every paragraph keeps its own
/// direction, the rule `ComposeHTML` follows: a Persian one goes out `dir="rtl"`.
enum RichHTML {
    static let bullet = "\u{2022} "

    enum ListKind: Equatable { case bulleted, numbered }

    /// The list a paragraph belongs to, and the text after its marker.
    static func listItem(_ line: String) -> (ListKind, Int)? {
        if line.hasPrefix(bullet) { return (.bulleted, bullet.count) }
        var digits = 0
        for character in line {
            if character.isASCII, character.isNumber { digits += 1 } else { break }
        }
        guard digits > 0, digits < 4 else { return nil }
        let rest = line.dropFirst(digits)
        guard rest.hasPrefix(". ") else { return nil }
        return (.numbered, digits + 2)
    }

    /// Whether the text needs the rich converter at all: any trait, underline, link or list.
    static func hasFormatting(_ text: NSAttributedString) -> Bool {
        var found = false
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole) { attributes, _, stop in
            if attributes[.link] != nil || (attributes[.underlineStyle] as? Int ?? 0) != 0
                || traits(attributes[.font] as? NSFont).bold || traits(attributes[.font] as? NSFont).italic {
                found = true
                stop.pointee = true
            }
        }
        if found { return true }
        return text.string.components(separatedBy: "\n").contains { listItem($0) != nil }
    }

    static func traits(_ font: NSFont?) -> (bold: Bool, italic: Bool) {
        guard let font else { return (false, false) }
        let symbolic = font.fontDescriptor.symbolicTraits
        return (symbolic.contains(.bold), symbolic.contains(.italic))
    }

    static func html(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var output = ""
        var openList: ListKind?
        var location = 0
        func closeList() {
            if let list = openList { output += list == .bulleted ? "</ul>" : "</ol>" }
            openList = nil
        }
        while location <= string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = lineRange
            // Drop the paragraph's newline.
            if contentRange.length > 0, string.character(at: NSMaxRange(contentRange) - 1) == 10 {
                contentRange.length -= 1
            }
            let line = string.substring(with: contentRange)
            let rtl = TextDirection.firstStrong(in: line) == .rightToLeft
            let dir = rtl ? #" dir="rtl" style="text-align:right""# : ""
            if let (kind, markerLength) = listItem(line) {
                if openList != kind {
                    closeList()
                    output += kind == .bulleted ? "<ul\(dir)>" : "<ol\(dir)>"
                    openList = kind
                }
                let inner = NSRange(location: contentRange.location + markerLength,
                                    length: max(0, contentRange.length - markerLength))
                output += "<li>" + runs(text, in: inner) + "</li>"
            } else {
                closeList()
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    output += "<div><br></div>"
                } else {
                    output += "<div\(dir)>" + runs(text, in: contentRange) + "</div>"
                }
            }
            if NSMaxRange(lineRange) >= string.length { break }
            location = NSMaxRange(lineRange)
        }
        closeList()
        return #"<div style="font-family:Calibri,Arial,sans-serif;font-size:11pt">"# + output + "</div>"
    }

    /// One paragraph's runs, each wrapped in the tags its attributes ask for.
    private static func runs(_ text: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var html = ""
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            var piece = SOAP.escape(text.attributedSubstring(from: runRange).string)
            let (bold, italic) = traits(attributes[.font] as? NSFont)
            if (attributes[.underlineStyle] as? Int ?? 0) != 0, attributes[.link] == nil { piece = "<u>\(piece)</u>" }
            if italic { piece = "<i>\(piece)</i>" }
            if bold { piece = "<b>\(piece)</b>" }
            if let link = attributes[.link] {
                let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !target.isEmpty { piece = #"<a href="\#(SOAP.escape(target))">"# + piece + "</a>" }
            }
            html += piece
        }
        return html
    }

    /// HTML (a reopened draft or a template) as editor text: the formatting the bar knows,
    /// in the editor's own font, lists turned back into typed markers.
    @MainActor
    static func attributed(fromHTML html: String, baseFont: NSFont = .systemFont(ofSize: 13)) -> NSAttributedString {
        let marked = html
            .replacingOccurrences(of: "<li>", with: "<li>\u{E000}", options: .caseInsensitive)
        guard let data = marked.data(using: .utf8),
              let parsed = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else {
            return NSAttributedString(string: html, attributes: [.font: baseFont])
        }
        let whole = NSRange(location: 0, length: parsed.length)
        let manager = NSFontManager.shared
        parsed.enumerateAttribute(.font, in: whole) { value, range, _ in
            let (bold, italic) = traits(value as? NSFont)
            var font = baseFont
            if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            parsed.addAttribute(.font, value: font, range: range)
        }
        parsed.removeAttribute(.foregroundColor, range: whole)
        parsed.removeAttribute(.backgroundColor, range: whole)
        parsed.removeAttribute(.paragraphStyle, range: whole)
        // AppKit writes list items as "\t•\t" or "\t1.\t" before the text; make them ours.
        var string = parsed.string as NSString
        var search = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: "\u{E000}", options: [], range: search)
            guard found.location != NSNotFound else { break }
            let line = string.lineRange(for: found)
            let prefix = NSRange(location: line.location, length: NSMaxRange(found) - line.location)
            let marker = string.substring(with: prefix)
            let numbered = marker.contains(where: { $0.isNumber })
            let number = marker.filter(\.isNumber)
            parsed.replaceCharacters(in: prefix, with: numbered ? "\(number.isEmpty ? "1" : number). " : bullet)
            string = parsed.string as NSString
            search = NSRange(location: line.location, length: string.length - line.location)
        }
        // AppKit's HTML import ends with a newline that was not typed.
        while parsed.string.hasSuffix("\n") {
            parsed.deleteCharacters(in: NSRange(location: parsed.length - 1, length: 1))
        }
        return parsed
    }
}
