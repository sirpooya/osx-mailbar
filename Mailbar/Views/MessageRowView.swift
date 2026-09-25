import SwiftUI

/// One inbox row, laid out like Outlook's message list:
///
///     ● Sender                                   (bold while unread)
///       Subject ......................  ⚑ 📎 Yesterday
///       One line of preview
///
/// Every text line takes its direction from its own first strong character, so a Persian subject
/// starts at the right and truncates at its left end while the time stays on the right, which is
/// what Outlook does with the same mail.
struct MessageRowView: View {
    let message: MailMessage
    let accountID: UUID
    @Bindable var store: MailStore
    let onOpen: () -> Void

    @State private var isHovering: Bool

    init(message: MailMessage, accountID: UUID, store: MailStore,
         startsHovered: Bool = false, onOpen: @escaping () -> Void) {
        self.message = message
        self.accountID = accountID
        self.store = store
        self.onOpen = onOpen
        _isHovering = State(initialValue: startsHovered)
    }

    /// Shared with `SkeletonListView`, which draws the same three lines at the same pitch so a
    /// row does not jump when the real one replaces the placeholder.
    enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 8
        static let lineSpacing: CGFloat = 2
        static let dotColumn: CGFloat = 8
    }

    var body: some View {
        Button(action: onOpen) { rowContent }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            // The four actions at the row's trailing edge while the pointer is on it, the way
            // Outlook shows them: over the subject line, so the time on the sender line never hides.
            .overlay(alignment: .trailing) {
                if isHovering {
                    MessageActionButtons(message: message, accountID: accountID, store: store, size: 11)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(.trailing, Metrics.horizontalPadding - 4)
                }
            }
            .contextMenu { contextMenu }
            .help(message.received.formatted(date: .complete, time: .shortened))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(message.isRead ? "Mark as Unread" : "Mark as Read") {
            Task { await store.setRead(!message.isRead, message: message.id, in: accountID) }
        }
        Button(message.isFlagged ? "Clear Flag" : "Flag") {
            Task { await store.setFlag(!message.isFlagged, message: message.id, in: accountID) }
        }
        Divider()
        Button("Archive") {
            Task { await store.archive(message: message.id, in: accountID) }
        }
        Button("Delete") {
            Task { await store.delete(message: message.id, in: accountID) }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            unreadDot

            VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
                // The time sits in front of the sender, on line 1 (the user's call, 2026-09-25).
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    DirectionalText(message.senderName,
                                    font: .system(size: 13, weight: message.isRead ? .regular : .semibold))
                        .foregroundStyle(.primary)
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    receivedTime
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    DirectionalText(message.subject,
                                    font: .system(size: 12, weight: message.isRead ? .regular : .medium),
                                    pinnedLeading: true)
                        .foregroundStyle(.primary)
                    trailingMarks
                }

                if !message.preview.isEmpty {
                    DirectionalText(message.preview, font: .system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
        .contentShape(Rectangle())
    }

    /// Outlook's unread marker. The column is always reserved, so read and unread rows keep their
    /// text on the same left edge.
    private var unreadDot: some View {
        Circle()
            .fill(message.isRead ? Color.clear : Color.accentColor)
            .frame(width: 7, height: 7)
            .frame(width: Metrics.dotColumn)
    }

    private var trailingMarks: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if message.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .fixedSize()
    }

    /// Never squeezed: the sender gives way, the time does not.
    private var receivedTime: some View {
        Text(RelativeTime.label(for: message.received))
            .font(.system(size: 11, weight: message.isRead ? .regular : .medium))
            .monospacedDigit()
            .foregroundStyle(message.isRead ? Color.secondary : Color.accentColor)
            .lineLimit(1)
            .fixedSize()
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        if !message.isRead { parts.append("Unread") }
        if message.isFlagged { parts.append("Flagged") }
        parts.append("from \(message.senderName)")
        parts.append(message.subject)
        parts.append(RelativeTime.label(for: message.received))
        if message.hasAttachments { parts.append("has attachments") }
        return parts.joined(separator: ", ")
    }
}

/// One line of text placed on the side its own content implies.
///
/// Right-to-left text is pinned to the trailing edge with a plain frame alignment. It is NOT done
/// with `.environment(\.layoutDirection, .rightToLeft)`: that also flips the view's leading
/// alignment guide, and the row's stacks line their children up by that guide, so one Persian line
/// dragged its neighbours across (measured 2026-09-24: the time jumped to the left edge on a row
/// whose sender and subject were both Persian). The text itself needs no help: its paragraph
/// direction comes from its first strong character, so a Persian line still reads right to left
/// and still truncates at its left end.
struct DirectionalText: View {
    let text: String
    let font: Font
    /// One line everywhere in the mail list; calendar blocks let a title wrap when there is room.
    var lines: Int = 1
    /// Keeps the line at the leading edge even when it reads right to left: the inbox subject
    /// starts where every other subject starts (the user's call, 2026-09-25), the words still in
    /// Persian order.
    var pinnedLeading = false

    init(_ text: String, font: Font, lines: Int = 1, pinnedLeading: Bool = false) {
        self.text = text
        self.font = font
        self.lines = lines
        self.pinnedLeading = pinnedLeading
    }

    private var isRightToLeft: Bool {
        TextDirection.firstStrong(in: text) == .rightToLeft
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(lines)
            .truncationMode(.tail)
            .multilineTextAlignment(isRightToLeft && !pinnedLeading ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isRightToLeft && !pinnedLeading ? .trailing : .leading)
    }
}
