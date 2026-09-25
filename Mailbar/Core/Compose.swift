import Foundation

/// A message being written (M12 to M14). One at a time, in memory only: it survives the popover
/// closing, and goes when it is sent, discarded, or Mailbar quits. Never written to disk, never
/// saved to the server's Drafts folder.
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

    var title: String {
        switch kind {
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .new: return "New Message"
        }
    }

    /// What the subject will be. Replies and forwards follow Outlook's own prefixes, which the
    /// server applies; this is only the preview of it.
    var subjectPreview: String {
        switch kind {
        case .reply, .replyAll: return "RE: \(originalSubject)"
        case .forward: return "FW: \(originalSubject)"
        case .new: return subject
        }
    }

    var hasContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (kind == .new && !subject.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The first thing stopping Send, or nil.
    var sendProblem: String? {
        let toList = Recipients.parse(to)
        let ccList = Recipients.parse(cc)
        if toList.isEmpty && ccList.isEmpty { return "Add a recipient." }
        if let bad = (toList + ccList).first(where: { !Recipients.isValid($0) }) {
            return "\u{201C}\(bad)\u{201D} is not an email address."
        }
        if kind == .new && subject.trimmingCharacters(in: .whitespaces).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write something first."
        }
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
}
