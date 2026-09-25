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
    static var openPopover: Bool { has("--open-popover") || openMessage || searchText != nil || composeKind != nil }
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

    /// `--open-calendar` or `--open-calendar=month` (day, workWeek, week, month): the calendar window.
    static var openCalendar: String? {
        #if DEBUG
        if has("--open-calendar") { return "" }
        return CommandLine.arguments.first { $0.hasPrefix("--open-calendar=") }.map { String($0.dropFirst("--open-calendar=".count)) }
        #else
        return nil
        #endif
    }

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
