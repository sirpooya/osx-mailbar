import Foundation

/// The time on a row, the way the user asked for it: today shows the time, then `Yesterday`,
/// then `2 days ago` up to six, then a short date, with the year only when it is not this year.
///
/// Counted in calendar days, not in 24-hour blocks, so a message from 23:50 last night is
/// "Yesterday" at 00:10, as it is in Outlook.
enum RelativeTime {
    static func label(for date: Date,
                      now: Date = Date(),
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0

        // Zero, or a clock skewed into the future: both are "today".
        if days <= 0 {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                   locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }

        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(base.month(.abbreviated).day())
            : date.formatted(base.month(.abbreviated).day().year())
    }
}
