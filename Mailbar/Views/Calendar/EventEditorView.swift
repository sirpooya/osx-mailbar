import SwiftUI

/// Creating or editing an event (M16): the fields of the user's OWA form, minus the scheduling
/// assistant, charms and categories. Notes are plain text, like the mail composer.
struct EventEditorView: View {
    @Bindable var store: CalendarStore
    let original: EventDraft

    @State private var suggestions: [(name: String, address: String)] = []
    @FocusState private var peopleFocused: Bool

    private static let labelWidth: CGFloat = 86

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: field(\.subject))
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.bottom, 2)
                    location
                    Divider().opacity(0.5)
                    times
                    Divider().opacity(0.5)
                    options
                    Divider().opacity(0.5)
                    people
                    Divider().opacity(0.5)
                    row("Notes") {
                        ComposeEditor(text: field(\.notes), onSend: { Task { await store.saveEditor() } })
                            .frame(height: 110)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    }
                    footer
                }
                .padding(18)
            }
        }
        .frame(width: 540, height: 640)
        .background(CalendarSurface.background)
    }

    private var draft: EventDraft { store.editor ?? original }

    /// A binding into the open draft, so every field edits `store.editor` directly.
    private func field<Value>(_ path: WritableKeyPath<EventDraft, Value>) -> Binding<Value> {
        Binding(get: { (store.editor ?? original)[keyPath: path] },
                set: { store.editor?[keyPath: path] = $0 })
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel") { store.editor = nil }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text(draft.isNew ? "New Event" : "Edit Event").font(.system(size: 13, weight: .semibold))
            Spacer()
            if draft.isSaving {
                ProgressView().controlSize(.small).frame(width: 60)
            } else {
                // Says "Send" when saving will mail invitations or updates, so nobody is surprised.
                Button(draft.sendsInvitations ? "Send" : "Save") { Task { await store.saveEditor() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.problem != nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Fields

    private var location: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Location") {
                HStack(spacing: 6) {
                    TextField(draft.rooms.isEmpty ? "Add a location" : draft.locationText, text: field(\.location))
                        .textFieldStyle(.roundedBorder)
                    roomMenu
                }
            }
            if !draft.rooms.isEmpty {
                row("") {
                    HStack(spacing: 5) {
                        ForEach(draft.rooms) { room in
                            chip(room.name, systemImage: "building.2") {
                                store.editor?.rooms.removeAll { $0 == room }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Rooms from the organization's room lists, loaded the first time the menu is opened.
    private var roomMenu: some View {
        Menu {
            if let rooms = store.rooms {
                if rooms.isEmpty {
                    Text("No room lists published")
                } else {
                    ForEach(rooms) { room in
                        Button {
                            if draft.rooms.contains(room) {
                                store.editor?.rooms.removeAll { $0 == room }
                            } else {
                                store.editor?.rooms.append(room)
                            }
                        } label: {
                            Label(room.name, systemImage: draft.rooms.contains(room) ? "checkmark" : "")
                        }
                    }
                }
            } else {
                Text("Loading rooms...")
            }
        } label: {
            Label("Rooms", systemImage: "building.2")
        }
        .fixedSize()
        .task { await store.loadRooms() }
        .help("Book a room")
    }

    private var times: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Starts") {
                DatePicker("", selection: field(\.start),
                           displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                    .onChange(of: draft.start) { old, new in
                        // Moving the start keeps the length, as every calendar does.
                        guard let length = store.editor.map({ $0.end.timeIntervalSince(old) }), length > 0 else { return }
                        store.editor?.end = new.addingTimeInterval(length)
                    }
            }
            row("Ends") {
                DatePicker("", selection: field(\.end),
                           displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
            }
            row("") {
                HStack(spacing: 18) {
                    Toggle("All day", isOn: field(\.isAllDay))
                    Toggle("Private", isOn: field(\.isPrivate))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Repeat") {
                if draft.isOccurrence {
                    Text("Changes apply to this occurrence only.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if draft.isNew {
                    Picker("", selection: field(\.repeatRule)) {
                        ForEach(EventDraft.Repeat.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text("Never").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            row("Reminder") {
                Picker("", selection: field(\.reminderMinutes)) {
                    ForEach(EventDraft.reminderChoices, id: \.self) { Text(EventDraft.reminderLabel($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Show as") {
                Picker("", selection: field(\.showAs)) {
                    ForEach(EventDraft.ShowAs.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// Addresses, comma separated, with suggestions from the company directory (searched by the
    /// server) and from inbox senders for the name being typed.
    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("People") {
                TextField("Add people", text: field(\.attendees))
                    .textFieldStyle(.roundedBorder)
                    .focused($peopleFocused)
            }
            if peopleFocused, !suggestions.isEmpty {
                row("") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions, id: \.address) { person in
                            Button {
                                store.editor?.attendees = Recipients.completing(draft.attendees, with: person.address)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                                    Text(person.name.isEmpty ? person.address : person.name).font(.system(size: 12))
                                    Text(person.address).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: draft.attendees) {
            let token = Recipients.currentToken(in: draft.attendees)
            guard token.count >= 2 else { suggestions = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            suggestions = await store.peopleSuggestions(for: token, excluding: draft.attendees)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = draft.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.orange)
        } else if let problem = draft.problem {
            Text(problem).font(.system(size: 11)).foregroundStyle(.orange)
        } else if draft.sendsInvitations {
            Text(draft.isNew ? "Saving sends the invitations." : "Saving sends the changes to everyone invited.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Pieces

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ text: String, systemImage: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(text).font(.system(size: 11))
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}
