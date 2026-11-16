import Foundation

/// A small iCalendar reader for "Add to Calendar" on an .ics or .vcs attachment (2026-11-16):
/// each VEVENT's start and end (with TZID, UTC or floating, and all-day `VALUE=DATE`), summary,
/// location, description, uid and a basic RRULE. Nothing else of the format is read. In memory
/// only: the file's bytes and what is parsed from them go when the sheet closes.
enum ICalendar {
    struct Event: Equatable, Identifiable {
        var uid = ""
        var summary = ""
        var location = ""
        var notes = ""
        var start: Date
        var end: Date
        var isAllDay = false
        var repeatPattern: RepeatPattern?
        var repeatEnd: RepeatEnd = .never
        var id: String { uid.isEmpty ? "\(start.timeIntervalSince1970)-\(summary)" : uid }
    }

    /// Every event in the file; an event without a readable start is left out.
    static func events(in data: Data, calendar: Calendar = .current) -> [Event] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [Event] = []
        var fields: [(name: String, params: [String: String], value: String)]?
        for line in unfolded(text) {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { fields = []; continue }
            if upper == "END:VEVENT" {
                if let fields, let event = event(from: fields, calendar: calendar) { result.append(event) }
                fields = nil
                continue
            }
            guard fields != nil, let property = property(line) else { continue }
            fields?.append(property)
        }
        return result
    }

    /// RFC 5545's folding: a line that starts with a space or a tab continues the one before.
    static func unfolded(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    /// "DTSTART;TZID=Asia/Tehran:20261120T100000" as its name, parameters and value. The value
    /// starts at the first colon outside a quoted parameter.
    static func property(_ line: String) -> (name: String, params: [String: String], value: String)? {
        var quoted = false
        var split: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if character == ":", !quoted { split = index; break }
        }
        guard let split else { return nil }
        let head = line[..<split].split(separator: ";").map(String.init)
        guard let name = head.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for part in head.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name, params, String(line[line.index(after: split)...]))
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func event(from fields: [(name: String, params: [String: String], value: String)],
                              calendar: Calendar) -> Event? {
        func field(_ name: String) -> (params: [String: String], value: String)? {
            fields.first { $0.name == name }.map { ($0.params, $0.value) }
        }
        guard let startField = field("DTSTART"),
              let parsed = date(startField.value, params: startField.params, calendar: calendar) else { return nil }
        let (start, allDay) = parsed
        var end = field("DTEND").flatMap { date($0.value, params: $0.params, calendar: calendar)?.0 }
        if end == nil, let duration = field("DURATION").flatMap({ seconds(inDuration: $0.value) }) {
            end = start.addingTimeInterval(duration)
        }
        let finish = end.flatMap { $0 > start ? $0 : nil }
            ?? (allDay ? calendar.date(byAdding: .day, value: 1, to: start) ?? start : start.addingTimeInterval(3600))
        var event = Event(start: start, end: finish, isAllDay: allDay)
        event.uid = field("UID")?.value ?? ""
        event.summary = unescape(field("SUMMARY")?.value ?? "")
        event.location = unescape(field("LOCATION")?.value ?? "")
        event.notes = unescape(field("DESCRIPTION")?.value ?? "")
        if let rule = field("RRULE")?.value {
            (event.repeatPattern, event.repeatEnd) = repeatRule(rule, start: start, calendar: calendar)
        }
        return event
    }

    /// A start or an end, and whether it is a whole day. `Z` is UTC; a TZID is an IANA name or
    /// one of the Windows names Outlook writes; anything else is the user's own zone.
    static func date(_ value: String, params: [String: String], calendar: Calendar) -> (Date, Bool)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let digits = text.filter(\.isNumber)
        if params["VALUE"]?.uppercased() == "DATE" || (digits.count == 8 && !text.contains("T")) {
            guard digits.count >= 8 else { return nil }
            var components = DateComponents()
            components.year = Int(digits.prefix(4))
            components.month = Int(digits.dropFirst(4).prefix(2))
            components.day = Int(digits.dropFirst(6).prefix(2))
            return calendar.date(from: components).map { ($0, true) }
        }
        guard digits.count >= 12 else { return nil }
        var zone = calendar.timeZone
        if text.hasSuffix("Z") || text.hasSuffix("z") {
            zone = TimeZone(identifier: "UTC")!
        } else if let id = params["TZID"] {
            zone = TimeZone(identifier: id)
                ?? WindowsTimeZone.zone(for: id)
                ?? WindowsTimeZone.byIANA.first(where: { $0.value == id }).flatMap { TimeZone(identifier: $0.key) }
                ?? zone
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        var components = DateComponents()
        components.year = Int(digits.prefix(4))
        components.month = Int(digits.dropFirst(4).prefix(2))
        components.day = Int(digits.dropFirst(6).prefix(2))
        components.hour = Int(digits.dropFirst(8).prefix(2))
        components.minute = Int(digits.dropFirst(10).prefix(2))
        components.second = digits.count >= 14 ? Int(digits.dropFirst(12).prefix(2)) : 0
        return gregorian.date(from: components).map { ($0, false) }
    }

    /// "PT1H30M", "P1D": a DURATION's length.
    static func seconds(inDuration text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in text.uppercased() {
            switch character {
            case "P", "+": continue
            case "T": inTime = true
            case "0"..."9": number.append(character)
            default:
                guard let value = Double(number) else { return nil }
                switch character {
                case "W": total += value * 7 * 86_400
                case "D": total += value * 86_400
                case "H": total += value * 3600
                case "M": total += inTime ? value * 60 : value * 30 * 86_400
                case "S": total += value
                default: return nil
                }
                number = ""
            }
        }
        return total > 0 ? total : nil
    }

    /// The RRULE parts the form's repeat can hold: FREQ, INTERVAL, BYDAY, COUNT, UNTIL.
    static func repeatRule(_ rule: String, start: Date, calendar: Calendar) -> (RepeatPattern?, RepeatEnd) {
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0].uppercased()] = pair[1].uppercased() }
        }
        let interval = parts["INTERVAL"].flatMap(Int.init) ?? 1
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let byDay = (parts["BYDAY"] ?? "").split(separator: ",").map(String.init)
        var pattern: RepeatPattern?
        switch parts["FREQ"] {
        case "DAILY":
            pattern = RepeatPattern(kind: .daily, interval: interval)
        case "WEEKLY":
            let days = Set(byDay.compactMap { code in codes.firstIndex(of: String(code.suffix(2))).map { $0 + 1 } })
            pattern = RepeatPattern(kind: .weekly, interval: interval, weekdays: days)
        case "MONTHLY":
            // "2TU" or "-1FR": a weekday of the month; otherwise the start's date.
            let relative = byDay.contains { $0.count > 2 }
            pattern = RepeatPattern(kind: relative ? .monthlyWeek : .monthlyDay, interval: interval)
        case "YEARLY":
            pattern = RepeatPattern(kind: .yearly)
        default:
            pattern = nil
        }
        var end = RepeatEnd.never
        if let count = parts["COUNT"].flatMap(Int.init) {
            end = .after(max(count, 1))
        } else if let until = parts["UNTIL"], let day = date(until, params: [:], calendar: calendar)?.0 {
            end = .on(day)
        }
        return (pattern, pattern == nil ? .never : end)
    }

    /// What Add to Calendar writes: a plain appointment, nobody invited, in memory until sent.
    static func draft(_ event: Event, accountID: UUID) -> EventDraft {
        var draft = EventDraft(accountID: accountID, start: event.start,
                               end: event.isAllDay ? event.end.addingTimeInterval(-1) : event.end)
        draft.subject = event.summary
        draft.location = event.location
        draft.notes = event.notes
        draft.isAllDay = event.isAllDay
        draft.repeatPattern = event.repeatPattern
        draft.repeatEnd = event.repeatEnd
        return draft
    }

    /// True for the attachments this reads: .ics and the older .vcs, or the calendar type.
    static func isCalendarFile(name: String, contentType: String = "") -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".ics") || lower.hasSuffix(".vcs") || contentType.lowercased().contains("text/calendar")
    }
}
