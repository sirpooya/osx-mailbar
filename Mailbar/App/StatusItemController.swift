import AppKit
import Observation
import SwiftUI

/// The status item and its popover.
///
/// `NSStatusItem` plus `NSPopover` rather than `MenuBarExtra`, so the panel sits centred under
/// the icon (osx-jirabar's pattern).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: MailStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let onOpenSettings: () -> Void
    private let onRefresh: () -> Void

    init(store: MailStore, onOpenSettings: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        updateIcon()
        observeStore()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidResignActive),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)
    }

    private func configureButton() {
        // A stable autosave name, never AppKit's generic "Item-N": visibility is persisted per
        // slot, and a generic slot can inherit a hidden state from an unrelated build.
        statusItem.autosaveName = "mailbar.status.v1"
        // Not removable by Cmd-dragging it off the bar, which is one way a bundle id ends up on
        // Control Center's blocked list (menubar-fix).
        statusItem.behavior = []
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let root = PopoverRootView(store: store,
                                   onOpenSettings: { [weak self] in self?.openSettings() },
                                   onRefresh: { [weak self] in self?.onRefresh() },
                                   onQuit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: root)
        // The panel grows with its content instead of being pinned to one guessed size.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    // MARK: - Showing

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            popover.isShown ? close() : show()
        }
    }

    func show() {
        guard let button = statusItem.button else { return }
        // Active first. An inactive app's popover draws its material flat grey, which erases the
        // difference between primary and secondary text; and the popover already closes when the
        // app resigns active, so it is only ever meant to be open while active.
        WindowActivation.claim()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover opens behind the frontmost app's windows.
        popover.contentViewController?.view.window?.makeKey()
        // Opening is a check: the list should be current the moment it is looked at.
        onRefresh()
    }

    func close() {
        popover.performClose(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(menuRefresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings...", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mailbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Attached only for this click, or every later left click would open the menu instead.
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { onRefresh() }

    @objc private func menuSettings() { openSettings() }

    private func openSettings() {
        close()
        onOpenSettings()
    }

    @objc private func applicationDidResignActive() {
        close()
    }

    /// Closing the popover closes the message too, so its body and images are released rather
    /// than kept in a hidden view until the next open.
    func popoverDidClose(_ notification: Notification) {
        store.openMessage = nil
        store.pendingArchive = nil
        store.closeSearch()
    }

    // MARK: - Icon

    /// `withObservationTracking` fires once per change, so it re-arms itself.
    private func observeStore() {
        withObservationTracking {
            _ = store.totalUnread
            _ = store.hasProblem
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeStore()
            }
        }
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let count = store.totalUnread
        button.image = StatusItemIcon.image(dimmed: store.hasProblem && count == 0)
        // The count beside the glyph, in the bar's own font with fixed-width digits so 9 turning
        // into 10 does not shuffle the neighbouring icons more than it must.
        if count > 0 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: " \(count)", attributes: [.font: font])
        } else {
            button.title = ""
        }
        let label = accessibilityLabel(count: count)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private func accessibilityLabel(count: Int) -> String {
        if store.accounts.accounts.isEmpty { return "Mailbar: no account yet" }
        let unread = count == 1 ? "1 unread message" : "\(count) unread messages"
        return store.hasProblem ? "Mailbar: \(unread), an account needs attention" : "Mailbar: \(unread)"
    }
}
