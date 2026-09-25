import AppKit
import Foundation

/// An event being created or edited (M16). In memory only, like a mail draft.
struct EventDraft: Equatable, Identifiable {
    enum Repeat: String, CaseIterable, Identifiable {
        case never, daily, weekly, monthly, yearly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: return "Never"
            case .daily: return "Every day"
            case .weekly: return "Every week"
            case .monthly: return "Every month"
            case .yearly: return "Every year"
            }
        }
    }

    enum ShowAs: String, CaseIterable, Identifiable {
        case busy = "Busy", free = "Free", tentative = "Tentative", away = "OOF", elsewhere = "WorkingElsewhere"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .busy: return "Busy"
            case .free: return "Free"
            case .tentative: return "Tentative"
            case .away: return "Away"
            case .elsewhere: return "Working elsewhere"
            }
        }
    }

    /// Reminder choices in minutes, as OWA offers them; nil is None.
    static let reminderChoices: [Int?] = [nil, 0, 5, 15, 30, 60, 120, 1440]

    static func reminderLabel(_ minutes: Int?) -> String {
        switch minutes {
        case nil: return "None"
        case 0?: return "At start time"
        case 1440?: return "1 day before"
        case let m? where m >= 60: return "\(m / 60) hour\(m == 60 ? "" : "s") before"
        case let m?: return "\(m) minutes before"
        }
    }

    let formID = UUID()
    var id: String?
    let accountID: UUID
    var subject = ""
    var location = ""
    var rooms: [Room] = []
    var start: Date
    var end: Date
    var isAllDay = false
    var isPrivate = false
    var repeatRule: Repeat = .never
    var reminderMinutes: Int? = 15
    var showAs: ShowAs = .busy
    var notes = ""
    /// Typed addresses, comma separated, as in the mail composer.
    var attendees = ""
    /// Editing one occurrence of a series: the repeat rule is the series', not changeable here.
    var isOccurrence = false
    var isSaving = false
    var error: String?

    var isNew: Bool { id == nil }
    var attendeeList: [String] { Recipients.parse(attendees) }
    var subjectOrDefault: String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Event" : trimmed
    }

    /// The location as sent: what was typed, else the rooms booked, as OWA fills it.
    var locationText: String {
        let typed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? rooms.map(\.name).joined(separator: "; ") : typed
    }

    /// All-day events run from the first day's midnight to the midnight after the last day.
    var requestStart: Date { isAllDay ? Calendar.current.startOfDay(for: start) : start }
    var requestEnd: Date {
        guard isAllDay else { return end }
        let lastDay = Calendar.current.startOfDay(for: max(end, start))
        return Calendar.current.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
    }

    var problem: String? {
        if !isAllDay && end <= start { return "The event has to end after it starts." }
        if let bad = attendeeList.first(where: { !Recipients.isValid($0) }) {
            return "\u{201C}\(bad)\u{201D} is not an email address."
        }
        return nil
    }

    /// Sending invitations: shown on the Save button so the user knows it will mail people.
    var sendsInvitations: Bool { !attendeeList.isEmpty || !rooms.isEmpty }

    // MARK: - Starting points

    /// A new event at the start of the next half hour, an hour long; or at a slot double-clicked.
    static func new(accountID: UUID, at slot: Date? = nil) -> EventDraft {
        let calendar = Calendar.current
        let start: Date
        if let slot {
            start = slot
        } else {
            let now = Date()
            let minute = calendar.component(.minute, from: now)
            let rounded = calendar.date(byAdding: .minute, value: minute < 30 ? 30 - minute : 60 - minute, to: now) ?? now
            start = calendar.date(bySetting: .second, value: 0, of: rounded) ?? rounded
        }
        return EventDraft(accountID: accountID, start: start, end: start.addingTimeInterval(3600))
    }

    /// Editing what the detail panel loaded.
    static func editing(_ detail: EventDetail, accountID: UUID) -> EventDraft {
        let event = detail.event
        var draft = EventDraft(id: event.id, accountID: accountID, start: event.start,
                               end: event.isAllDay ? event.end.addingTimeInterval(-1) : event.end)
        draft.subject = event.subject == "(No title)" ? "" : event.subject
        draft.location = event.location
        draft.isAllDay = event.isAllDay
        draft.isPrivate = event.isPrivate
        draft.showAs = ShowAs(rawValue: event.showAs) ?? .busy
        draft.reminderMinutes = detail.reminderMinutes
        draft.notes = plainText(fromHTML: detail.html)
        draft.attendees = detail.attendees.filter { !$0.isOptional }.map(\.address)
            .filter { !$0.isEmpty }.joined(separator: ", ")
        draft.rooms = detail.roomBoxes
        draft.isOccurrence = event.isRecurring
        return draft
    }

    /// The notes as the plain text the form edits. The formatting of a note written in Outlook
    /// is not kept on save: this editor is plain text on purpose, like the mail composer.
    static func plainText(fromHTML html: String) -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = html.data(using: .utf8),
              let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil) else { return "" }
        return text.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
