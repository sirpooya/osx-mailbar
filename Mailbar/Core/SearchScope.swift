import Foundation
import Observation

// Search, after Outlook (2026-11-16): where it looks (this folder, every folder, the Online
// Archive), extra criteria, typed keywords, saved searches, and Events and People sections.

/// Where a search looks, picked in the menu at the search field's left.
enum SearchScope: String, Codable, Sendable, CaseIterable {
    /// The folder the mail tab shows (M8's behaviour).
    case thisFolder
    /// Every mail folder of the mailbox (Deleted Items only when asked for).
    case allFolders
    /// The Online Archive mailbox (`archivemsgfolderroot`), when the mailbox has one.
    case onlineArchive

    var title: String {
        switch self {
        case .thisFolder: "This Folder"
        case .allFolders: "All Folders"
        case .onlineArchive: "Online Archive"
        }
    }
}

/// The Options popover's criteria. Configuration a saved search keeps; never mail.
struct SearchCriteria: Codable, Equatable, Sendable {
    var from = ""
    var to = ""
    var subject = ""
    var receivedAfter: Date?
    var receivedBefore: Date?
    var hasAttachments = false

    enum Field: String, CaseIterable, Sendable {
        case from, to, subject, after, before, attachments
    }

    var isEmpty: Bool { fields.isEmpty }

    /// The criteria that are set, in the popover's order.
    var fields: [Field] {
        Field.allCases.filter { field in
            switch field {
            case .from: !from.trimmed.isEmpty
            case .to: !to.trimmed.isEmpty
            case .subject: !subject.trimmed.isEmpty
            case .after: receivedAfter != nil
            case .before: receivedBefore != nil
            case .attachments: hasAttachments
            }
        }
    }

    /// The chip under the field for one criterion: "From: sara", "After 1 Nov".
    func label(_ field: Field) -> String {
        switch field {
        case .from: "From: \(from.trimmed)"
        case .to: "To: \(to.trimmed)"
        case .subject: "Subject: \(subject.trimmed)"
        case .after: "After \(receivedAfter.map(Self.chipDate) ?? "")"
        case .before: "Before \(receivedBefore.map(Self.chipDate) ?? "")"
        case .attachments: "Has attachments"
        }
    }

    mutating func clear(_ field: Field) {
        switch field {
        case .from: from = ""
        case .to: to = ""
        case .subject: subject = ""
        case .after: receivedAfter = nil
        case .before: receivedBefore = nil
        case .attachments: hasAttachments = false
        }
    }

    /// The criteria as AQS, for `QueryString` on Exchange 2013 and later.
    var aqs: String {
        var parts: [String] = []
        if !from.trimmed.isEmpty { parts.append("from:" + SearchQuery.quoted(from.trimmed)) }
        if !to.trimmed.isEmpty { parts.append("to:" + SearchQuery.quoted(to.trimmed)) }
        if !subject.trimmed.isEmpty { parts.append("subject:" + SearchQuery.quoted(subject.trimmed)) }
        if let receivedAfter { parts.append("received:>=" + SearchQuery.aqsDate(receivedAfter)) }
        if let receivedBefore { parts.append("received:<=" + SearchQuery.aqsDate(receivedBefore)) }
        if hasAttachments { parts.append("hasattachment:true") }
        return parts.joined(separator: " ")
    }

    private static func chipDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// What a search asks for: the typed text (plain words, or AQS keywords) plus the criteria.
struct SearchQuery: Equatable, Sendable {
    var text: String
    var criteria = SearchCriteria()

    var trimmedText: String { text.trimmed }

    /// Something to search for: two typed characters, or any criterion.
    var isSearchable: Bool { trimmedText.count >= 2 || !criteria.isEmpty }

    /// Exchange 2013 and later: what is typed goes to the server's index as typed (AQS
    /// included), the criteria appended as AQS. Juxtaposed terms are ANDed by the server.
    var queryString: String {
        [trimmedText, criteria.aqs].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The typed keywords read here, for older servers, with the criteria merged in.
    func parsed(now: Date = Date(), calendar: Calendar = .current) -> ParsedSearch {
        var parsed = ParsedSearch.parse(text, now: now, calendar: calendar)
        if !criteria.from.trimmed.isEmpty { parsed.from.append(criteria.from.trimmed) }
        if !criteria.to.trimmed.isEmpty { parsed.to.append(criteria.to.trimmed) }
        if !criteria.subject.trimmed.isEmpty { parsed.subject.append(criteria.subject.trimmed) }
        if criteria.hasAttachments { parsed.hasAttachments = true }
        if let after = criteria.receivedAfter {
            let day = calendar.startOfDay(for: after)
            parsed.after = parsed.after.map { max($0, day) } ?? day
        }
        if let before = criteria.receivedBefore {
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: before)) ?? before
            parsed.before = parsed.before.map { min($0, end) } ?? end
        }
        return parsed
    }

