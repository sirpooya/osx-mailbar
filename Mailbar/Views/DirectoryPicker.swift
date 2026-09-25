import AppKit
import SwiftUI

/// Add a team or department: people from the directory in Settings, narrowed by department and
/// team, each with a tick, added together. Shared by the event form's People and the mail
/// composer's To and Cc. Photos are fetched as rows appear and held by this view alone.
struct DirectoryPicker: View {
    let directory: PeopleDirectory
    /// Addresses already added: shown as added and never added twice.
    let already: Set<String>
    let onAdd: ([DirectoryPerson]) -> Void

    @State private var department: String?
    @State private var team: String?
    @State private var chosen: Set<String> = []
    @State private var photos: [String: NSImage] = [:]

    private var shown: [DirectoryPerson] {
        directory.people.filter {
            (department == nil || $0.department == department) && (team == nil || $0.team == team)
        }
    }

    private var addable: [DirectoryPerson] { shown.filter { !already.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a team or department").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                PopUpMenu(items: [.init(id: "", title: "All departments")]
                            + directory.departments.map { .init(id: $0, title: $0, separatorBefore: $0 == directory.departments.first) },
                          selected: department ?? "", width: 150) { id in
                    department = id.isEmpty ? nil : id
                    if let team, !directory.teams(in: department).contains(team) { self.team = nil }
                    chooseShown()
                }
                PopUpMenu(items: [.init(id: "", title: "All teams")]
                            + directory.teams(in: department).map { .init(id: $0, title: $0, separatorBefore: $0 == directory.teams(in: department).first) },
                          selected: team ?? "", width: 150) { id in
                    team = id.isEmpty ? nil : id
                    chooseShown()
                }
            }
            content
            Divider()
            HStack {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(chosen.count == 1 ? "Add 1 Person" : "Add \(chosen.count) People") {
                    onAdd(addable.filter { chosen.contains($0.id) })
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(chosen.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .task { await directory.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch directory.phase {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await directory.load() } }.controlSize(.small)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        case .idle, .loading where directory.people.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the directory...").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 80)
        default:
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !addable.isEmpty {
                Button {
                    chosen = chosen.count == addable.count ? [] : Set(addable.map(\.id))
                } label: {
                    HStack(spacing: 8) {
                        tick(chosen.count == addable.count ? "checkmark.square.fill" : chosen.isEmpty ? "square" : "minus.square.fill",
                             on: !chosen.isEmpty)
                        Text("Everyone shown").font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { person in row(person) }
                }
            }
            .frame(height: 260)
        }
    }

    private func row(_ person: DirectoryPerson) -> some View {
        let added = already.contains(person.id)
        let on = added || chosen.contains(person.id)
        return Button {
            if chosen.contains(person.id) { chosen.remove(person.id) } else { chosen.insert(person.id) }
        } label: {
            HStack(spacing: 8) {
                tick(on ? "checkmark.square.fill" : "square", on: on)
                Avatar(name: person.name.isEmpty ? person.address : person.name, size: 26, photo: photos[person.id])
                VStack(alignment: .leading, spacing: 0) {
                    DirectionalText(person.name.isEmpty ? person.address : person.name, font: .system(size: 12.5))
                    Text(added ? "Already added" : [person.role, person.team].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .opacity(added ? 0.55 : 1)
        .help(person.address)
        .task(id: person.id) {
            guard photos[person.id] == nil, person.avatar != nil else { return }
            if let image = await directory.avatar(for: person.address) { photos[person.id] = image }
        }
    }

    private func tick(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
    }

    private var summary: String {
        let count = shown.count
        return count == 1 ? "1 person" : "\(count) people"
    }

    /// Narrowing to a team or department ticks everyone in it; back to everyone ticks nobody,
    /// so the whole company is never one click away.
    private func chooseShown() {
        chosen = department == nil && team == nil ? [] : Set(addable.map(\.id))
    }
}
