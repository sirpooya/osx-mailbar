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

    @State private var isHovering = false

    /// Shared with `SkeletonListView`, which draws the same three lines at the same pitch so a
    /// row does not jump when the real one replaces the placeholder.
    enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 8
        static let lineSpacing: CGFloat = 2
        static let dotColumn: CGFloat = 8
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            unreadDot

            VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
                DirectionalText(message.senderName,
                                font: .system(size: 13, weight: message.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    DirectionalText(message.subject,
                                    font: .system(size: 12, weight: message.isRead ? .regular : .medium))
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
        .onHover { isHovering = $0 }
        .help(message.received.formatted(date: .complete, time: .shortened))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
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
            if message.hasAttachments {
                Image(systemName: "paperclip")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if message.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
            Text(RelativeTime.label(for: message.received))
                .font(.system(size: 11, weight: message.isRead ? .regular : .medium))
                .monospacedDigit()
                .foregroundStyle(message.isRead ? Color.secondary : Color.accentColor)
                .lineLimit(1)
        }
        // Never squeezed: the subject gives way, the time does not.
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

    init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    private var isRightToLeft: Bool {
        TextDirection.firstStrong(in: text) == .rightToLeft
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isRightToLeft ? .trailing : .leading)
    }
}
