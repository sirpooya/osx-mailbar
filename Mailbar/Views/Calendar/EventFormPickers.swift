import SwiftUI

/// OWA's Categorize list: every category in the master list with its colour, a check on the ones
/// the event has, and Clear. Stays open so several can be set.
struct CategoryPicker: View {
    let names: [String]
    let chosen: [String]
    let color: (String) -> Color
    /// A name to toggle, or nil to clear them all.
    let toggle: (String?) -> Void

    var body: some View {
        // A category the event has but the list does not know still shows, so it can be removed.
        let all = names + chosen.filter { !names.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(all, id: \.self) { name in
                        Button { toggle(name) } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(color(name)).frame(width: 12, height: 12)
                                DirectionalText(name, font: .system(size: 12.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(chosen.contains(name) ? 1 : 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen.contains(name) ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Clear categories") { toggle(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(chosen.isEmpty ? .tertiary : .primary)
                .disabled(chosen.isEmpty)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .frame(width: 240)
    }
}

/// OWA's Charm grid: None, then the icons seven to a row.
struct CharmPicker: View {
    let chosen: Int?
    let pick: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { pick(nil) } label: {
                Text("None")
                    .font(.system(size: 12, weight: chosen == nil ? .semibold : .regular))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(chosen == nil ? Color.accentColor.opacity(0.15) : .clear))
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 7), spacing: 4) {
                ForEach(EventCharm.allCases) { charm in
                    Button { pick(charm.rawValue) } label: {
                        Image(systemName: charm.symbol)
                            .font(.system(size: 14))
                            .frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(chosen == charm.rawValue ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(charm.label)
                    .accessibilityLabel(charm.label)
                }
            }
        }
        .padding(10)
    }
}

/// The form's right side, after OWA's People pane: a field that suggests people from the
/// company directory and inbox senders as you type, and everyone invited with whether they are
/// free at the event's time. The organizer (this account) is listed first and cannot be removed.
struct PeopleSidebar: View {
    @Bindable var store: CalendarStore
    let draft: EventDraft

    @State private var query = ""
    @State private var suggestions: [(name: String, address: String)] = []
    @State private var highlighted = 0
    @State private var statuses: [String: String] = [:]
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 4) {
                TextField("Add people", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit(addHighlighted)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button(action: addHighlighted) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(fieldFocused ? 0.35 : 0.18)))

            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if let account = store.account {
                            personRow(name: account.fullName.isEmpty ? account.email : account.fullName,
                                      address: account.email, note: "Organizer", removable: nil)
                        }
                        ForEach(draft.people) { person in
                            personRow(name: person.display, address: person.address, note: nil) {
                                store.editor?.people.removeAll { $0 == person }
                            }
                        }
                    }
                }
                if fieldFocused, !suggestions.isEmpty { dropdown }
            }
        }
        .padding(16)
        .task(id: query) {
            let token = query.trimmingCharacters(in: .whitespaces)
            guard token.count >= 2 else { suggestions = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await store.peopleSuggestions(for: token, excluding: draft.attendeeList.joined(separator: ", "))
            guard !Task.isCancelled else { return }
            suggestions = found
            highlighted = 0
        }
        .task(id: availabilityKey) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            var addresses = draft.attendeeList
            if let own = store.account?.email, !own.isEmpty { addresses.insert(own, at: 0) }
            let found = await store.availability(for: addresses, start: draft.requestStart, end: draft.requestEnd)
            guard !Task.isCancelled else { return }
            statuses = found
        }
    }

    /// The people, the time and the length: any change asks the server again.
    private var availabilityKey: String {
        draft.attendeeList.joined(separator: ",") + "|\(draft.requestStart.timeIntervalSince1970)|\(draft.requestEnd.timeIntervalSince1970)"
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.address) { index, person in
                Button { add(name: person.name, address: person.address) } label: {
                    HStack(spacing: 8) {
                        Avatar(name: person.name.isEmpty ? person.address : person.name, size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            DirectionalText(person.name.isEmpty ? person.address : person.name, font: .system(size: 12.5))
                            Text(person.address).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(index == highlighted ? Color.accentColor.opacity(0.15) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(CalendarSurface.background)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func personRow(name: String, address: String, note: String?, removable: (() -> Void)?) -> some View {
        PersonRow(name: name, address: address, note: note, status: statuses[address.lowercased()], onRemove: removable)
    }

    private func personRow(name: String, address: String, note: String?, onRemove: @escaping () -> Void) -> some View {
        personRow(name: name, address: address, note: note, removable: onRemove)
    }

    private func move(_ step: Int) {
        guard !suggestions.isEmpty else { return }
        highlighted = max(0, min(highlighted + step, suggestions.count - 1))
    }

    /// Return picks the highlighted suggestion; with none, whatever was typed, when it is an
    /// address (several, comma separated, are all added).
    private func addHighlighted() {
        if fieldFocused, suggestions.indices.contains(highlighted) {
            let person = suggestions[highlighted]
            add(name: person.name, address: person.address)
            return
        }
        let typed = Recipients.parse(query).filter(Recipients.isValid)
        guard !typed.isEmpty else { return }
        for address in typed { add(name: "", address: address) }
    }

    private func add(name: String, address: String) {
        let person = EventDraft.Invitee(name: name, address: address)
        if store.editor?.people.contains(where: { $0.id == person.id }) == false {
            store.editor?.people.append(person)
        }
        query = ""
        suggestions = []
        fieldFocused = true
    }
}

/// One person in the sidebar: initials, name, and free or busy at the event's time.
private struct PersonRow: View {
    let name: String
    let address: String
    let note: String?
    let status: String?
    let onRemove: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: name, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                DirectionalText(name, font: .system(size: 13))
                HStack(spacing: 4) {
                    if let status, let label = Self.label(status) {
                        Circle().fill(Self.color(status)).frame(width: 6, height: 6)
                        Text(label)
                    }
                    if let note { Text(status == nil ? note : "· \(note)") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onRemove, hovering {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove \(name)")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(address)
    }

    static func label(_ status: String) -> String? {
        switch status {
        case "Free": return "Free"
        case "Tentative": return "Tentative"
        case "Busy": return "Busy"
        case "OOF": return "Away"
        case "WorkingElsewhere": return "Working elsewhere"
        case "NoData": return "No information"
        default: return nil
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "Free": return .green
        case "Tentative": return .orange
        case "Busy": return .red
        case "OOF": return .purple
        case "WorkingElsewhere": return .teal
        default: return .gray
        }
    }
}

/// A neutral circle with the person's initials.
private struct Avatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "@" })
        let initials = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        Circle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.secondary))
            .accessibilityHidden(true)
    }
}
