import SwiftUI

// MARK: - SettingsComponents: the shared vocabulary of every osx-* settings window.
//
// Canonical copy, assembled from three project copies of the same file:
//   - osx-download-manager/Sources/DownloadManagerApp/SettingsComponents.swift
//     The base. Newest pass (settings rebuilt 2026-08-21): SettingsSection, subtitle rows,
//     SettingsBlock, SettingsCardActions, named cardCorner and bodyHPadding metrics.
//   - osx-autoconnect/Sources/AutoConnect/Views/SettingsComponents.swift
//     SettingsFieldRow, the four-tab window size (460 x 450), the monospaced column width.
//   - osx-launchpad/LaunchpadX/Settings/SettingsComponents.swift
//     The original LaunchOS-derived card look: labelColor 0.05 fill, continuous corners.
// Where the copies disagreed the download-manager values won, except the divider inset, which
// is both edges as in autoconnect and launchpad. The full list is in settings-ui.md, "Drift".
//
// Every pane is built from four pieces: a section HEADER, a rounded CARD of rows, hairline
// DIVIDERS between those rows, and an optional FOOTNOTE under the card. Controls go in the
// row's TRAILING slot, never in a control's own label. `Toggle("Label", isOn:)` draws its own
// label and lands the switch wherever that text ends, which is the ragged look this replaces.

enum SettingsMetrics {
    /// Row inset. Section headers and footnotes use the same value plus the body padding, so a
    /// header's first letter sits directly above its row's first letter.
    static let rowHPadding: CGFloat = 14
    static let rowHeight: CGFloat = 34
    static let cardCorner: CGFloat = 10
    static let bodyHPadding: CGFloat = 20
    /// Four tabs of icon-over-label buttons. download-manager needs 592 x 620 for eight tabs.
    static let windowWidth: CGFloat = 460
    /// Fixed, so switching tabs never resizes the window under the pointer. Panes scroll.
    static let windowHeight: CGFloat = 450
    /// The tab bar's height, enforced on it rather than left to its contents. A pane that needs
    /// to know its real room cannot ask: `GeometryReader` over-reports by 16pt. The one
    /// trustworthy figure is `windowHeight - tabBarHeight - 1` (the divider).
    static let tabBarHeight: CGFloat = 54
    /// The standard width for a trailing text field or pop-up, so a column of them lines up.
    static let controlWidth: CGFloat = 220
    /// Monospaced values (a 40-character SHA1, a binary path) are longer than any label, so they
    /// get a smaller face and this wider column.
    static let monospacedControlWidth: CGFloat = 290
}

extension Color {
    /// The card fill: built on semantic `labelColor` rather than a fixed white or black alpha,
    /// so it tracks light/dark and the "increase contrast" accessibility setting.
    static let settingsCardFill = Color(nsColor: .labelColor).opacity(0.05)
}

/// A grouped rounded container. Children stack vertically; put `SettingsDivider` between rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                // `.continuous` for the squircle curve, which reads as a macOS grouped box
                // rather than a rounded rectangle drawn by hand.
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCorner, style: .continuous)
                    .fill(Color.settingsCardFill)
            )
    }
}

/// Hairline between two rows, inset on both edges so it floats inside the card.
struct SettingsDivider: View {
    var body: some View {
        // A plain rectangle rather than `Divider()`, whose system separator draws at its own
        // weight and cannot be lightened to sit quietly inside a translucent card.
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, SettingsMetrics.rowHPadding)
    }
}

/// One row: leading title (with optional explanatory subtitle), trailing control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .firstTextBaseline : .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A subtitled row's title column keeps its width even when the trailing control is
            // wide, or the caption wraps to five lines.
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, SettingsMetrics.rowHPadding)
        .padding(.vertical, subtitle == nil ? 0 : 9)
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

/// A row whose trailing control is a text field, right aligned so the values line up in a
/// column down the card.
struct SettingsFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var secure = false

    var body: some View {
        SettingsRow(title) {
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(monospaced ? .system(size: 10, design: .monospaced) : .system(size: 13))
            .frame(maxWidth: monospaced
                ? SettingsMetrics.monospacedControlWidth
                : SettingsMetrics.controlWidth)
        }
    }
}

/// A row that is entirely one control (a grid, a rule editor) rather than title plus value.
struct SettingsBlock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, SettingsMetrics.rowHPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one unlabelled switch every toggle row uses, so thirty of them cannot drift into three
/// sizes.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

/// A bold section header above a card.
struct SettingsSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Aligns with the row TITLE inside the card, not with the card's left edge.
            .padding(.leading, SettingsMetrics.rowHPadding)
    }
}

/// Explanatory text under a card. Tint it (`.orange`) for a warning the user should act on.
struct SettingsFootnote: View {
    let text: String
    var tint: Color?

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint ?? .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.rowHPadding)
    }
}

/// Header + card + footnote in one piece, which is what almost every group in every pane is.
struct SettingsSection<Content: View>: View {
    let title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil,
         footnote: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { SettingsSectionHeader(text: title) }
            SettingsCard { content }
            if let footnote { SettingsFootnote(footnote) }
        }
    }
}

/// Buttons that sit loose under a card ("Add Rule", "Add Index"), indented to the row inset so
/// they read as belonging to the card above rather than to the window.
struct SettingsCardActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, SettingsMetrics.rowHPadding)
        .padding(.top, 2)
    }
}

/// The scrolling body every pane shares, so their padding and section rhythm match.
struct SettingsTabBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.bodyHPadding)
                .padding(.vertical, 16)
        }
    }
}
