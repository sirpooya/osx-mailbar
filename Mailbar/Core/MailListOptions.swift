import Foundation

/// The list's quick filters, after Outlook's "Filter By" (2026-11-16, the user's pick). Asked of
/// the server, so a filter reaches past the 50 newest; a search's results are filtered here.
enum MailFilter: String, CaseIterable, Sendable, Identifiable {
    case unread
    case flagged
    case attachments
    case toMe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .flagged: "Flagged"
        case .attachments: "Has Attachments"
        case .toMe: "To Me"
        }
    }

    var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .flagged: "flag"
        case .attachments: "paperclip"
        case .toMe: "person"
        }
    }

    /// Whether the filter means anything in this folder: Flagged already is the flagged mail,
    /// and everything in Sent Items was sent by me, not to me.
    func applies(to folder: MailFolder) -> Bool {
        switch self {
        case .flagged: folder != .flagged
        case .toMe: folder != .sent
        case .unread, .attachments: true
        }
    }

    func matches(_ message: MailMessage) -> Bool {
        switch self {
        case .unread: !message.isRead
        case .flagged: message.isFlagged
        case .attachments: message.hasAttachments
        case .toMe: message.isToMe
        }
    }

    /// The EWS condition. "To me" is PidTagMessageToMe (0x0057), which Exchange sets when the
    /// mailbox owner is on the To line; every version has it.
    var condition: String {
        switch self {
        case .unread:
            #"<t:IsEqualTo><t:FieldURI FieldURI="message:IsRead"/><t:FieldURIOrConstant><t:Constant Value="false"/></t:FieldURIOrConstant></t:IsEqualTo>"#
        case .flagged:
            SOAP.flaggedCondition
        case .attachments:
            #"<t:IsEqualTo><t:FieldURI FieldURI="item:HasAttachments"/><t:FieldURIOrConstant><t:Constant Value="true"/></t:FieldURIOrConstant></t:IsEqualTo>"#
        case .toMe:
            #"<t:IsEqualTo><t:ExtendedFieldURI PropertyTag="0x0057" PropertyType="Boolean"/><t:FieldURIOrConstant><t:Constant Value="true"/></t:FieldURIOrConstant></t:IsEqualTo>"#
        }
    }
}

/// The list's order, after Outlook's "Sort By". Every order but Date falls back to newest first.
enum MailSort: String, CaseIterable, Sendable, Identifiable {
    case date
    case sender
    case subject
    case size
    case importance

    var id: String { rawValue }

    /// Sent Items sorts by whom it went to where other folders sort by who sent it.
    func title(in folder: MailFolder) -> String {
        switch self {
        case .date: "Date"
        case .sender: folder.showsRecipients ? "To" : "From"
        case .subject: "Subject"
        case .size: "Size"
        case .importance: "Importance"
        }
    }

    /// The `FieldOrder`s, most significant first. Sender and subject sort on their MAPI columns:
    /// PidTagSenderName (0x0C1A), PidTagDisplayTo (0x0E04) and PidTagNormalizedSubject (0x0E1D),
    /// the subject without its "RE:", which is how Outlook sorts it.
    func fieldOrders(in folder: MailFolder) -> String {
        let newest = #"<t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder>"#
        let first: String
        switch self {
        case .date:
            return newest
        case .sender:
            let tag = folder.showsRecipients ? "0x0E04" : "0x0C1A"
            first = #"<t:FieldOrder Order="Ascending"><t:ExtendedFieldURI PropertyTag="\#(tag)" PropertyType="String"/></t:FieldOrder>"#
        case .subject:
            first = #"<t:FieldOrder Order="Ascending"><t:ExtendedFieldURI PropertyTag="0x0E1D" PropertyType="String"/></t:FieldOrder>"#
        case .size:
            first = #"<t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:Size"/></t:FieldOrder>"#
        case .importance:
            first = #"<t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:Importance"/></t:FieldOrder>"#
        }
        return first + newest
    }

    /// The same order applied here, for search results, which the server returns newest first.
    func sorted(_ messages: [MailMessage], in folder: MailFolder) -> [MailMessage] {
        guard self != .date else { return messages }
        return messages.sorted { a, b in
            switch self {
            case .date:
                break
            case .sender:
                let left = folder.showsRecipients ? a.displayTo : a.senderName
                let right = folder.showsRecipients ? b.displayTo : b.senderName
                let order = left.localizedStandardCompare(right)
                if order != .orderedSame { return order == .orderedAscending }
            case .subject:
                let order = Self.normalized(a.subject).localizedStandardCompare(Self.normalized(b.subject))
                if order != .orderedSame { return order == .orderedAscending }
            case .size:
                if a.size != b.size { return a.size > b.size }
            case .importance:
                if a.importance != b.importance { return a.importance.rank > b.importance.rank }
            }
            return a.received > b.received
        }
    }

    /// "RE: FW: Budget" sorts as "Budget".
    static func normalized(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 3,
              text[..<colon].allSatisfy(\.isLetter) {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// The filters and order the list shows. The default (no filter, newest first) is the plain
/// folder list; anything else is its own request.
struct MailListOptions: Equatable, Sendable {
    var filters: Set<MailFilter> = []
    var sort: MailSort = .date

    func filters(in folder: MailFolder) -> [MailFilter] {
        MailFilter.allCases.filter { filters.contains($0) && $0.applies(to: folder) }
    }

    func isDefault(in folder: MailFolder) -> Bool {
        filters(in: folder).isEmpty && sort == .date
    }

    /// Filtering and ordering done here rather than by the server: search results.
    func apply(to messages: [MailMessage], in folder: MailFolder) -> [MailMessage] {
        let active = filters(in: folder)
        let kept = messages.filter { message in active.allSatisfy { $0.matches(message) } }
        return sort.sorted(kept, in: folder)
    }

    /// "Unread and Has Attachments", for the strip under the header and the empty state.
    func summary(in folder: MailFolder) -> String {
        let names = filters(in: folder).map(\.title)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

/// Outlook's date groups over a list sorted newest first: Today, Yesterday, the day names of
/// this week, Last Week, Two and Three Weeks Ago, Last Month, Older (the user's pick, 2026-11-16).
enum MailDateGroup {
    struct Section: Identifiable {
        let title: String
        var messages: [MailMessage]
        var id: String { title }
    }

    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if date >= today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday {
            return "Yesterday"
        }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        if date >= week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        for (weeks, name) in [(1, "Last Week"), (2, "Two Weeks Ago"), (3, "Three Weeks Ago")] {
            if let start = calendar.date(byAdding: .weekOfYear, value: -weeks, to: week), date >= start {
                return name
            }
        }
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
        if let last = calendar.date(byAdding: .month, value: -1, to: month), date >= last {
            return "Last Month"
        }
        return "Older"
    }

    /// Consecutive runs with the same title, so the list's order is kept as it is.
    static func sections(_ messages: [MailMessage], now: Date = Date(),
                         calendar: Calendar = .current) -> [Section] {
        var sections: [Section] = []
        for message in messages {
            let title = title(for: message.received, now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1].messages.append(message)
            } else if let index = sections.firstIndex(where: { $0.title == title }) {
                // Out of date order (a sort other than Date never groups, so this is a clock
                // oddity): keep one section per title.
                sections[index].messages.append(message)
            } else {
                sections.append(Section(title: title, messages: [message]))
            }
        }
        return sections
    }
}
