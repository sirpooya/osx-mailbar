import Foundation

/// How a new event repeats, after OWA's Repeat list (the user's screenshots, 2026-09-25): the
/// quick choices worded from the start date ("Every Wednesday", "Day 23 of every month", "Every
/// fourth Wednesday", "Every September 23"), and Other for any interval or set of weekdays.
/// Monthly and yearly patterns always follow the start date, as OWA's own editor does.
struct RepeatPattern: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case daily, weekly, monthlyDay, monthlyWeek, yearly
        var id: String { rawValue }
    }

    var kind: Kind
    /// Every how many days, weeks or months. Yearly has none in EWS: every year.
    var interval = 1
    /// Weekly only: Calendar weekdays, 1 (Sunday) to 7. Empty means the start's own day.
    var weekdays: Set<Int> = []

    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                             "September", "October", "November", "December"]
    private static let ordinals = ["first", "second", "third", "fourth", "last"]

    /// Which week of its month a date falls in, 0 to 4, the fifth being "last".
    static func weekIndex(of date: Date, calendar: Calendar = .current) -> Int {
        min((calendar.component(.day, from: date) - 1) / 7, 4)
    }

    /// The weekdays a weekly pattern repeats on, in the order of the user's week.
    func days(start: Date, calendar: Calendar = .current) -> [Int] {
        let chosen = weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : Array(weekdays)
        return chosen.sorted { Self.order($0, calendar) < Self.order($1, calendar) }
    }

    private static func order(_ weekday: Int, _ calendar: Calendar) -> Int {
        (weekday - calendar.firstWeekday + 7) % 7
    }

    // MARK: - Words

    func label(start: Date, workDays: Set<Int>, calendar: Calendar = .current) -> String {
        let day = calendar.component(.day, from: start)
        let weekday = Self.dayNames[calendar.component(.weekday, from: start) - 1]
        let month = Self.monthNames[calendar.component(.month, from: start) - 1]
        let ordinal = Self.ordinals[Self.weekIndex(of: start, calendar: calendar)]
        switch kind {
        case .daily:
            return interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            let days = days(start: start, calendar: calendar)
            if interval == 1, Set(days) == workDays, days.count > 1 { return "Every workday" }
            let names = Self.list(days.map { Self.dayNames[$0 - 1] })
            return interval == 1 ? "Every \(names)" : "Every \(interval) weeks on \(names)"
        case .monthlyDay:
            return interval == 1 ? "Day \(day) of every month" : "Day \(day) of every \(interval) months"
        case .monthlyWeek:
            return interval == 1 ? "Every \(ordinal) \(weekday)" : "The \(ordinal) \(weekday) of every \(interval) months"
        case .yearly:
            return "Every \(month) \(day)"
        }
    }

    /// The quick choices, in OWA's order.
    static func presets(workDays: Set<Int>) -> [RepeatPattern] {
        [RepeatPattern(kind: .daily), RepeatPattern(kind: .weekly),
         RepeatPattern(kind: .weekly, weekdays: workDays), RepeatPattern(kind: .monthlyDay),
         RepeatPattern(kind: .monthlyWeek), RepeatPattern(kind: .yearly)]
    }

    /// The name of each kind in the Other editor.
    static func kindName(_ kind: Kind, start: Date, calendar: Calendar = .current) -> String {
        switch kind {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthlyDay: return "Monthly, on day \(calendar.component(.day, from: start))"
        case .monthlyWeek:
            return "Monthly, on the \(ordinals[weekIndex(of: start, calendar: calendar)]) "
                + dayNames[calendar.component(.weekday, from: start) - 1]
        case .yearly: return "Yearly"
        }
    }

    private static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }

    // MARK: - EWS

    /// The pattern element of `<t:Recurrence>`, in the schema's names.
    func xml(start: Date, calendar: Calendar = .current) -> String {
        let n = max(interval, 1)
        let day = calendar.component(.day, from: start)
        let weekday = Self.dayNames[calendar.component(.weekday, from: start) - 1]
        switch kind {
        case .daily:
            return "<t:DailyRecurrence><t:Interval>\(n)</t:Interval></t:DailyRecurrence>"
        case .weekly:
            let names = days(start: start, calendar: calendar).map { Self.dayNames[$0 - 1] }.joined(separator: " ")
            return "<t:WeeklyRecurrence><t:Interval>\(n)</t:Interval><t:DaysOfWeek>\(names)</t:DaysOfWeek></t:WeeklyRecurrence>"
        case .monthlyDay:
            return "<t:AbsoluteMonthlyRecurrence><t:Interval>\(n)</t:Interval><t:DayOfMonth>\(day)</t:DayOfMonth></t:AbsoluteMonthlyRecurrence>"
        case .monthlyWeek:
            let index = ["First", "Second", "Third", "Fourth", "Last"][Self.weekIndex(of: start, calendar: calendar)]
            return "<t:RelativeMonthlyRecurrence><t:Interval>\(n)</t:Interval><t:DaysOfWeek>\(weekday)</t:DaysOfWeek>"
                + "<t:DayOfWeekIndex>\(index)</t:DayOfWeekIndex></t:RelativeMonthlyRecurrence>"
        case .yearly:
            let month = Self.monthNames[calendar.component(.month, from: start) - 1]
            return "<t:AbsoluteYearlyRecurrence><t:DayOfMonth>\(day)</t:DayOfMonth><t:Month>\(month)</t:Month></t:AbsoluteYearlyRecurrence>"
        }
    }
}

/// When a series stops: never, on a date, or after a number of times.
enum RepeatEnd: Equatable, Sendable {
    case never
    case on(Date)
    case after(Int)
}
