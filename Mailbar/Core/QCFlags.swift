import Foundation

/// Launch flags that put a surface on screen without a click, so `mac-qc` can photograph it on a
/// host that has no Accessibility grant to drive the status item. DEBUG only.
///
///     Mailbar.app/Contents/MacOS/Mailbar --open-settings
///     Mailbar.app/Contents/MacOS/Mailbar --open-popover
///     Mailbar.app/Contents/MacOS/Mailbar --open-editor      (Settings plus the add sheet)
enum QCFlags {
    static var openSettings: Bool { has("--open-settings") || openEditor }
    static var openPopover: Bool { has("--open-popover") }
    static var openEditor: Bool { has("--open-editor") }

    private static func has(_ flag: String) -> Bool {
        #if DEBUG
        return CommandLine.arguments.contains(flag)
        #else
        return false
        #endif
    }
}