    /// The plain words, without any keyword: what the Events and People sections look for.
    var freeText: String { ParsedSearch.parse(text).words.joined(separator: " ") }

    static func quoted(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\"", with: "")
        return clean.contains(where: \.isWhitespace) ? "\"\(clean)\"" : clean
    }

    /// AQS dates are month/day/year (Microsoft's examples: `received:>11/30/2013`).
    static func aqsDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M/d/yyyy"
        return formatter.string(from: date)
    }

    /// The keyword hint under the empty field.
    static let keywordHint = "from:  to:  subject:  hasattachment:true  received:yesterday"
}

/// Typed AQS, read the way an older server (no `QueryString`) needs it: the common keywords
/// become restriction parts, everything else is plain text matched in subject or body.
struct ParsedSearch: Equatable, Sendable {
    /// Plain words and quoted phrases, in order, quotes removed.
    var words: [String] = []
    var from: [String] = []
    var to: [String] = []
    var subject: [String] = []
    var hasAttachments: Bool?
    /// Received at or after this moment.
    var after: Date?
    /// Received before this moment.
    var before: Date?

    var isEmpty: Bool {
        words.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty && hasAttachments == nil
            && after == nil && before == nil
    }

    /// Keywords whose value is text worth marking in a row; the others ("received:",
    /// "hasattachment:") have values nobody expects to see marked.
    static let textKeywords: Set<String> = ["from", "to", "cc", "bcc", "subject", "body", "attachment",
                                            "participants", "category"]
    /// Every keyword Exchange's AQS knows (Microsoft's list), plus the spellings Outlook takes.
    static let keywords: Set<String> = textKeywords.union(["hasattachment", "hasattachments", "received", "sent",
                                                           "isread", "isflagged", "kind", "importance", "size"])
    static let operators: Set<String> = ["and", "or", "not"]

    /// One piece of typed text: `key` set for "key:value".
    struct Token: Equatable {
        var key: String?
        var value: String
    }

    /// Splits on white space outside quotes; `from:"Sara Rahimi"` is one token.
    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        func flush() {
            let raw = current
            current = ""
            guard !raw.isEmpty else { return }
            if let colon = raw.firstIndex(of: ":"), !raw.hasPrefix("\"") {
                let key = String(raw[..<colon]).lowercased()
                if keywords.contains(key) {
                    let value = String(raw[raw.index(after: colon)...]).replacingOccurrences(of: "\"", with: "")
                    tokens.append(Token(key: key, value: value))
                    return
                }
            }
            tokens.append(Token(key: nil, value: raw.replacingOccurrences(of: "\"", with: "")))
        }
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character.isWhitespace, !inQuotes {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedSearch {
        var parsed = ParsedSearch()
        for token in tokens(in: text) {
            let value = token.value.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard let key = token.key else {
                if !value.isEmpty, !operators.contains(value.lowercased()) { parsed.words.append(value) }
                continue
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "from": parsed.from.append(value)
            case "to": parsed.to.append(value)
            case "subject": parsed.subject.append(value)
            case "hasattachment", "hasattachments":
                parsed.hasAttachments = ["true", "yes", "1"].contains(value.lowercased())
            case "received":
                if let range = dateRange(value, now: now, calendar: calendar) {
                    if let lower = range.lower { parsed.after = parsed.after.map { max($0, lower) } ?? lower }
                    if let upper = range.upper { parsed.before = parsed.before.map { min($0, upper) } ?? upper }
                }
            default:
                // A keyword an older server cannot restrict on: its value is still worth finding.
                if textKeywords.contains(key) { parsed.words.append(value) }
            }
        }
        return parsed
    }

    /// "yesterday", ">=11/1/2026", "<2026-11-01", "11/1/2026..today": the moments a received
    /// date may fall between, lower inclusive, upper exclusive.
    static func dateRange(_ value: String, now: Date, calendar: Calendar) -> (lower: Date?, upper: Date?)? {
        if let dots = value.range(of: "..") {
            let first = day(String(value[..<dots.lowerBound]), now: now, calendar: calendar)
            let last = day(String(value[dots.upperBound...]), now: now, calendar: calendar)
            guard first != nil || last != nil else { return nil }
            return (first, last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) })
        }
        for op in [">=", "<=", ">", "<"] where value.hasPrefix(op) {
            guard let date = day(String(value.dropFirst(op.count)), now: now, calendar: calendar) else { return nil }
            let next = calendar.date(byAdding: .day, value: 1, to: date)
            switch op {
            case ">=": return (date, nil)
            case ">": return (next, nil)
            case "<=": return (nil, next)
            default: return (nil, date)
            }
        }
        guard let date = day(value, now: now, calendar: calendar) else { return nil }
        return (date, calendar.date(byAdding: .day, value: 1, to: date))
    }

    /// The start of the day a date word or a written date names.
    static func day(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let word = text.trimmed.lowercased()
        let today = calendar.startOfDay(for: now)
        switch word {
        case "today": return today
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        default: break
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        for format in ["M/d/yyyy", "yyyy-MM-dd", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: word) { return calendar.startOfDay(for: date) }
        }
        formatter.dateFormat = "M/d"
        if let date = formatter.date(from: word) {
            var parts = calendar.dateComponents([.month, .day], from: date)
            parts.year = calendar.component(.year, from: now)
            return calendar.date(from: parts).map(calendar.startOfDay)
        }
        return nil
    }
}

