import AppKit
import SwiftUI

/// A name in the reader's header that opens the person's contact card (M22), the same card the
/// event form's People sidebar opens (`PersonCardView`), anchored to the name. The photo and the
/// directory's entry are read when the card opens and held by it alone, like everywhere else.
struct PersonNameButton: View {
    let name: String
    let address: String
    let accountID: UUID
    let store: MailStore
    var font: Font = .system(size: 11)
    var color: Color = .secondary
    /// The From line's name: the row's room, right-aligned when the name reads right to left,
    /// the button itself only as wide as the name so the card points at it.
    var fillsWidth = false

    @State private var open = false
    @State private var hovering = false

    private var isRightToLeft: Bool { TextDirection.firstStrong(in: name) == .rightToLeft }

    var body: some View {
        if fillsWidth {
            button.frame(maxWidth: .infinity, alignment: isRightToLeft ? .trailing : .leading)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            open.toggle()
        } label: {
            Text(name)
                .font(font)
                .underline(hovering)
                .foregroundStyle(hovering ? Color.primary : color)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(address.isEmpty)
        .onHover { hovering = $0 && !address.isEmpty }
        .help(address)
        .accessibilityHint("Shows the contact card")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ReaderPersonCard(name: name, address: address, accountID: accountID, store: store)
        }
        .task {
            // QC: `--person-card=<address>` with `--open-message` opens this card on its own, once
            // the header has its final height (a popover resized under the card closes both).
            guard QCFlags.openMessage, QCFlags.personCard == address.lowercased() else { return }
            try? await Task.sleep(for: .seconds(3))
            open = true
        }
    }
}

/// `PersonCardView` for a name in a message: the people directory's role, team and department
/// at the top, the Exchange directory's entry below, the photo fetched for this card only.
struct ReaderPersonCard: View {
    let name: String
    let address: String
    let accountID: UUID
    let store: MailStore

    @State private var photo: NSImage?

    var body: some View {
        PersonCardView(name: name, address: address, photo: photo, directoryHeadline: headline) {
            try await store.contactCard(address, accountID: accountID)
        }
        // Opaque, as the popover under it is: the glass let the message show through the card.
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            photo = await store.photo(for: address, accountID: accountID)
            await store.directory.loadIfNeeded()
        }
    }

    private var headline: String {
        let known = store.directory.person(for: address)
        return [known?.role ?? "", known?.team ?? "", known?.department ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// "To: Sara Rahimi, Omid Karimi, +3 more": every name a `PersonNameButton`, wrapping onto more
/// lines when it needs them. A long list shows its first few until "+N more" is clicked.
struct ReaderPeopleLine: View {
    let label: String
    let people: [MessageBody.Person]
    let accountID: UUID
    let store: MailStore

    @State private var expanded = false

    static let collapsedCount = 5

    var body: some View {
        let shown = expanded ? people : Array(people.prefix(Self.collapsedCount))
        let hidden = people.count - shown.count
        ReaderFlowLayout(spacing: 0, lineSpacing: 2) {
            Text("\(label): ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(Array(shown.enumerated()), id: \.offset) { index, person in
                HStack(spacing: 0) {
                    PersonNameButton(name: person.display, address: person.address, accountID: accountID, store: store)
                    if index < shown.count - 1 || hidden > 0 {
                        Text(", ").font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 3)
                    }
                }
            }
            if hidden > 0 {
                Button("+\(hidden) more") { expanded = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }
}

/// Lays its children out left to right, starting a new line when the next does not fit.
struct ReaderFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        // Never wider than offered, and never infinite when asked for its largest size.
        return CGSize(width: min(used, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = fitted(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// A child's natural size, cut to the line's width when it is wider (it then truncates).
    private func fitted(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let size = subview.sizeThatFits(.unspecified)
        guard size.width > width, width.isFinite else { return size }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: size.height))
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = fitted(subviews[index], width: width)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
