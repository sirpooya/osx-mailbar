import AppKit
import SwiftUI

/// The calendar's own window (M15), opened from the tray icon's right-click menu. A real titled,
/// resizable `NSWindow`, as Settings is, so the week grid has room; the app stays `.accessory`
/// and never shows in the Dock (AGENTS.md, Decisions).
@MainActor
final class CalendarWindow: NSObject, NSWindowDelegate {
    static let shared = CalendarWindow()

    private var window: NSWindow?
    private(set) var store: CalendarStore?

    var isOpen: Bool { window?.isVisible == true }

    func show(mail: MailStore) {
        WindowActivation.claim()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let store = CalendarStore(mail: mail)
        self.store = store

        let hosting = NSHostingController(rootView: CalendarRootView(store: store))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Calendar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MailbarCalendarWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        Task { await store.refresh() }
    }

    /// Streamed changes (M11) and the poller call this; it does nothing while the window is shut.
    func refreshIfOpen() {
        guard isOpen, let store else { return }
        Task { await store.refresh() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Coming back to the window is a check, as opening the popover is for mail.
        refreshIfOpen()
    }

    func windowWillClose(_ notification: Notification) {
        // The events go with the window: nothing of the calendar stays in memory once it is shut.
        window = nil
        store = nil
    }
}