/// A search kept by name, to run again from the scope menu: what was typed, where it looked,
/// and the criteria. Configuration in UserDefaults (`Keys.savedSearches`); never results.
struct SavedSearch: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var query: String
    var scope: SearchScope
    var includeDeleted = false
    var criteria = SearchCriteria()

    static func load(_ defaults: UserDefaults = .standard) -> [SavedSearch] {
        guard let data = defaults.data(forKey: Keys.savedSearches) else { return [] }
        return (try? JSONDecoder().decode([SavedSearch].self, from: data)) ?? []
    }

    static func save(_ list: [SavedSearch], to defaults: UserDefaults = .standard) {
        if list.isEmpty {
            defaults.removeObject(forKey: Keys.savedSearches)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.savedSearches)
        }
    }
}

/// A folder a search looks in.
enum SearchParent: Hashable, Sendable {
    case distinguished(String)
    case folder(String)

    var xml: String {
        switch self {
        case .distinguished(let id): #"<t:DistinguishedFolderId Id="\#(SOAP.escape(id))"/>"#
        case .folder(let id): #"<t:FolderId Id="\#(SOAP.escape(id))"/>"#
        }
    }

    var id: String {
        switch self {
        case .distinguished(let id), .folder(let id): id
        }
    }
}

/// The search's own state beside the store's results (`MailStore.searchExtras`): the scope,
/// the criteria, the saved searches, and the Events and People sections. In memory, except the
/// saved searches, which are configuration.
@MainActor
@Observable
final class SearchState {
    var scope: SearchScope = .thisFolder
    /// All Folders only: Deleted Items too. Off by default, as in Outlook.
    var includeDeleted = false
    var criteria = SearchCriteria()
    var saved: [SavedSearch] = SavedSearch.load()

    /// Up to five events whose title or place matches, nearest first.
    var events: [CalendarEvent] = []
    /// Up to five people matching the typed words.
    var people: [PersonSuggestion] = []
    /// The folder each result is in, by item id, when the results come from several folders.
    var folderNames: [String: String] = [:]
    /// The results come from more than one folder, so rows name theirs.
    var spansFolders = false

    /// Whether each account has an Online Archive, asked once (`GetFolder` on
    /// `archivemsgfolderroot`) and remembered in memory.
    var onlineArchive: [UUID: Bool] = [:]
    @ObservationIgnored var probing: Set<UUID> = []
    /// Each account's Online Archive folders, read once, in memory.
    @ObservationIgnored var archiveFolders: [UUID: [MailboxFolder]] = [:]

    /// The scope that applies: Online Archive falls back to This Folder when there is none.
    func scope(for accountID: UUID?) -> SearchScope {
        if scope == .onlineArchive, let accountID, onlineArchive[accountID] != true { return .thisFolder }
        return scope
    }

    /// Back to a plain search when the field closes. The scope stays until the app quits.
    func reset() {
        criteria = SearchCriteria()
        clearResults()
    }

    func clearResults() {
        events = []
        people = []
        folderNames = [:]
        spansFolders = false
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
