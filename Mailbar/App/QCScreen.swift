import AppKit

#if DEBUG
/// Screenshot runs (`MAILBAR_MOCK`) put every window and the popover on the Mac's built-in
/// display, never the external one the user is working on (the user's call, 2026-11-16: "only
/// open in MacBook Pro monitor for test, not in the LG monitor"). DEBUG and mock mode only; the
/// installed app is never moved.
@MainActor
enum QCScreen {
    /// The built-in panel, when one is connected and it is not already the main display.
    static var builtIn: NSScreen? {
        guard MockMode.current != nil else { return nil }
        let panel = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
        return panel == NSScreen.screens.first ? nil : panel
    }

    private static var placed: Set<Int> = []
    private static var timer: Timer?
    private static var anchorWindow: NSWindow?

    /// A one-point window under the built-in display's menu bar, top right, for the popover to
    /// hang from instead of the status item on the main display.
    static var anchor: NSView? {
        guard let screen = builtIn else { return nil }
        if anchorWindow == nil {
            let frame = screen.visibleFrame
            let window = NSWindow(contentRect: NSRect(x: frame.maxX - 220, y: frame.maxY - 1, width: 1, height: 1),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .statusBar
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            anchorWindow = window
        }
        return anchorWindow?.contentView
    }

    /// Moves each new ordinary window to the built-in display once, centred, as it appears.
    static func install() {
        guard builtIn != nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { moveNewWindows() }
        }
    }

    private static func moveNewWindows() {
        guard let screen = builtIn else { return }
        for window in NSApp.windows where window.isVisible && !placed.contains(window.windowNumber) {
            let kind = String(describing: type(of: window))
            // The popover follows its anchor and the status item stays in its menu bar.
            guard window !== anchorWindow, !kind.contains("Popover"), !kind.contains("StatusBar"),
                  window.level == .normal || window.level == .floating else { continue }
            placed.insert(window.windowNumber)
            guard window.screen != screen else { continue }
            let area = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, area.width)
            frame.size.height = min(frame.height, area.height)
            frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
    }
}
#endif
