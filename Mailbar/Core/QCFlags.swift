import Foundation

/// Launch flags that put a surface on screen without a click, so `mac-qc` can photograph it on a
/// host that has no Accessibility grant to drive the status item. DEBUG only.
///
///     Mailbar.app/Contents/MacOS/Mailbar --open-settings
///     Mailbar.app/Contents/MacOS/Mailbar --open-popover
///     Mailbar.app/Contents/MacOS/Mailbar --open-editor      (Settings plus the add sheet)
///     Mailbar.app/Contents/MacOS/Mailbar --open-message     (the popover, first message open)
///     Mailbar.app/Contents/MacOS/Mailbar --editor-signin    (the add sheet, signed in, mock only)
///     Mailbar.app/Contents/MacOS/Mailbar --load-images      (remote images allowed from the start)
enum QCFlags {
    static var openSettings: Bool { has("--open-settings") || openEditor }
    static var openPopover: Bool { has("--open-popover") || openMessage || searchText != nil || composeKind != nil || openToday }
    /// `--open-today`: the popover on its Today tab.
    static var openToday: Bool { has("--open-today") }
    /// `--today-swipe`: with `--open-today`, a scripted sideways swipe to the next day, through the
    /// same pager calls a trackpad makes, for screenshots of where it comes to rest.
    static var todaySwipe: Bool { has("--today-swipe") }

    /// `--today-offset=1`: with `--open-today`, the Today tab on that many days from today.
    static var todayOffset: Int? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--today-offset=") }.flatMap { Int($0.dropFirst("--today-offset=".count)) }
        #else
        return nil
        #endif
    }
    static var openMessage: Bool { openMessageIndex != nil }
    /// `--compose=reply` or `--compose=new`: the composer with sample text, mock mode only.
    static var composeKind: String? {
        #if DEBUG
        guard MockMode.current != nil else { return nil }
        return CommandLine.arguments.first { $0.hasPrefix("--compose=") }.map { String($0.dropFirst("--compose=".count)) }
        #else
        return nil
        #endif
    }

    /// `--open-calendar` or `--open-calendar=month` (day, week, month): the calendar window.
    static var openCalendar: String? {
        #if DEBUG
        if has("--open-calendar") { return "" }
        return CommandLine.arguments.first { $0.hasPrefix("--open-calendar=") }.map { String($0.dropFirst("--open-calendar=".count)) }
        #else
        return nil
        #endif
    }

    /// `--calendar-width=560`: the calendar window at that width, to photograph narrow layouts.
    static var calendarWidth: CGFloat? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--calendar-width=") }
            .flatMap { Double($0.dropFirst("--calendar-width=".count)) }.map { CGFloat($0) }
        #else
        return nil
        #endif
    }

    /// `--settings-tab=calendar`: Settings opens on that tab.
    static var settingsTab: SettingsTab? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--settings-tab=") }
            .flatMap { SettingsTab(rawValue: String($0.dropFirst("--settings-tab=".count)).capitalized) }
        #else
        return nil
        #endif
    }

    /// `--settings-height=1200`: the Settings window that tall, to photograph the lower sections.
    static var settingsHeight: CGFloat? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--settings-height=") }
            .flatMap { Double($0.dropFirst("--settings-height=".count)) }.map { CGFloat($0) }
        #else
        return nil
        #endif
    }

    /// `--calendar-new`: the calendar with the new event form open.
    static var calendarNew: Bool { has("--calendar-new") }

    /// `--calendar-rooms=هفت`: with `--calendar-new`, that typed into Location, listing its rooms.
    static var calendarRooms: String? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--calendar-rooms=") }.map { String($0.dropFirst("--calendar-rooms=".count)) }
        #else
        return nil
        #endif
    }

    /// `--calendar-charms`, `--calendar-categories`: with `--calendar-new`, that picker open.
    static var calendarCharms: Bool { has("--calendar-charms") }
    static var calendarCategories: Bool { has("--calendar-categories") }

    /// `--person-card=omid@example.org`: with `--calendar-new`, that attendee's contact card open.
    static var personCard: String? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--person-card=") }
            .map { String($0.dropFirst("--person-card=".count)).lowercased() }
        #else
        return nil
        #endif
    }

    /// `--directory-picker`: with `--calendar-new`, the Team and Department picker open.
    static var directoryPicker: Bool { has("--directory-picker") }

    /// `--with-group`: with `--calendar-new` or `--compose=new`, a distribution group already added.
    static var withGroup: Bool { has("--with-group") }

    /// `--calendar-people=sar`: with `--calendar-new`, that typed into the People field.
    static var calendarPeople: String? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--calendar-people=") }.map { String($0.dropFirst("--calendar-people=".count)) }
        #else
        return nil
        #endif
    }

    /// `--calendar-repeat`: with `--calendar-new`, Repeat's Other editor open, on Monthly.
    static var calendarRepeat: Bool { has("--calendar-repeat") }

    /// `--calendar-series=on` (or `after`, `never`): with `--calendar-new`, a daily series with
    /// that end, for screenshots of the Until row.
    static var calendarSeries: String? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--calendar-series=") }.map { String($0.dropFirst("--calendar-series=".count)) }
        #else
        return nil
        #endif
    }

    /// `--calendar-assistant`: with `--calendar-new`, the Scheduling Assistant open.
    static var calendarAssistant: Bool { has("--calendar-assistant") }

    /// `--calendar-drag`: the calendar with a new event being dragged out today, 10:00 to 11:30.
    static var calendarDrag: Bool { has("--calendar-drag") }

    /// `--calendar-select=Design Weekly`: the calendar with that event's detail panel open.
    static var calendarSelect: String? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--calendar-select=") }.map { String($0.dropFirst("--calendar-select=".count)) }
        #else
        return nil
        #endif
    }

    /// `--search=booking`: the popover with the search field open on that text.
    static var searchText: String? {
        #if DEBUG
        return CommandLine.arguments.first { $0.hasPrefix("--search=") }.map { String($0.dropFirst("--search=".count)) }
        #else
        return nil
        #endif
    }
    /// `--open-message` opens the first message, `--open-message=5` the sixth.
    static var openMessageIndex: Int? {
        #if DEBUG
        if has("--open-message") { return 0 }
        return CommandLine.arguments.first { $0.hasPrefix("--open-message=") }
            .flatMap { Int($0.dropFirst("--open-message=".count)) }
        #else
        return nil
        #endif
    }
    static var openEditor: Bool { has("--open-editor") || editorSignIn || editorEmail }
    /// The add sheet, filled with the mock account's address and signed in, to photograph what
    /// Autodiscover fills in. Mock mode only.
    /// The add sheet with the mock account's address typed in and nothing else, to photograph the
    /// saved-login offer. Mock mode only.
    static var editorEmail: Bool { has("--editor-email") && MockMode.current != nil }
    static var editorSignIn: Bool { has("--editor-signin") && MockMode.current != nil }
    /// Opens messages with remote images already allowed: the positive control for the pixel
    /// test (a blocked load only proves something if an allowed one is seen to arrive).
    static var loadImages: Bool { has("--load-images") }
    /// Draws the first inbox row as hovered, since a synthetic pointer cannot reach the app
    /// without the Accessibility grant.
    static var hoverFirstRow: Bool { has("--hover-first-row") }

    private static func has(_ flag: String) -> Bool {
        #if DEBUG
        return CommandLine.arguments.contains(flag)
        #else
        return false
        #endif
    }
}
