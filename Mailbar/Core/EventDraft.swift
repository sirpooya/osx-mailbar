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

    /// Someone invited, as the People sidebar lists them.
    struct Invitee: Equatable, Hashable, Identifiable, Sendable {
        let name: String
        let address: String
        var id: String { address.lowercased() }
        var display: String { name.isEmpty ? address : name }
    }

    /// A file added in the form: its bytes in memory until Save sends them, never on disk.
    struct NewFile: Equatable, Identifiable {
        let id = UUID()
        let name: String
        let data: Data
        var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
    }

    /// Exchange's default request limit is about 35 MB, and Base64 adds a third.
    static let attachmentLimit = 25 * 1024 * 1024

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
    var people: [Invitee] = []
    /// Category names, as the master list spells them. The first one colours the event.
    var categories: [String] = []
    /// `EventCharm` raw value, or nil for none.
    var charm: Int?
    /// Files the event already has, those the user removed from it, and those being added.
    var existingFiles: [FileAttachment] = []
    var removedFileIDs: Set<String> = []
    var newFiles: [NewFile] = []
    /// Editing one occurrence of a series: the repeat rule is the series', not changeable here.
    var isOccurrence = false
    var isSaving = false
    var error: String?

    var isNew: Bool { id == nil }
    var attendeeList: [String] { people.map(\.address) }
    var keptFiles: [FileAttachment] { existingFiles.filter { !removedFileIDs.contains($0.id) } }
    var changesFiles: Bool { !newFiles.isEmpty || !removedFileIDs.isEmpty }
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
        if newFiles.reduce(0, { $0 + $1.data.count }) > Self.attachmentLimit {
            return "Files over 25 MB together are too large for Exchange to take."
        }
        return nil
    }

    /// Sending invitations: shown on the Save button so the user knows it will mail people.
    var sendsInvitations: Bool { !attendeeList.isEmpty || !rooms.isEmpty }

    // MARK: - Start and length

    /// The form sets a start and a length, not an end (the user's call, 2026-09-25): moving the
    /// start moves the end with it.
    var duration: TimeInterval {
        get { max(end.timeIntervalSince(start), 0) }
        set { end = start.addingTimeInterval(newValue) }
    }

    var startKeepingDuration: Date {
        get { start }
        set { let length = end.timeIntervalSince(start); start = newValue; end = newValue.addingTimeInterval(length) }
    }

    /// An all-day event's length in days. `end` is then any moment on its last day.
    var days: Int {
        get {
            let calendar = Calendar.current
            let count = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                to: calendar.startOfDay(for: max(end, start))).day ?? 0
            return count + 1
        }
        set { end = Calendar.current.date(byAdding: .day, value: max(newValue, 1) - 1, to: start) ?? start }
    }

    /// Lengths the form offers, in minutes; the draft's own is added when it is not one of them.
    static let durationChoices = [15, 30, 45, 60, 90, 120, 150, 180, 240, 300, 360, 480]

    static func durationLabel(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) minutes" }
        if rest == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        if rest == 30 { return "\(hours).5 hours" }
        return "\(hours) h \(rest) min"
    }

    // MARK: - Starting points

    /// A new event at the start of the next half hour, an hour long; or at a slot double-clicked;
    /// or over the range dragged out on the grid (`until`).
    static func new(accountID: UUID, at slot: Date? = nil, until end: Date? = nil) -> EventDraft {
        let calendar = Calendar.current
        let start: Date
        if let slot {
            start = slot
        } else {
            // The next half hour, from the start of this minute. `date(bySetting: .second)` would
            // move FORWARD to the next zero second and give 16:01 for 16:00.
            let now = Date()
            let minute = calendar.component(.minute, from: now)
            let thisMinute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
            start = calendar.date(byAdding: .minute, value: minute < 30 ? 30 - minute : 60 - minute, to: thisMinute) ?? now
        }
        let finish = end.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        return EventDraft(accountID: accountID, start: start, end: finish)
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
        draft.people = detail.attendees.filter { !$0.isOptional && !$0.address.isEmpty }
            .map { Invitee(name: $0.name, address: $0.address) }
        draft.rooms = detail.roomBoxes
        draft.categories = event.categories
        draft.charm = event.charm
        draft.existingFiles = detail.files
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
