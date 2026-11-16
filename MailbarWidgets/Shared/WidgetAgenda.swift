import Foundation

/// The one file Mailbar writes for its widgets (M26), and the only mailbox-derived data it ever
/// puts on disk: today's remaining events, each with start, end, title, location and join link.
/// No mail, no people, no notes, no server ids.
///
/// The app overwrites it after each Today refresh (`WidgetFeed`) and deletes it when the last
/// account is removed or "Show events in widgets" is turned off. It lives in the App Group
/// container (`~/Library/Group Containers/<team>.in.pooya.mailbar/`), the one place a sandboxed
/// widget extension can read. Compiled into both the app and the widget extension.
struct WidgetAgenda: Codable, Equatable, Sendable {
    struct Event: Codable, Equatable, Sendable, Identifiable {
        var start: Date
        var end: Date
        var title: String
        var location: String
        var joinURL: URL?

        var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)-\(title)" }
    }

    /// The day the events are for (its start), so a widget can tell yesterday's file from today's.
    var day: Date
    /// The zone the app shows times in (Settings, Work time), so the widget's times match.
    var timeZone: String
    var events: [Event]

    static let fileName = "Agenda.json"

    // MARK: - The shared file

    /// The App Group id from the bundle's Info.plist (`MailbarAppGroup`), set per configuration
    /// in project.yml so a Debug build never writes into the installed app's container.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "MailbarAppGroup") as? String
    }

    static var fileURL: URL? {
        guard let group = appGroup,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return folder.appendingPathComponent(fileName)
    }

    static func read() -> WidgetAgenda? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetAgenda.self, from: data)
    }

    // MARK: - What the widgets show

    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// True when the file is about today, in the app's zone.
    func isCurrent(at now: Date) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }

    func isAllDay(_ event: Event) -> Bool {
        let calendar = calendar
        return calendar.startOfDay(for: event.start) == event.start
            && calendar.startOfDay(for: event.end) == event.end
            && event.end.timeIntervalSince(event.start) >= 86_400 - 3_600
    }

    /// Events not yet over: all-day ones first, then by start.
    func remaining(at now: Date) -> [Event] {
        guard isCurrent(at: now) else { return [] }
        return events.filter { $0.end > now }
            .sorted { (isAllDay($0) ? 0 : 1, $0.start) < (isAllDay($1) ? 0 : 1, $1.start) }
    }

    /// The next timed events, the one under way first: Up Next leaves all-day ones out.
    func upNext(at now: Date, limit: Int = 3) -> [Event] {
        Array(remaining(at: now).filter { !isAllDay($0) }.prefix(limit))
    }

    /// When the widget should redraw: 15 minutes before each start (Join becomes the small
    /// widget's tap), each start (it turns "Now"), each end (it leaves), and the next midnight.
    func refreshDates(after now: Date) -> [Date] {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let moments = events.flatMap { [$0.start.addingTimeInterval(-15 * 60), $0.start, $0.end] }
            .filter { $0 > now && $0 < midnight }
        return Array(Set(moments + [midnight])).sorted()
    }

    // MARK: - Wording

    func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "09:30 to 10:00", or "All day".
    func span(_ event: Event) -> String {
        isAllDay(event) ? "All day" : "\(timeText(event.start)) to \(timeText(event.end))"
    }

    /// "Now", "in 25 min", "in 2 h 10 min", or the start time from three hours out.
    func relative(_ event: Event, now: Date) -> String {
        if event.start <= now { return "Now" }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        if minutes >= 180 { return "at \(timeText(event.start))" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    /// "Monday 16".
    func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE d"
        return formatter.string(from: date)
    }
}
