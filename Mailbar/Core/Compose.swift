import Foundation

/// A message being written (M12 to M14, M23 to M25). One at a time. Nothing of it is ever on the
/// Mac's disk: it lives in memory, and (since M25, Outlook's behaviour) a copy is kept in the
/// server's Drafts folder a few seconds after typing stops, so it can be reopened from Drafts.
/// Attached files stay in memory only until the message is sent.
struct Draft: Equatable, Identifiable {
    enum Kind: Equatable {
        case reply
        case replyAll
        case forward
        case new
    }

    let id = UUID()
    let kind: Kind
    let accountID: UUID
    /// The message replied to or forwarded. Nil for a new message.
    let originalID: String?
    /// Shown for replies and forwards, where the server sets the real subject ("RE:", "FW:").
    let originalSubject: String
    var to: String
    var cc: String
    var subject: String
    var body: String
    var isSending = false
    var error: String?

    // MARK: M23 to M25

    /// Forward as attachment and Redirect are forwards of their own (they mark the original
    /// forwarded); Resend is a new message filled from a sent one.
    enum Style: Equatable, Sendable {
        case standard
        /// The original rides along as an attached message (`ItemAttachment`).
        case asAttachment
        /// The original's subject, body and files, sent on with no quote header and no "FW:".
        case redirect
    }

    var style: Style = .standard
    var bcc = ""
    /// An alias or a mailbox the account may send as or on behalf of. Empty: the account.
    var from = ""
    var options = MessageOptions()
    /// Files to send, bytes in memory until the message goes.
    var attachments: [OutgoingFile] = []
    /// The copy in the server's Drafts folder, once saved.
    var serverID: String?
    /// HTML the server or the original supplies under the user's text: a reply's quote (from the
    /// saved draft), or the original message for Redirect and Resend. Never edited here.
    var baseHTML: String?
    /// Reply to selected text: only this is quoted, not the whole original.
    var quotedSelection: String?
    /// The formatted body from the rich editor, or nil while the text has no formatting.
    var bodyHTML: String?
    /// Signature and "always Cc or Bcc me" applied, once, when the composer first shows it.
    var prepared = false
    /// Files already on a reopened server copy, by name. They stay on it and go with it.
    var keptFiles: [String] = []
    /// What the server copy holds, so an unchanged draft is not saved again.
    var savedFingerprint: String?

    /// The body as it goes to the server: the user's part (formatted or plain) marked so a
    /// reopened draft can be split again, then any quoted selection, then the base HTML.
    var outgoingHTML: String {
        var mine = bodyHTML ?? ComposeHTML.html(from: body)
        if let quote = quotedSelection, !quote.isEmpty {
            mine += ComposeHTML.quote(quote)
        }
        let marked = #"<div class="\#(ComposeHTML.marker)">"# + mine + "</div>"
        guard let base = baseHTML, !base.isEmpty else { return marked }
        return ComposeHTML.inserting(marked, intoBodyOf: base)
    }

    /// Everything a save writes, to tell whether the server copy is current.
    var fingerprint: String {
        [to, cc, bcc, subject, from, outgoingHTML, options.importance.rawValue,
         options.sensitivity.rawValue, "\(options.readReceipt)", "\(options.deliveryReceipt)"].joined(separator: "\u{1}")
    }

    /// Stands in for a draft that has just gone, so a binding read during a close has a value.
    static let placeholder = Draft(kind: .new, accountID: UUID(), originalID: nil, originalSubject: "",
                                   to: "", cc: "", subject: "", body: "")

    var allRecipients: [String] { Recipients.parse(to) + Recipients.parse(cc) + Recipients.parse(bcc) }

    /// Total bytes attached.
    var attachedBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }

    var title: String {
        switch (kind, style) {
        case (.forward, .asAttachment): return "Forward as Attachment"
        case (.forward, .redirect): return "Redirect"
        case (.reply, _): return quotedSelection == nil ? "Reply" : "Reply to Selection"
        case (.replyAll, _): return quotedSelection == nil ? "Reply All" : "Reply All to Selection"
        case (.forward, _): return "Forward"
        case (.new, _): return "New Message"
        }
    }

    /// What the subject will be. Replies and forwards follow Outlook's own prefixes, which the
    /// server applies; this is only the preview of it.
    var subjectPreview: String {
        switch kind {
        case .reply, .replyAll: return "RE: \(originalSubject)"
        case .forward: return style == .redirect ? originalSubject : "FW: \(originalSubject)"
        case .new: return subject
        }
    }

    var hasContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (kind == .new && !subject.trimmingCharacters(in: .whitespaces).isEmpty)
            || !attachments.isEmpty
    }

    /// The first thing stopping Send, or nil.
    var sendProblem: String? {
        let all = allRecipients
        if all.isEmpty { return "Add a recipient." }
        if let bad = all.first(where: { !Recipients.isValid($0) }) {
            return "\u{201C}\(bad)\u{201D} is not an email address. Check Names (⌘K) looks it up."
        }
        if !from.isEmpty, !Recipients.isValid(from) { return "The From address is not an email address." }
        if kind == .new && subject.trimmingCharacters(in: .whitespaces).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
            && (baseHTML ?? "").isEmpty {
            return "Write something first."
        }
        if attachedBytes > OutgoingFile.maxTotal { return "The files come to more than 25 MB." }
        return nil
    }
}

