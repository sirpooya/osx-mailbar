import AppKit
import SwiftUI

/// An `NSWindow` this app owns, not SwiftUI's `Settings` scene, which a menu-bar app would have
/// macOS open by itself at launch.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(accounts: AccountStore, client: EWSClient, onChange: @escaping () -> Void) {
        WindowActivation.claim()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(accounts: accounts,
                                                                 client: client,
                                                                 onChange: onChange))
        // Empty on purpose: with `.preferredContentSize` AppKit re-measures the ScrollView
        // mid-layout and aborts (osx-jirabar).
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Mailbar Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: SettingsMetrics.windowWidth, height: 480))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Opens to be read, not typed into.
        window.makeFirstResponder(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
