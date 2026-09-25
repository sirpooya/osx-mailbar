import Foundation

/// The rest of today (M19): what the popover's Today strip lists above the inbox.
enum TodayAgenda {
    /// Events still to come or under way today, soonest first; declined and cancelled left out.
    static func rest(of events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return events
            .filter { $0.end > now && $0.start < endOfDay && !$0.isCancelled && $0.myResponse != "Decline" }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// Every event that touches today, over or not: the Today tab's day view.
    static func all(of events: [CalendarEvent], on now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return events.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
    }

    /// The first online-meeting link in an event's notes: Teams, Zoom, Google Meet, Webex.
    static func joinLink(inHTML html: String) -> URL? {
        let pattern = #"https://(teams\.microsoft\.com/l/meetup-join/|[\w.-]*zoom\.us/j/|meet\.google\.com/|[\w.-]*webex\.com/)[^\s"'<>]+"#
        guard let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: raw)
    }

    /// "Now", "in 25 min", "in 2 h", for the next event's line.
    static func relative(_ event: CalendarEvent, now: Date) -> String {
        if event.start <= now { return "Now" }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }
}
