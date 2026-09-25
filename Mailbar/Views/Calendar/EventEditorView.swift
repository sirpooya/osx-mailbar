import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Creating or editing an event (M16): the fields of the user's OWA form, minus the scheduling
/// assistant. Notes are plain text, like the mail composer. People sit in a sidebar on the right,
/// as in OWA, each with whether they are free at that time.
struct EventEditorView: View {
    @Bindable var store: CalendarStore
    let original: EventDraft

    @State private var roomsOpen = QCFlags.calendarRooms != nil
    @State private var categoriesOpen = QCFlags.calendarCategories
    @State private var charmsOpen = QCFlags.calendarCharms
    @State private var calendarOpen = false

    private static let labelWidth: CGFloat = 86

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            HStack(spacing: 0) {
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
                        tags
                        Divider().opacity(0.5)
                        files
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
                .frame(width: 540)
                Divider().opacity(0.6)
                PeopleSidebar(store: store, draft: draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 860, height: 660)
        .background(CalendarSurface.background)
        // Files dropped anywhere on the form are attached.
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        }
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

    /// Rooms from the organization's room lists, loaded the first time the picker opens. A
    /// popover with a search field rather than a menu: a real organization has too many rooms to
    /// scroll through.
    private var roomMenu: some View {
        Button { roomsOpen.toggle() } label: {
            Label("Rooms", systemImage: "building.2")
        }
        .fixedSize()
        .help("Book a room")
        .popover(isPresented: $roomsOpen, arrowEdge: .bottom) {
            RoomPicker(rooms: store.rooms, chosen: draft.rooms) { room in
                if draft.rooms.contains(room) {
                    store.editor?.rooms.removeAll { $0 == room }
                } else {
                    store.editor?.rooms.append(room)
                }
            }
            .task { await store.loadRooms() }
        }
    }

