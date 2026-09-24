import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    /// The unit tests use the app as their TEST_HOST, so this delegate runs for them too. Without
    /// this guard every test run would raise a status item.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "mailbar.status.v1"
        item.button?.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "Mailbar")
        item.button?.image?.isTemplate = true
        statusItem = item
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { false }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
