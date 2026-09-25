import AppKit
import SwiftUI

/// An `NSWindow` this app owns, not SwiftUI's `Settings` scene, which a menu-bar app would have
/// macOS open by itself at launch.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(accounts: AccountStore, client: EWSClient, directory: PeopleDirectory, onChange: @escaping () -> Void) {
        WindowActivation.claim()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(accounts: accounts,
                                                                 client: client,
                                                                 directory: directory,
                                                                 onChange: onChange))
        // Empty on purpose: with `.preferredContentSize` AppKit re-measures the ScrollView
        // mid-layout and aborts (osx-jirabar).
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Mailbar Settings"
        // The top after osx-launchpad's Settings (the user's pick): no title strip, the close
        // button floating over the content and the tabs straight under it.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: SettingsMetrics.windowWidth,
                                     height: QCFlags.settingsHeight ?? 480 + SettingsMetrics.tabBarHeight + 28))
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
