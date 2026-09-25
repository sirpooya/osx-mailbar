import AppKit
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
/// A distribution group shows as a group with Expand, which puts its members in its place; with
/// a people directory in Settings, the button beside the field adds a whole team or department.
struct PeopleSidebar: View {
    @Bindable var store: CalendarStore
    let draft: EventDraft

    @State private var query = QCFlags.calendarPeople ?? ""
    @State private var suggestions: [PersonSuggestion] = []
    @State private var highlighted = 0
    @State private var statuses: [String: String] = [:]
    /// Photos by lowercased address, held only while the form is open.
    @State private var photos: [String: NSImage] = [:]
    @State private var photoAsked: Set<String> = []
    @State private var optionsOpen = false
    @State private var directoryOpen = QCFlags.directoryPicker
    /// Groups being expanded, and why the last one could not be.
    @State private var expanding: Set<String> = []
    @State private var expandProblem: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("People").font(.system(size: 17, weight: .semibold)).allowsHitTesting(false)
                Spacer()
                responseOptions
            }
            HStack(spacing: 4) {
                TextField("Add people", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit(addHighlighted)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                // No plus button (the user's call: Return and a click on a suggestion add).
                if store.mail.directory.isConfigured { directoryButton }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(fieldFocused ? 0.35 : 0.18)))
            if let expandProblem {
                Label(expandProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack(alignment: .top) {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if let account = store.account {
                                personRow(name: account.fullName.isEmpty ? account.email : account.fullName,
                                          address: account.email, note: "Organizer", removable: nil)
                            }
                            ForEach(draft.people) { person in
                                personRow(person)
                            }
                        }
                        // The whole height, so a click under the list also ends editing.
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                        .background(EndEditingArea())
                    }
                }
                if fieldFocused, !suggestions.isEmpty { dropdown }
            }
        }
        .padding(16)
        .background(EndEditingArea())
        .task { if QCFlags.calendarPeople != nil { try? await Task.sleep(nanoseconds: 800_000_000); fieldFocused = true } }
        .task(id: query) {
            let token = query.trimmingCharacters(in: .whitespaces)
            guard token.count >= 2 else { suggestions = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await store.peopleSuggestions(for: token, excluding: draft.attendeeList.joined(separator: ", "))
            guard !Task.isCancelled else { return }
            suggestions = found
            highlighted = 0
            // Photos for the suggestions too, as OWA shows them, all at once rather than one by one.
            let wanted = found.map { $0.address.lowercased() }.filter { !photoAsked.contains($0) }
            photoAsked.formUnion(wanted)
            await withTaskGroup(of: (String, NSImage?).self) { group in
                for address in wanted { group.addTask { (address, await store.photo(for: address)) } }
                for await (address, image) in group { if let image { photos[address] = image } }
            }
        }
        .task(id: draft.attendeeList.joined(separator: ",")) {
            // Which of them are groups, for the Expand button; the server is asked once each.
            await store.mail.checkGroups(draft.attendeeList, accountID: store.account?.id)
            var addresses = draft.attendeeList
            if let own = store.account?.email, !own.isEmpty { addresses.insert(own, at: 0) }
            for address in addresses.map({ $0.lowercased() }) where !photoAsked.contains(address) {
                photoAsked.insert(address)
                if let image = await store.photo(for: address) { photos[address] = image }
            }
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

    /// OWA's gear beside People, in secondary grey (the user's call: lighter than the text): a
    /// plain button, because a menu button ignores the colour of its icon. It opens Response options, Request
    /// responses and Allow forwarding.
    private var responseOptions: some View {
        Button { optionsOpen.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Response options")
        .popover(isPresented: $optionsOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Response options").font(.system(size: 12, weight: .semibold))
                Toggle("Request responses", isOn: Binding(get: { draft.requestResponses },
                                                          set: { store.editor?.requestResponses = $0 }))
                Toggle("Allow forwarding", isOn: Binding(get: { draft.allowForwarding },
                                                         set: { store.editor?.allowForwarding = $0 }))
            }
            .toggleStyle(.checkbox)
            .padding(14)
        }
    }

    /// The people, the time and the length: any change asks the server again.
    private var availabilityKey: String {
        draft.attendeeList.joined(separator: ",") + "|\(draft.requestStart.timeIntervalSince1970)|\(draft.requestEnd.timeIntervalSince1970)"
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, person in
                Button { add(name: person.name, address: person.address) } label: {
                    HStack(spacing: 8) {
                        Avatar(name: person.display, size: 26, photo: photos[person.id], isGroup: person.isGroup)
                        VStack(alignment: .leading, spacing: 0) {
                            DirectionalText(person.display, font: .system(size: 12.5))
                            Text(((person.isGroup ? ["Group"] : [person.detail]) + [person.address])
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
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
        PersonRow(name: name, address: address, note: note, status: statuses[address.lowercased()],
                  photo: photos[address.lowercased()], onRemove: removable)
    }

    /// An invitee, or a group with Expand (a group has no free or busy of its own).
    private func personRow(_ person: EventDraft.Invitee) -> some View {
        let group = store.mail.isGroup(person.address)
        return PersonRow(name: group ? store.mail.groupName(person.address) ?? person.display : person.display,
                         address: person.address, note: group ? "Group" : nil,
                         status: group ? nil : statuses[person.id], photo: group ? nil : photos[person.id],
                         isGroup: group, isExpanding: expanding.contains(person.id),
                         onExpand: group ? { Task { await expand(person) } } : nil,
                         onRemove: { store.editor?.people.removeAll { $0 == person } })
    }

    private var directoryButton: some View {
        Button { directoryOpen.toggle() } label: { Image(systemName: "person.3") }
            .buttonStyle(.borderless)
            .help("Add a team")
            .popover(isPresented: $directoryOpen, arrowEdge: .bottom) {
                DirectoryPicker(directory: store.mail.directory,
                                already: Set(draft.attendeeList.map { $0.lowercased() } + [store.account?.email.lowercased() ?? ""])) { people in
                    for person in people { append(name: person.name, address: person.address) }
                    directoryOpen = false
                }
            }
    }

    /// The group's members in its place, each once, never the organizer. A group inside it
    /// stays a group, to expand in turn.
    private func expand(_ group: EventDraft.Invitee) async {
        expanding.insert(group.id)
        defer { expanding.remove(group.id) }
        let name = store.mail.groupName(group.address) ?? group.display
        do {
            let result = try await store.mail.expandGroup(group.address, accountID: store.account?.id)
            guard var people = store.editor?.people, let index = people.firstIndex(of: group) else { return }
            guard !result.members.isEmpty else {
                expandProblem = "The server lists no members for \(name)."
                return
            }
            var seen = Set(people.map(\.id) + [store.account?.email.lowercased() ?? ""])
            let members = result.members.filter { seen.insert($0.id).inserted }
                .map { EventDraft.Invitee(name: $0.name, address: $0.address) }
            people.replaceSubrange(index...index, with: members)
            store.editor?.people = people
            expandProblem = result.complete ? nil : "The server listed only some of \(name)'s members."
        } catch {
            expandProblem = "Could not expand \(name): \(error.localizedDescription)"
        }
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
        append(name: name, address: address)
        query = ""
        suggestions = []
        fieldFocused = true
    }

    private func append(name: String, address: String) {
        let person = EventDraft.Invitee(name: name, address: address)
        if store.editor?.people.contains(where: { $0.id == person.id }) == false {
            store.editor?.people.append(person)
        }
    }
}

/// One person in the sidebar: initials, name, and free or busy at the event's time. A group
/// has Expand instead, always showing, since it is the thing to do with one.
private struct PersonRow: View {
    let name: String
    let address: String
    let note: String?
    let status: String?
    let photo: NSImage?
    var isGroup = false
    var isExpanding = false
    var onExpand: (() -> Void)? = nil
    let onRemove: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: name, size: 36, photo: photo, isGroup: isGroup)
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
            if isExpanding {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if let onExpand {
                Button("Expand", action: onExpand)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Replace \(name) with its members")
            }
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

/// The person's photo (the people directory's or Exchange's), else a neutral circle with their
/// initials, or with a group glyph for a distribution group.
struct Avatar: View {
    let name: String
    let size: CGFloat
    var photo: NSImage? = nil
    var isGroup = false

    var body: some View {
        if isGroup {
            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.32))
                    .foregroundStyle(Color.accentColor))
                .accessibilityHidden(true)
        } else if let photo {
            Image(nsImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            initials
        }
    }

    private var initials: some View {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "@" })
        let initials = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return Circle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.secondary))
            .accessibilityHidden(true)
    }
}
