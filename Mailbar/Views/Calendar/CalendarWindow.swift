import AppKit
import SwiftUI

/// The calendar's own window (M15), opened from the tray icon's right-click menu. A real titled,
/// resizable `NSWindow`, as Settings is, so the week grid has room.
///
/// **The one time Mailbar shows in the Dock** (the user's request, 2026-09-25): while this window
/// is open the app is `.regular`, so the calendar sits in the Dock and in Cmd+Tab like any
/// calendar app; closing it puts the app back to `.accessory`, menu bar only. Settings and the
/// popover never add a Dock tile.
///
/// A two-finger swipe (or a sideways wheel) anywhere in the window steps to the next or previous
/// day, week or month, the way the popover swipes between accounts.
@MainActor
final class CalendarWindow: NSObject, NSWindowDelegate {
    static let shared = CalendarWindow()

    private var window: NSWindow?
    private(set) var store: CalendarStore?
    private var swipeMonitor: Any?

    private static let swipeThreshold: CGFloat = 40

    var isOpen: Bool { window?.isVisible == true }

    func show(mail: MailStore) {
        DockPresence.windowOpened()
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
        window.minSize = CalendarRootView.minimumSize
        // Opens at the size the user picked (2026-09-25); after that, wherever they leave it.
        window.setContentSize(NSSize(width: 870, height: 620))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // A new name, so the new default size applies once instead of an old saved frame.
        window.setFrameAutosaveName("MailbarCalendarWindow.v2")
        if let width = QCFlags.calendarWidth {
            // After the autosaved frame is restored, or that frame wins.
            DispatchQueue.main.async {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        installSwipe()
        Task { await store.refresh() }
    }

    /// The Dock icon was clicked: bring the calendar forward.
    func bringForward() {
        guard let window else { return }
        WindowActivation.claim()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Swiping between weeks

    /// A trackpad swipe arrives as scroll events with phases, which no SwiftUI gesture reports, so
    /// a local monitor collects them. Only events in this window count.
    ///
    /// The first few points decide the axis, as Calendar does: sideways, and the page strip
    /// follows the fingers and the events are consumed so the hours do not also scroll; up and
    /// down, and the events pass straight through to the hour grid. The momentum that trails a
    /// sideways swipe is swallowed too, or it would nudge the grid after the page has settled.
    private func installSwipe() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread; the event just is not marked Sendable.
            nonisolated(unsafe) let scroll = event
            let consumed = MainActor.assumeIsolated { self?.handleSwipe(scroll) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeSwipe() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var travel = CGSize.zero

    /// Returns true when the event was used for paging and must not reach the scroll view.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard let store, let window, event.window === window else { return false }
        let pager = store.pager
        let time = event.timestamp

        if !event.momentumPhase.isEmpty {
            return axis == .horizontal
        }
        if event.phase.contains(.began) {
            axis = .undecided
            travel = .zero
            pager.began()
            return false
        }
        if event.phase.contains(.changed) {
            if axis == .undecided {
                travel.width += event.scrollingDeltaX
                travel.height += event.scrollingDeltaY
                guard abs(travel.width) + abs(travel.height) > 4 else { return false }
                axis = abs(travel.width) > abs(travel.height) ? .horizontal : .vertical
                if axis == .horizontal { pager.moved(by: travel.width, at: time) }
                return axis == .horizontal
            }
            guard axis == .horizontal else { return false }
            pager.moved(by: event.scrollingDeltaX, at: time)
            return true
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { if axis != .horizontal { axis = .undecided } }
            guard axis == .horizontal else { return false }
            pager.ended(at: time)
            return true
        }
        // A mouse with a sideways wheel sends no phases: one decisive push is one page.
        if event.phase.isEmpty,
           let direction = SwipeTracker.direction(ofUnphasedDeltaX: event.scrollingDeltaX,
                                                  deltaY: event.scrollingDeltaY,
                                                  threshold: Self.swipeThreshold) {
            store.slide(forward: direction == .left)
            return true
        }
        return false
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
        removeSwipe()
        window = nil
        store = nil
        DockPresence.windowClosed()
    }
}
