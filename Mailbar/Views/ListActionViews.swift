import AppKit
import SwiftUI

// The views of M20 (list actions) and M21 (junk and folders): the undo toast, the bar for a
// multi-row selection, the swipe settings, the reader's Unsubscribe button and the folder
// menus. The popover and the row place them; the store does the work.

/// "Archived. Undo" at the popover's foot for five seconds after mail moved (M20).
struct UndoToastView: View {
    let toast: UndoToast
    @Bindable var store: MailStore

    var body: some View {
        HStack(spacing: 10) {
            Text(toast.text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            if toast.undo != nil {
                Button("Undo") { Task { await store.undo(toast) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.76, blue: 1.0))
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo  ⌘Z")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(white: 0.16).opacity(0.94)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}

/// The bar that replaces the footer while two or more rows are selected (M20): the count, the
/// five actions on all of them at once, and Cancel (or Escape).
struct SelectionBar: View {
    let ids: [String]
    let accountID: UUID
    let folder: MailFolder
    @Bindable var store: MailStore

    private var messages: [MailMessage] { ids.compactMap { store.message($0, in: accountID) } }

    var body: some View {
        let rows = messages
        let allRead = rows.allSatisfy(\.isRead)
        let allFlagged = !rows.isEmpty && rows.allSatisfy(\.isFlagged)
        HStack(spacing: 12) {
            Text("\(ids.count) selected")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Spacer(minLength: 4)
            action(allRead ? "envelope.badge" : "envelope.open",
                   help: allRead ? "Mark as Unread" : "Mark as Read") {
                await store.setRead(!allRead, ids: ids, in: accountID)
            }
            action(allFlagged ? "flag.slash" : "flag", help: allFlagged ? "Clear Flag" : "Flag") {
                await store.setFlag(!allFlagged, ids: ids, in: accountID)
            }
            if folder.canArchive {
                action("archivebox", help: "Archive") {
                    store.listActions.clearSelection()
                    await store.archive(ids, in: accountID)
                }
            }
            if folder.canDelete {
                action("trash", help: "Delete (moves to Deleted Items)") {
                    store.listActions.clearSelection()
                    await store.delete(ids, in: accountID)
                }
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
            Button("Cancel") { store.listActions.clearSelection() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .keyboardShortcut(.cancelAction)
                .help("Clear the selection  esc")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.accentColor.opacity(0.08))
    }

    private func action(_ symbol: String, help: String, run: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await run() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The colour and glyph a row shows under itself while it is swiped (M20).
struct SwipeReveal: View {
    let action: SwipeAction
    let message: MailMessage
    /// Positive when the row slid right, so the glyph sits at the left edge.
    let offset: CGFloat

    static let threshold: CGFloat = 70

    var body: some View {
        let armed = abs(offset) >= Self.threshold
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Self.color(action).opacity(armed ? 1 : 0.55))
            .overlay(alignment: offset > 0 ? .leading : .trailing) {
                Image(systemName: action.symbol(for: message))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(armed ? 1.1 : 0.9)
                    .padding(.horizontal, 18)
            }
            .animation(.snappy(duration: 0.15), value: armed)
    }

    static func color(_ action: SwipeAction) -> Color {
        switch action {
        case .none: .clear
        case .archive: .green
        case .delete: .red
        case .toggleRead: .blue
        case .flag: .orange
        }
    }
}

/// Settings, General: what a swipe each way across a row does (M20).
struct SwipeSettingsSection: View {
    @AppStorage(Keys.swipeLeft) private var left = SwipeAction.leftDefault.rawValue
    @AppStorage(Keys.swipeRight) private var right = SwipeAction.rightDefault.rawValue

    var body: some View {
        SettingsSection("Swipe", footnote: "Two fingers across a row in the list.") {
            SettingsRow("Swipe left") { picker($left) }
            SettingsRow("Swipe right") { picker($right) }
        }
    }

    private func picker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(SwipeAction.allCases) { action in
                Text(action.title).tag(action.rawValue)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

/// The reader's Unsubscribe button: shown only when the open message carries a
/// `List-Unsubscribe` header, which the popover looks up as the message opens (M20). Asks
/// before acting.
struct UnsubscribeButton: View {
    let messageID: String
    let accountID: UUID
    @Bindable var store: MailStore

    var body: some View {
        if store.listActions.unsubscribeLinks[messageID]?.preferred != nil {
            Button {
                Task { await store.askToUnsubscribe(message: messageID, in: accountID) }
            } label: {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unsubscribe...")
            .accessibilityLabel("Unsubscribe")
        }
    }
}

/// The folder tree as menu items, indented by level (M21). `exclude` leaves the folder showing
/// out of a "Move to" list.
struct FolderTreeItems: View {
    let folders: [MailboxFolder]
    var exclude: MailFolder? = nil
    var checked: MailFolder? = nil
    let pick: (MailboxFolder) -> Void

    var body: some View {
        ForEach(folders.filter { exclude == nil || $0.mailFolder != exclude }) { folder in
            Button {
                pick(folder)
            } label: {
                let indent = String(repeating: "\u{2003}", count: folder.depth)
                Label(indent + folder.name,
                      systemImage: checked == folder.mailFolder ? "checkmark" : Self.symbol(folder))
            }
        }
    }

    static func symbol(_ folder: MailboxFolder) -> String {
        switch folder.wellKnown {
        case "inbox": "tray"
        case "sentitems": "paperplane"
        case "archive": "archivebox"
        case "deleteditems": "trash"
        case "junkemail": "xmark.bin"
        default: "folder"
        }
    }
}
