import AppKit

/// The Dock tile shows while the calendar or Settings is open (the user's calls, 2026-09-25), so
/// either is in the Dock and Cmd+Tab; with both closed the app is menu bar only again.
@MainActor
enum DockPresence {
    static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
    }

    /// A turn later, so the closing window has finished closing and no longer counts as open.
    static func windowClosed() {
        DispatchQueue.main.async {
            if !CalendarWindow.shared.isOpen, !SettingsWindow.shared.isOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
