import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var accounts: AccountStore!
    private var client: EWSClient!
    private var store: MailStore!
    private var poller: Poller!
    private var streamer: MailStreamer!
    private var statusItemController: StatusItemController!
    private let notifications = NotificationService()
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

        store = MailStore(accounts: accounts, client: client)
        notifications.configure()
        store.onNewMail = { [weak self] account, messages in
            let defaults = UserDefaults.standard
            guard let self, defaults.bool(forKey: Keys.notifyNewMail) else { return }
            self.notifications.notify(messages, account: account,
                                      showDetails: defaults.bool(forKey: Keys.notificationDetails))
        }
        store.onUnreadChanged = { [weak self] unread in
            self?.notifications.withdraw(except: unread)
        }
        statusItemController = StatusItemController(
            store: store,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onRefresh: { [weak self] in self?.poller.refreshNow() })

        // Streaming (M11) brings changes the moment they happen; while it covers every account,
        // polling only guards against a subscription that died without the connection noticing.
        streamer = MailStreamer(store: store, onChange: { [weak self] in self?.poller.refreshNow() })
        poller = Poller(intervalProvider: { [weak self] in
                            guard let self, self.streamer.coversAllAccounts else { return Keys.pollInterval() }
                            return max(Keys.pollInterval(), MailStreamer.fallbackPollInterval)
                        },
                        action: { [weak self] in
                            guard let self else { return false }
                            // Unstructured on purpose. `refreshNow` (every popover open) restarts
                            // the poller's loop by cancelling it, and that cancellation used to
                            // reach the requests in flight and surface as "Something went wrong".
                            // A detached-from-cancellation Task lets the poll that is already
                            // running finish; the restarted loop then finds it still refreshing
                            // and simply uses its result.
                            let store = self.store!
                            return await Task { await store.refresh() }.value
                        })
        poller.start()
        // After the launch poll has had a moment, so the first stream does not race it for the
        // server version.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.streamer.start() }

        // Asked once an account exists, never at a bare first launch (osx-jirabar's rule).
        if !accounts.accounts.isEmpty, MockMode.current == nil {
            Task { await notifications.requestAuthorizationIfNeeded() }
        }
        notifications.onOpenMessage = { [weak self] account, message in
            guard let self else { return }
            self.store.closeSearch()
            self.store.selectedAccountID = account
            self.store.openMessage = .init(accountID: account, messageID: message)
            self.statusItemController.show()
        }
        Attachments.clearOpenedCopies()

        installMainMenu()
        installEditingShortcuts()
        observeSleepAndWake()

        if accounts.accounts.isEmpty || QCFlags.openSettings {
            showSettings()
        } else if QCFlags.openPopover {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusItemController.show()
            }
            if let text = QCFlags.searchText {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.store.isSearchOpen = true
                    self?.store.searchQuery = text
                }
            }
            if QCFlags.openMessage {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, let account = self.store.selectedAccount,
                          let index = QCFlags.openMessageIndex else { return }
                    let messages = self.store.state(for: account.id).messages
                    guard messages.indices.contains(index) else { return }
                    self.store.openMessage = .init(accountID: account.id, messageID: messages[index].id)
                }
            }
        }
    }

    private func showSettings() {
        // An account added, edited or deleted, or a new interval, all mean "check now".
        SettingsWindow.shared.show(accounts: accounts, client: client,
                                   onChange: { [weak self] in
                                       guard let self else { return }
                                       self.poller.refreshNow()
                                       self.streamer.restartAll()
                                       if !self.accounts.accounts.isEmpty, MockMode.current == nil {
                                           Task { await self.notifications.requestAuthorizationIfNeeded() }
                                       }
                                   })
    }

    // MARK: - Sleep and wake

    /// Polling stops for the sleep and does exactly one refresh on wake, rather than firing every
    /// tick that was missed.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poller.pauseForSleep()
                self?.streamer.stopLoops()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poller.resumeFromWake()
                self?.streamer.sync()
            }
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        Attachments.clearOpenedCopies()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { false }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
