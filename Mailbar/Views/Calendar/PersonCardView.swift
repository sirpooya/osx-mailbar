import AppKit
import SwiftUI

/// The contact card an attendee's row opens, after Outlook's. The top holds what the people
/// directory says (photo, role, team, department, under the name); everything the Exchange
/// directory knows (job title, department, company, office, manager, phones, business address)
/// sits below the line, and nowhere else (the user's split). Read when the card opens (`ResolveNames`
/// with full contact data) and held by it alone, like the photos.
struct PersonCardView: View {
    let name: String
    let address: String
    let photo: NSImage?
    /// Role, team and department from the people directory, when it lists the person.
    let directoryHeadline: String
    let load: () async throws -> ContactCard?

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var card: ContactCard?
    @State private var phase: Phase = .loading
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Avatar(name: name, size: 64, photo: photo)
                VStack(alignment: .leading, spacing: 3) {
                    DirectionalText(card?.name.isEmpty == false ? card!.name : name,
                                    font: .system(size: 16, weight: .semibold))
                    if !directoryHeadline.isEmpty {
                        Text(directoryHeadline).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 5) {
                        Text(address).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy the address")
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            details
        }
        .padding(16)
        .frame(width: 330)
        .task {
            do {
                card = try await load()
                phase = .loaded
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking the directory...").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        case .failed(let message):
            Label("Could not read the directory: \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded:
            let lines = rows
            if lines.isEmpty {
                Text("The directory has no details for this person.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text(line.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(line.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    /// What the card lists, in Outlook's order, leaving out what the directory leaves empty.
    private var rows: [(label: String, value: String)] {
        var lines: [(label: String, value: String)] = []
        if let card {
            lines += [("Job title", card.jobTitle), ("Department", card.department), ("Company", card.company),
                      ("Office", card.office), ("Manager", card.manager)]
            lines += card.phones.map { ($0.label, $0.number) }
            lines.append(("Address", card.place))
        }
        return lines.filter { !$0.value.isEmpty }
    }
}
