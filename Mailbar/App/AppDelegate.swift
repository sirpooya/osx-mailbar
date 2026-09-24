import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var accounts: AccountStore!
    private var client: EWSClient!
    private var statusItem: NSStatusItem?
    private var editingShortcutMonitor: Any?

    /// The unit tests use the app as their TEST_HOST, so this delegate runs for them too. Without
    /// this guard every test run would raise a status item and open Settings.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        // First, always: anything whose default is not 0 or false must be registered before
        // anything reads it.
        Keys.registerDefaults()

        if let mock = MockMode.current {
            accounts = AccountStore(inMemory: MockMode.accounts, passwords: MockMode.passwords)
            client = EWSClient(transport: MockTransport(mode: mock))
        } else {
            accounts = AccountStore()
            client = EWSClient()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "mailbar.status.v1"
        item.button?.image = StatusItemIcon.image(dimmed: false)
        item.button?.target = self
        item.button?.action = #selector(showSettings)
        statusItem = item

        installMainMenu()
        installEditingShortcuts()

        if accounts.accounts.isEmpty || QCFlags.openSettings { showSettings() }
    }

    @objc private func showSettings() {
        SettingsWindow.shared.show(accounts: accounts, client: client, onChange: {})
    }

    // MARK: - Main menu and editing shortcuts

    /// Never seen. An accessory app still routes Cmd+Q and the editing shortcuts through a main
    /// menu, so one has to exist.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Mailbar",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// Delivers Cmd+V and friends to the focused field. osx-jirabar found the menu above is not
    /// enough on its own: with a `MenuBarExtra` as the only scene, SwiftUI owns the main menu and
    /// replaces it, so pasting a password into Settings did nothing. A local key monitor sees the
    /// key first. Matched by key code, never by character, so it keeps working on the Persian
    /// layout (see `EditingShortcut`).
    private func installEditingShortcuts() {
        editingShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command || flags == [.command, .shift],
                  let shortcut = EditingShortcut.match(keyCode: event.keyCode,
                                                       command: flags.contains(.command),
                                                       shift: flags.contains(.shift)),
                  let responder = event.window?.firstResponder
                      ?? NSApp.keyWindow?.firstResponder else { return event }

            let action = NSSelectorFromString(shortcut.selectorName)
            if responder.responds(to: action) {
                NSApp.sendAction(action, to: responder, from: nil)
                return nil
            }
            if let undo = responder.undoManager {
                if shortcut == .undo, undo.canUndo { undo.undo(); return nil }
                if shortcut == .redo, undo.canRedo { undo.redo(); return nil }
            }
            return event
        }
    }

    // MARK: - Menu-bar app lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { false }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
