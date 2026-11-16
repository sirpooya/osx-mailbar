import Foundation

/// "5 accepted, 1 tentative, 2 declined, 3 not responded", for a meeting the user organized:
/// the detail panel and the meeting email's card both say it, after Outlook's tracking line.
struct ResponseCounts: Equatable, Sendable {
    var accepted = 0
    var tentative = 0
    var declined = 0
    var waiting = 0

    /// The organizer is left out: their own row is not an answer.
    init(attendees: [EventDetail.Attendee], organizer: String) {
        let me = organizer.lowercased()
        for person in attendees where me.isEmpty || person.address.lowercased() != me {
            switch person.response {
            case "Accept": accepted += 1
            case "Tentative": tentative += 1
            case "Decline": declined += 1
            case "Organizer": continue
            default: waiting += 1
            }
        }
    }

    var total: Int { accepted + tentative + declined + waiting }

    /// Only the answers someone gave, in Outlook's order; nil with nobody invited.
    var text: String? {
        guard total > 0 else { return nil }
        let parts = [(accepted, "accepted"), (tentative, "tentative"), (declined, "declined"), (waiting, "not responded")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.joined(separator: ", ")
    }
}

/// The open stretches of a work day, after Outlook's My Day: gaps of half an hour or more
/// between the busy events inside Settings' work hours, on a work day.
enum FreeSlots {
    static func gaps(in events: [CalendarEvent], on day: Date, workHours: ClosedRange<Int>, workDays: Set<Int>,
                     calendar: Calendar = .current, minimum: TimeInterval = 30 * 60) -> [DateInterval] {
        let dayStart = calendar.startOfDay(for: day)
        guard workDays.contains(calendar.component(.weekday, from: dayStart)),
              let from = calendar.date(byAdding: .hour, value: workHours.lowerBound, to: dayStart),
              let to = calendar.date(byAdding: .hour, value: workHours.upperBound, to: dayStart), to > from else { return [] }
        // What takes time: anything not shown as Free, not cancelled, not declined.
        let busy = events
            .filter { !$0.isAllDay && !$0.isCancelled && $0.showAs != "Free" && $0.myResponse != "Decline" }
            .map { (max($0.start, from), min($0.end, to)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
        var gaps: [DateInterval] = []
        var cursor = from
        for (start, end) in busy {
            if start.timeIntervalSince(cursor) >= minimum { gaps.append(DateInterval(start: cursor, end: start)) }
            cursor = max(cursor, end)
        }
        if to.timeIntervalSince(cursor) >= minimum { gaps.append(DateInterval(start: cursor, end: to)) }
        return gaps
    }

    /// "Free 14:00 to 16:00", 24-hour as the rest of the calendar.
    static func label(_ gap: DateInterval) -> String {
        "Free \(time(gap.start)) to \(time(gap.end))"
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

extension WindowsTimeZone {
    /// One entry per zone Exchange knows here, west to east, with a city to show it by.
    static let choices: [(id: String, zone: TimeZone)] = {
        var seen: Set<String> = []
        return byIANA.keys.sorted().compactMap { iana -> (String, TimeZone)? in
            guard let windows = byIANA[iana], !seen.contains(windows), let zone = TimeZone(identifier: iana) else { return nil }
            seen.insert(windows)
            return (windows, zone)
        }
        .sorted { ($0.1.secondsFromGMT(), $0.0) < ($1.1.secondsFromGMT(), $1.0) }
    }()

    /// The IANA zone a Windows id stands for, to show times in it.
    static func zone(for id: String?) -> TimeZone? {
        guard let id else { return nil }
        return choices.first { $0.id == id }?.zone
    }

    /// "Tehran", for the form's narrow zone popup.
    static func city(for id: String) -> String {
        guard let zone = zone(for: id) else { return id }
        return zone.identifier == "UTC" ? "UTC"
            : (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// "Tehran +03:30".
    static func label(for id: String) -> String {
        guard let zone = zone(for: id) else { return id }
        let city = zone.identifier == "UTC" ? "UTC" : (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
        let seconds = zone.secondsFromGMT()
        let sign = seconds < 0 ? "-" : "+"
        let offset = String(format: "%@%02d:%02d", sign, abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        return city == "UTC" ? "UTC" : "\(city) \(offset)"
    }
}

/// Moving a time between zones the way Outlook's Time zones does: the clock reading stays, so
/// 09:00 in Tehran becomes 09:00 in Istanbul.
enum EventZones {
    static func sameClock(_ date: Date, from: TimeZone, to: TimeZone) -> Date {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = from
        var target = Calendar(identifier: .gregorian)
        target.timeZone = to
        let parts = source.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return target.date(from: parts) ?? date
    }
}
