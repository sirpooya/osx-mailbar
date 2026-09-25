import Foundation

/// Every UserDefaults key the app owns, in one place, with the defaults registered at launch.
///
/// `UserDefaults.integer` answers `0` for an absent key, so any default that is not `0` or `false`
/// has to be registered or the first launch reads the wrong thing.
///
/// The `mailbar.` prefix is a storage address, not a label. Renaming it strands every setting.
/// Nothing from the mailbox is ever stored here: only configuration.
enum Keys {
    /// The account list, JSON. No passwords: those are in the Keychain.
    static let accounts = "mailbar.accounts"
    static let pollMinutes = "mailbar.pollMinutes"
    /// The account whose inbox the popover shows, when there is more than one.
    static let selectedAccount = "mailbar.selectedAccount"
    /// New-mail notifications on or off (M7).
    static let notifyNewMail = "mailbar.notifyNewMail"
    /// Event reminders on or off (M18).
    static let eventReminders = "mailbar.eventReminders"
    /// The people directory's address (a JSON list of people with team and department), or
    /// empty for none. Never a default: the user types it.
    static let peopleDirectoryURL = "mailbar.peopleDirectoryURL"
    /// How many people the directory's last good read listed, and when, so Settings can say so
    /// before it reads again. A count and a time only, never the people.
    static let peopleDirectoryCount = "mailbar.peopleDirectoryCount"
    static let peopleDirectoryReadAt = "mailbar.peopleDirectoryReadAt"

    // Calendar (M15)
    /// Day, work week, week or month, as last chosen.
    static let calendarMode = "mailbar.calendarMode"
    /// The first day of the week, `Calendar` numbering (1 Sunday ... 7 Saturday).
    static let calendarWeekStart = "mailbar.calendarWeekStart"
    /// The work week's days, same numbering, comma separated.
    static let calendarWorkDays = "mailbar.calendarWorkDays"
    static let calendarWorkStartHour = "mailbar.calendarWorkStartHour"
    static let calendarWorkEndHour = "mailbar.calendarWorkEndHour"
    /// An IANA zone the app runs in instead of the Mac's, or empty for the Mac's own.
    static let calendarTimeZone = "mailbar.calendarTimeZone"

    static let pollMinuteChoices = [1, 2, 3, 5, 10]

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            pollMinutes: 2,
            notifyNewMail: true,
            eventReminders: true,
            // The user's OWA: the week runs Saturday to Friday, the work week Saturday to
            // Wednesday, working hours 9 to 17.
            calendarWeekStart: 7,
            calendarWorkDays: "7,1,2,3,4",
            calendarWorkStartHour: 9,
            calendarWorkEndHour: 17,
        ])
    }

    static func calendarWeekStart(_ defaults: UserDefaults = .standard) -> Int {
        min(max(defaults.integer(forKey: calendarWeekStart), 1), 7)
    }

    static func calendarWorkDays(_ defaults: UserDefaults = .standard) -> Set<Int> {
        let days = (defaults.string(forKey: calendarWorkDays) ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...7).contains($0) }
        return days.isEmpty ? [7, 1, 2, 3, 4] : Set(days)
    }

    static func calendarWorkHours(_ defaults: UserDefaults = .standard) -> ClosedRange<Int> {
        let start = min(max(defaults.integer(forKey: calendarWorkStartHour), 0), 23)
        let end = min(max(defaults.integer(forKey: calendarWorkEndHour), start + 1), 24)
        return start...end
    }

    /// Sets the zone the whole app shows and writes times in: the chosen one, or the Mac's. Every
    /// `Calendar.current`, formatter and `WindowsTimeZone.current` follows `NSTimeZone.default`.
    static func applyTimeZone(_ defaults: UserDefaults = .standard) {
        let chosen = defaults.string(forKey: calendarTimeZone).flatMap { TimeZone(identifier: $0) }
        NSTimeZone.default = chosen ?? NSTimeZone.system
    }

    /// Clamped so a hand-edited plist cannot make the app poll every second.
    static func pollInterval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = min(max(defaults.integer(forKey: pollMinutes), 1), 10)
        return TimeInterval(minutes * 60)
    }
}