    /// A date and a time, each its own field, then how long (the user's call, 2026-09-25): no end
    /// to keep in step with the start.
    private var times: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Starts") {
                HStack(spacing: 6) {
                    DatePicker("", selection: field(\.startKeepingDuration), displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .frame(width: 110)
                    Button { calendarOpen.toggle() } label: { Image(systemName: "calendar") }
                        .buttonStyle(.borderless)
                        .help("Pick a date")
                        .popover(isPresented: $calendarOpen, arrowEdge: .bottom) {
                            DatePicker("", selection: field(\.startKeepingDuration), displayedComponents: [.date])
                                .labelsHidden()
                                .datePickerStyle(.graphical)
                                .padding(10)
                        }
                    if !draft.isAllDay {
                        DatePicker("", selection: field(\.startKeepingDuration), displayedComponents: [.hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .frame(width: 90)
                            .padding(.leading, 8)
                    }
                }
            }
            row(draft.isAllDay ? "Days" : "Duration") {
                if draft.isAllDay {
                    Picker("", selection: field(\.days)) {
                        ForEach(Array(Set(Array(1...14) + [draft.days])).sorted(), id: \.self) { days in
                            Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Picker("", selection: durationMinutes) {
                        ForEach(Array(Set(EventDraft.durationChoices + [durationMinutes.wrappedValue])).sorted(), id: \.self) { minutes in
                            Text(EventDraft.durationLabel(minutes: minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("until \(draft.end.formatted(date: Calendar.current.isDate(draft.end, inSameDayAs: draft.start) ? .omitted : .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            row("") {
                HStack(spacing: 18) {
                    Toggle("All day", isOn: field(\.isAllDay))
                    Toggle("Private", isOn: field(\.isPrivate))
                }
                .toggleStyle(.checkbox)
                .onChange(of: draft.isAllDay) { _, allDay in
                    // Back from all day: an hour, not the whole span to its last day's evening.
                    if !allDay, draft.duration <= 0 || draft.duration > 24 * 3600 { store.editor?.duration = 3600 }
                }
            }
        }
    }

    private var durationMinutes: Binding<Int> {
        Binding(get: { Int((draft.duration / 60).rounded()) },
                set: { store.editor?.duration = TimeInterval($0 * 60) })
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

    // MARK: - Category and charm

    /// OWA's Categorize and Charm. The category's colour is the master list's, the same rule the
    /// grid draws with; the first category chosen is the one that colours the event.
    private var tags: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Category") {
                HStack(spacing: 6) {
                    Button { categoriesOpen.toggle() } label: {
                        HStack(spacing: 5) {
                            if draft.categories.isEmpty {
                                Text("None")
                            } else {
                                ForEach(draft.categories, id: \.self) { name in
                                    HStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 2).fill(store.categoryColor(name)).frame(width: 10, height: 10)
                                        Text(name).lineLimit(1)
                                    }
                                }
                            }
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                    .popover(isPresented: $categoriesOpen, arrowEdge: .bottom) {
                        CategoryPicker(names: store.categoryNames, chosen: draft.categories,
                                       color: { store.categoryColor($0) }) { name in
                            if let name {
                                if draft.categories.contains(name) {
                                    store.editor?.categories.removeAll { $0 == name }
                                } else {
                                    store.editor?.categories.append(name)
                                }
                            } else {
                                store.editor?.categories = []
                            }
                        }
                    }
                }
            }
            row("Charm") {
                Button { charmsOpen.toggle() } label: {
                    HStack(spacing: 5) {
                        if let charm = draft.charm.flatMap(EventCharm.init) {
                            Image(systemName: charm.symbol)
                            Text(charm.label)
                        } else {
                            Text("None")
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                .popover(isPresented: $charmsOpen, arrowEdge: .bottom) {
                    CharmPicker(chosen: draft.charm) { charm in
                        store.editor?.charm = charm
                        charmsOpen = false
                    }
                }
            }
        }
    }

    // MARK: - Files

    /// Files on the event: those it has (removable) and those being added, which stay in memory
    /// until Save sends them. Add with the button or by dropping files on the form.
    private var files: some View {
        row("Files") {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    panel.prompt = "Attach"
                    if panel.runModal() == .OK { addFiles(panel.urls) }
                } label: {
                    Label("Add Files...", systemImage: "paperclip")
                }
                .fixedSize()
                if !draft.keptFiles.isEmpty || !draft.newFiles.isEmpty {
                    FlowChips {
                        ForEach(draft.keptFiles) { file in
                            fileChip(file.name, size: file.sizeLabel) { store.editor?.removedFileIDs.insert(file.id) }
                        }
                        ForEach(draft.newFiles) { file in
                            fileChip(file.name, size: file.sizeLabel) { store.editor?.newFiles.removeAll { $0.id == file.id } }
                        }
                    }
                }
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls where !url.hasDirectoryPath {
            guard let data = try? Data(contentsOf: url) else { continue }
            store.editor?.newFiles.append(.init(name: url.lastPathComponent, data: data))
        }
    }

    private func fileChip(_ name: String, size: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: Attachments.icon(for: name)).resizable().frame(width: 14, height: 14)
            Text(name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
            if !size.isEmpty { Text(size).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize() }
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .help("Remove \(name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
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
            HStack(alignment: .firstTextBaseline, spacing: 8) { content() }
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

/// Chips that wrap onto more lines when a row is full.
private struct FlowChips: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + line), points)
    }
}

/// The room list with a search field on top: type any part of a room's name or address, in any
/// order ("هفت نمونه" finds "ساختمان نمونه | طبقه هفت"). Up and Down move, Return picks, and the popover stays
/// open so several rooms can be booked.
private struct RoomPicker: View {
    let rooms: [Room]?
    let chosen: [Room]
    let toggle: (Room) -> Void

    @State private var query = QCFlags.calendarRooms ?? ""
    @State private var highlighted: Room.ID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = RoomSearch.filter(rooms ?? [], by: query)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search rooms", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let room = matches.first(where: { $0.id == highlighted }) ?? matches.first { toggle(room) } }
                    .onKeyPress(.downArrow) { move(1, in: matches); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: matches); return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            Group {
                if rooms == nil {
                    status("Loading rooms...")
                } else if rooms?.isEmpty == true {
                    status("No room lists published")
                } else if matches.isEmpty {
                    status("No rooms match")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(matches) { room in row(room).id(room.id) }
                            }
                            .padding(4)
                        }
                        .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }
            .frame(height: 260)
        }
        .frame(width: 340)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlighted = nil }
    }

    private func row(_ room: Room) -> some View {
        let isChosen = chosen.contains(room)
        return Button { toggle(room) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isChosen ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    DirectionalText(room.name, font: .system(size: 12.5))
                    Text(room.address).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(highlighted == room.id ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func move(_ step: Int, in matches: [Room]) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == highlighted }.map { $0 + step } ?? (step > 0 ? 0 : matches.count - 1)
        highlighted = matches[max(0, min(index, matches.count - 1))].id
    }
}

enum RoomSearch {
    /// Every word typed must appear in the name or the address, ignoring case, accents, and the
    /// Arabic and Persian spellings of ye and kaf, which directory data mixes freely.
    static func filter(_ rooms: [Room], by query: String) -> [Room] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return rooms }
        return rooms.filter { room in
            let text = normalized(room.name + " " + room.address)
            return words.allSatisfy { text.contains($0) }
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{064A}", with: "\u{06CC}")   // Arabic yeh to Persian yeh
            .replacingOccurrences(of: "\u{0649}", with: "\u{06CC}")   // alef maksura
            .replacingOccurrences(of: "\u{0643}", with: "\u{06A9}")   // Arabic kaf to Persian keheh
            .replacingOccurrences(of: "\u{200C}", with: "")            // zero-width non-joiner
    }
}