/// Addresses typed into To and Cc.
enum Recipients {
    /// Splits on commas, semicolons and newlines, and reduces `Name <addr>` to the address.
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { ",;\n".contains($0) })
            .map { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                    return String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }

    static func isValid(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !address.contains(where: { $0.isWhitespace || "<>\"".contains($0) }) else { return false }
        return true
    }

    static func join(_ addresses: [String]) -> String {
        addresses.joined(separator: ", ")
    }

    /// Reply all: the sender plus everyone else on the message, minus this account, each once.
    static func replyAll(from: String, to: [String], cc: [String], me: String) -> (to: [String], cc: [String]) {
        var seen: Set<String> = [me.lowercased()]
        func keep(_ list: [String]) -> [String] {
            list.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        let toList = keep([from] + to)
        let ccList = keep(cc)
        return (toList, ccList)
    }

    /// The part of the field being typed: whatever follows the last separator.
    static func currentToken(in text: String) -> String {
        let tail = text.split(omittingEmptySubsequences: false, whereSeparator: { ",;\n".contains($0) }).last ?? ""
        return tail.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces the token being typed with a chosen address, ready for the next one.
    static func completing(_ text: String, with address: String) -> String {
        if let cut = text.lastIndex(where: { ",;\n".contains($0) }) {
            return String(text[...cut]) + " " + address + ", "
        }
        return address + ", "
    }

    /// The group's address swapped, where it stands, for its members' addresses. Anyone
    /// already in the field (or in `elsewhere`, the other field) is not added twice.
    static func expanding(_ text: String, group: String, into members: [String], elsewhere: String = "") -> String {
        let key = group.lowercased()
        let parts = parse(text)
        var seen = Set((parts.filter { $0.lowercased() != key } + parse(elsewhere)).map { $0.lowercased() })
        let added = members.filter { seen.insert($0.lowercased()).inserted }
        let result = parts.flatMap { $0.lowercased() == key ? added : [$0] }
        return result.isEmpty ? "" : join(result) + ", "
    }

    /// These addresses after what is already in the field, each once.
    static func appending(_ addresses: [String], to text: String, elsewhere: String = "") -> String {
        let parts = parse(text)
        var seen = Set((parts + parse(elsewhere)).map { $0.lowercased() })
        let result = parts + addresses.filter { seen.insert($0.lowercased()).inserted }
        return result.isEmpty ? "" : join(result) + ", "
    }
}

/// The written text as the HTML body Exchange receives.
///
/// Plain text in, so there is nothing to format; HTML out, because that is the only way to tell
/// the recipient's mail client which way a Persian paragraph runs. Each paragraph gets the
/// direction of its own first strong character, as the composer shows it.
enum ComposeHTML {
    static func html(from text: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let body = paragraphs.map { line -> String in
            let escaped = SOAP.escape(line)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return "<div><br></div>" }
            if TextDirection.firstStrong(in: line) == .rightToLeft {
                return #"<div dir="rtl" style="text-align:right">"# + escaped + "</div>"
            }
            return "<div>" + escaped + "</div>"
        }.joined()
        return #"<div style="font-family:Calibri,Arial,sans-serif;font-size:11pt">"# + body + "</div>"
    }

    /// The class on the user's own part of a saved draft's body, so reopening the draft puts only
    /// that part back in the editor and keeps the quote under it as it was.
    static let marker = "mailbar-compose"

    /// Selected text from the original, quoted as Outlook quotes: a rule on the left.
    static func quote(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            let escaped = SOAP.escape(line)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return "<div><br></div>" }
            return TextDirection.firstStrong(in: line) == .rightToLeft
                ? #"<div dir="rtl" style="text-align:right">"# + escaped + "</div>" : "<div>" + escaped + "</div>"
        }.joined()
        return #"<blockquote style="margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex">"# + lines + "</blockquote>"
    }

    /// `html` put first inside `base`'s body element (after `<body ...>`), or before it all when
    /// `base` has no body element.
    static func inserting(_ html: String, intoBodyOf base: String) -> String {
        if let open = base.range(of: "<body", options: .caseInsensitive),
           let close = base[open.upperBound...].firstIndex(of: ">") {
            let at = base.index(after: close)
            return String(base[..<at]) + html + String(base[at...])
        }
        return html + base
    }

    /// A saved body split into the user's part (inside the marker) and everything else. Nil when
    /// the marker is not there (a draft written elsewhere): then the whole body is the user's.
    static func split(_ html: String) -> (mine: String, base: String)? {
        guard let start = html.range(of: #"<div class="\#(marker)""#) ??
                html.range(of: #"<div class=\#(marker)"#) else { return nil }
        var depth = 0
        var index = start.lowerBound
        while index < html.endIndex {
            let rest = html[index...]
            if rest.hasPrefix("<div") || rest.hasPrefix("<DIV") {
                depth += 1
            } else if rest.hasPrefix("</div") || rest.hasPrefix("</DIV") {
                depth -= 1
                if depth == 0, let end = rest.firstIndex(of: ">") {
                    let after = html.index(after: end)
                    let mine = String(html[start.lowerBound..<after])
                    let base = String(html[..<start.lowerBound]) + String(html[after...])
                    return (mine, base)
                }
            }
            index = html.index(after: index)
        }
        return nil
    }
}
