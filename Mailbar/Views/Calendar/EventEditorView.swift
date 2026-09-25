import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Creating or editing an event (M16): the fields of the user's OWA form, minus the scheduling
/// assistant. Notes are plain text, like the mail composer. People sit in a sidebar on the right,
/// as in OWA, each with whether they are free at that time.
struct EventEditorView: View {
    @Bindable var store: CalendarStore
    let original: EventDraft

    @State private var highlightedRoom: Room.ID?
    @State private var roomAvailability: [String: String] = [:]
    @State private var categoriesOpen = QCFlags.calendarCategories
    @State private var charmsOpen = QCFlags.calendarCharms
    @State private var calendarOpen = false
    /// Whether Title is being edited, for its box's accent border. Nothing is focused on open.
    @FocusState private var titleFocused: Bool
    /// The scroll area's height and the fields' above Description, so Description can fill the rest.
    @State private var formHeight: CGFloat = 0
    @State private var fieldsHeight: CGFloat = 0
    @FocusState private var locationFocused: Bool
    @State private var repeatEditorOpen = QCFlags.calendarRepeat
    @State private var endCalendarOpenForSeries = false
    @State private var endCalendarOpen = false

    private static let labelWidth: CGFloat = 78
    /// The form's size, cut to the user's marks (2026-09-25): 440 pt of fields, a 250 pt People
    /// sidebar, 556 pt tall. Description takes whatever height is left.
    private static let mainWidth: CGFloat = 440
    private static let sidebarWidth: CGFloat = 250
    private static let formSize = CGSize(width: mainWidth + sidebarWidth, height: 556)
    /// Repeat, Reminder and Show as share one width (the user's call), wide enough for the
    /// longest choice, "Working elsewhere" with its swatch.
    private static let menuWidth: CGFloat = 190
    /// The toolbar's charm glyph, category square and Show as square share one size (the user's
    /// catch: they were 14, 10 and 14 pt).
    private static let toolbarIcon: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            // No field focused or selected when the form opens, not even for a frame.
            FocusSink().frame(width: 0, height: 0)
            header
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                      VStack(alignment: .leading, spacing: 12) {
                        // A plain bordered field like Location, with its label (the user's call).
                        row("Title") {
                            FieldBox(focused: titleFocused) {
                                TextField("Add a title", text: field(\.subject))
                                    .textFieldStyle(.plain)
                                    .focused($titleFocused)
                            }
                        }
                        location
                        Divider().opacity(0.5)
                        times
                        Divider().opacity(0.5)
                        options
                        Divider().opacity(0.5)
                        files
                      }
                      .background(GeometryReader { box in
                          Color.clear
                              .onAppear { fieldsHeight = box.size.height }
                              .onChange(of: box.size.height) { _, height in fieldsHeight = height }
                      })
                        // The event's body, which OWA calls the description. It fills what the
                        // form leaves, down to the bottom bar, never shorter than 110 pt (the
                        // user's catch: a fixed box left dead space under it).
                        row("Description") {
                            ComposeEditor(text: field(\.notes), onSend: { Task { await store.saveEditor() } },
                                          takesFocus: false)
                                .frame(height: max(110, formHeight - 36 - fieldsHeight - 12))
                                // The text view has no baseline SwiftUI can see: its first line
                                // sits at the 8 pt inset plus the 13 pt font's ascender, so the
                                // label lines up with it exactly (the user's catch, twice).
                                .alignmentGuide(.firstTextBaseline) { box in
                                    box[.top] + 8 + NSFont.systemFont(ofSize: 13).ascender
                                }
                                .overlay(alignment: .topLeading) {
                                    if draft.notes.isEmpty {
                                        Text("Add a description")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 13)
                                            .padding(.vertical, 8)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .background(EndEditingArea())
                }
                .background(GeometryReader { box in
                    Color.clear
                        .onAppear { formHeight = box.size.height }
                        .onChange(of: box.size.height) { _, height in formHeight = height }
                })
                .frame(width: Self.mainWidth)
                Divider().opacity(0.6)
                PeopleSidebar(store: store, draft: draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.6)
            bottomBar
        }
        .frame(width: Self.formSize.width, height: Self.formSize.height)
        .background(CalendarSurface.background)
        .task {
            // A turn after the sheet is up, or the focus has nowhere to go yet.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let rooms = QCFlags.calendarRooms {
                store.editor?.location = rooms
                locationFocused = true
            }
        }
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

    /// The title bar with the form's name alone, then OWA's toolbar under it: Attach, Charm and
    /// Categorize. Cancel and Send live in the bar at the bottom (the user's layout, 2026-09-25).
    private var header: some View {
        VStack(spacing: 0) {
            Text(draft.isNew ? "New Event" : "Edit Event")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            // The same white as the form, no line between it and the title (the user's call).
            HStack(spacing: 16) {
                attachButton
                charmButton
                categoryButton
                showAsMenu
                reminderMenu
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 7)
        }
    }

    /// What saving will do, or what stops it, on the left; Cancel and Send on the right.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            footer
            Spacer()
            Button("Cancel") { store.editor = nil }
                .keyboardShortcut(.cancelAction)
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

    /// Location is also where rooms are found (the user's call, 2026-09-25: one place, not a
    /// field and a Rooms button that did the same thing). Typing lists the organization's rooms
    /// that match under the field; a click books one, and the bar under the list books them all
    /// or checks which are free at the event's time.
    private var location: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Location") {
                FieldBox(focused: locationFocused) {
                    TextField(draft.rooms.isEmpty ? "Add a location or a room" : draft.locationText, text: field(\.location))
                        .textFieldStyle(.plain)
                        .focused($locationFocused)
                        .onKeyPress(.downArrow) { moveRoom(1); return .handled }
                        .onKeyPress(.upArrow) { moveRoom(-1); return .handled }
                        .onSubmit {
                            let matches = roomMatches
                            if let room = matches.first(where: { $0.id == highlightedRoom }) {
                                book([room])
                            }
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if locationFocused, !draft.location.trimmingCharacters(in: .whitespaces).isEmpty, !roomMatches.isEmpty {
                    RoomDropdown(rooms: roomMatches, chosen: draft.rooms, highlighted: highlightedRoom,
                                 availability: roomAvailability,
                                 onSelect: { highlightedRoom = $0.id },
                                 onAdd: { book([$0]) },
                                 onCheck: checkRooms)
                        .padding(.leading, Self.labelWidth + 10)
                        .offset(y: 32)
                }
            }
            .zIndex(1)
            if !draft.rooms.isEmpty {
                row("") {
                    FlowChips {
                        ForEach(draft.rooms) { room in
                            chip(room.name, systemImage: "building.2") {
                                store.editor?.rooms.removeAll { $0 == room }
                            }
                        }
                    }
                }
            }
        }
        .zIndex(1)
        .task { await store.loadRooms() }
        .onChange(of: draft.location) { _, _ in highlightedRoom = nil; roomAvailability = [:] }
    }

    private var roomMatches: [Room] {
        let query = draft.location.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return RoomSearch.filter(store.rooms ?? [], by: query)
    }

    /// Books rooms and clears the typed words, so the location becomes the rooms' names, as OWA
    /// fills it.
    private func book(_ rooms: [Room]) {
        for room in rooms where store.editor?.rooms.contains(room) == false {
            store.editor?.rooms.append(room)
        }
        store.editor?.location = ""
        highlightedRoom = nil
    }

    private func moveRoom(_ step: Int) {
        let matches = roomMatches
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == highlightedRoom }.map { $0 + step } ?? (step > 0 ? 0 : matches.count - 1)
        highlightedRoom = matches[max(0, min(index, matches.count - 1))].id
    }

    private func checkRooms() {
        let addresses = roomMatches.map(\.address)
        Task {
            roomAvailability = await store.availability(for: addresses, start: draft.requestStart, end: draft.requestEnd)
        }
    }

    /// Start and End, each a date field with its calendar and a time field, in columns that line
    /// up, as OWA lays them out (the user's call, 2026-09-25, after trying a length slider).
    /// Moving the start moves the end with it; an all-day event shows dates only.
    private var times: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Outlook for Mac's arrangement (the user's pick): Duration and All day on one line,
            // Starts and Ends under it. The duration sets the end; editing the end updates it.
            row("Duration") {
                PopUpMenu(items: durationItems, selected: durationID, width: 120) { id in
                    if let minutes = Int(id) { store.editor?.duration = TimeInterval(minutes * 60) }
                }
                .disabled(draft.isAllDay)
                Toggle("All day event", isOn: field(\.isAllDay))
                    .toggleStyle(.checkbox)
                    .padding(.leading, 8)
                Toggle("Private", isOn: field(\.isPrivate))
                    .toggleStyle(.checkbox)
                    .padding(.leading, 8)
            }
            .onChange(of: draft.isAllDay) { _, allDay in
                // Back from all day: an hour, not the whole span to its last day's evening.
                if !allDay, draft.duration <= 0 || draft.duration > 24 * 3600 { store.editor?.duration = 3600 }
            }
            row("Starts") { dateTime(field(\.startKeepingDuration), calendarOpen: $calendarOpen) }
            row("Ends") { dateTime(field(\.end), calendarOpen: $endCalendarOpen) }
        }
    }

    private var durationMinutes: Int { Int((draft.duration / 60).rounded()) }
    private var durationID: String { String(durationMinutes) }

    /// Outlook's lengths, plus the event's own when it is none of them (a 75-minute drag).
    private var durationItems: [PopUpMenu.Item] {
        let minutes = Array(Set(EventDraft.durationChoices + [max(durationMinutes, 1)])).sorted()
        return minutes.map { .init(id: String($0), title: EventDraft.durationLabel(minutes: $0)) }
    }

    /// One row's date box, with its calendar button inside it, and the time box right beside it,
    /// at fixed widths so Start and End line up (the user's layout, 2026-09-25).
    private func dateTime(_ date: Binding<Date>, calendarOpen: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            dateBox(date, calendarOpen: calendarOpen)
            if !draft.isAllDay {
                FieldBox { PlainDatePicker(date: date, elements: .hourMinute).fieldInset(-2.5) }
                    .frame(width: 76)
            }
        }
    }

    private func dateBox(_ date: Binding<Date>, calendarOpen: Binding<Bool>) -> some View {
        FieldBox {
            PlainDatePicker(date: date, elements: .yearMonthDay).fieldInset(-3.5)
            Spacer(minLength: 0)
            Button { calendarOpen.wrappedValue.toggle() } label: {
                Image(systemName: "calendar").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Pick a date")
            .popover(isPresented: calendarOpen, arrowEdge: .bottom) {
                DatePicker("", selection: date, displayedComponents: [.date])
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    // It takes the keyboard as the popover opens; no ring around the whole
                    // calendar for that (the user's catch).
                    .focusEffectDisabled()
                    .padding(10)
            }
        }
        .frame(width: 134)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Repeat") {
                if draft.isOccurrence {
                    Text("Changes apply to this occurrence only.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if draft.isNew {
                    PopUpMenu(items: repeatItems, selected: repeatSelection, width: Self.menuWidth,
                              actions: ["other"], onSelect: pickRepeat)
                        .popover(isPresented: $repeatEditorOpen, arrowEdge: .bottom) {
                            RepeatPatternEditor(pattern: QCFlags.calendarRepeat ? RepeatPattern(kind: .monthlyWeek) : draft.repeatPattern, start: draft.start, workDays: workDays,
                                                onSave: { store.editor?.repeatPattern = $0; repeatEditorOpen = false },
                                                onCancel: { repeatEditorOpen = false })
                        }
                    // What the choice means for this start date, as Outlook's summary line says it.
                    if let pattern = draft.repeatPattern, presetIndex(pattern) != nil {
                        Text(pattern.label(start: draft.start, workDays: workDays))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Never").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if draft.isNew, draft.repeatPattern != nil { seriesEnd }
        }
    }

    // MARK: - Repeat

    private var workDays: Set<Int> { Keys.calendarWorkDays() }

    private func reminderID(_ minutes: Int?) -> String { minutes.map(String.init) ?? "none" }

    /// Never, OWA's quick choices worded from the start date, the pattern set in Other when it is
    /// none of those, and Other itself.
    private var repeatItems: [PopUpMenu.Item] {
        var items: [PopUpMenu.Item] = [.init(id: "never", title: "Never")]
        for index in RepeatPattern.presets(workDays: workDays).indices {
            items.append(.init(id: "preset-\(index)", title: RepeatPattern.presetNames[index]))
        }
        if let pattern = draft.repeatPattern, presetIndex(pattern) == nil {
            items.append(.init(id: "custom", title: pattern.label(start: draft.start, workDays: workDays), separatorBefore: true))
        }
        items.append(.init(id: "other", title: "Other...", separatorBefore: true))
        return items
    }

    private func presetIndex(_ pattern: RepeatPattern) -> Int? {
        RepeatPattern.presets(workDays: workDays).firstIndex { preset in
            // A weekly pattern on just the start's day is the "Every Wednesday" choice.
            let normal: (RepeatPattern) -> RepeatPattern = { p in
                var p = p
                if p.kind == .weekly, p.weekdays == [Calendar.current.component(.weekday, from: draft.start)] { p.weekdays = [] }
                return p
            }
            return normal(preset) == normal(pattern)
        }
    }

    private var repeatSelection: String {
        guard let pattern = draft.repeatPattern else { return "never" }
        return presetIndex(pattern).map { "preset-\($0)" } ?? "custom"
    }

    private func pickRepeat(_ id: String) {
        switch id {
        case "never": store.editor?.repeatPattern = nil
        case "other": repeatEditorOpen = true
        case "custom": break
        default:
            if let index = Int(id.dropFirst("preset-".count)) {
                store.editor?.repeatPattern = RepeatPattern.presets(workDays: workDays)[index]
            }
        }
    }

    /// When the series stops: no end, on a date, or after a number of times, as OWA's To field
    /// and Outlook's End date do.
    private var seriesEnd: some View {
        row("Until") {
            PopUpMenu(items: [.init(id: "never", title: "No end date"), .init(id: "on", title: "On a date"),
                              .init(id: "after", title: "After")],
                      selected: seriesEndID, width: 130) { id in
                switch id {
                case "on":
                    let threeMonths = Calendar.current.date(byAdding: .month, value: 3, to: draft.start) ?? draft.start
                    store.editor?.repeatEnd = .on(threeMonths)
                case "after": store.editor?.repeatEnd = .after(10)
                default: store.editor?.repeatEnd = .never
                }
            }
            switch draft.repeatEnd {
            case .on(let last):
                dateBox(Binding(get: { last }, set: { store.editor?.repeatEnd = .on($0) }),
                        calendarOpen: $endCalendarOpenForSeries)
            case .after(let count):
                FieldBox {
                    TextField("", value: Binding(get: { count }, set: { store.editor?.repeatEnd = .after(min(max($0, 1), 999)) }),
                              format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                .frame(width: 54)
                Text(count == 1 ? "time" : "times").foregroundStyle(.secondary)
            case .never:
                EmptyView()
            }
        }
    }

    private var seriesEndID: String {
        switch draft.repeatEnd {
        case .never: return "never"
        case .on: return "on"
        case .after: return "after"
        }
    }

    // MARK: - Category and charm

    /// OWA's Categorize and Charm. The category's colour is the master list's, the same rule the
    /// grid draws with; the first category chosen is the one that colours the event. Each button
    /// shows what is chosen, or its own name when nothing is.
    private var categoryButton: some View {
        Button { categoriesOpen.toggle() } label: {
            HStack(spacing: 5) {
                if draft.categories.isEmpty {
                    Text("Categorize")
                } else {
                    ForEach(draft.categories, id: \.self) { name in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(store.categoryColor(name))
                                .frame(width: Self.toolbarIcon, height: Self.toolbarIcon)
                            Text(name).lineLimit(1)
                        }
                    }
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
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

    /// Show as and Reminder live in the toolbar too, as in OWA (the user's layout): each shows
    /// the current choice, and the choices carry the system checkmark.
    private var showAsMenu: some View {
        Menu {
            Picker("", selection: field(\.showAs)) {
                ForEach(EventDraft.ShowAs.allCases) { state in
                    Label { Text(state.label) } icon: { Image(nsImage: ShowAsSwatch.image(state)) }.tag(state)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label { Text(draft.showAs.label) } icon: { Image(nsImage: ShowAsSwatch.image(draft.showAs, size: Self.toolbarIcon)) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show as")
    }

    private var reminderMenu: some View {
        Menu {
            Picker("", selection: field(\.reminderMinutes)) {
                ForEach(EventDraft.reminderChoices, id: \.self) { Text(EventDraft.reminderLabel($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(EventDraft.reminderLabel(draft.reminderMinutes),
                  systemImage: draft.reminderMinutes == nil ? "bell.slash" : "bell")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reminder")
    }

    private var charmButton: some View {
        Button { charmsOpen.toggle() } label: {
            HStack(spacing: 5) {
                if let charm = draft.charm.flatMap(EventCharm.init) {
                    Image(systemName: charm.symbol).font(.system(size: Self.toolbarIcon - 1))
                    Text(charm.label)
                } else {
                    Text("Charm")
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: $charmsOpen, arrowEdge: .bottom) {
            CharmPicker(chosen: draft.charm) { charm in
                store.editor?.charm = charm
                charmsOpen = false
            }
        }
    }

    // MARK: - Files

    /// OWA's Attach: pick files; dropping them on the form works too.
    private var attachButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = "Attach"
            if panel.runModal() == .OK { addFiles(panel.urls) }
        } label: {
            // The icon close to its word, as the toolbar's other buttons have it; a Label spaces
            // them wider than the rest of the bar.
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                Text("Attach")
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    /// Files on the event, shown only when there are some: those it has (removable) and those
    /// being added, which stay in memory until Save sends them.
    @ViewBuilder
    private var files: some View {
        if !draft.keptFiles.isEmpty || !draft.newFiles.isEmpty {
            // No label and no line under it: the files sit just above Description (the user's
            // sketch).
            row("") {
                FlowChips {
                    ForEach(draft.keptFiles) { file in
                        fileChip(file.name, size: file.sizeLabel) { store.editor?.removedFileIDs.insert(file.id) }
                    }
                    ForEach(draft.newFiles) { file in
                        fileChip(file.name, size: file.sizeLabel) { store.editor?.newFiles.removeAll { $0.id == file.id } }
                    }
                }
            }
            .padding(.bottom, -4)
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

    /// A label and its field, on one baseline.
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Right-aligned with a colon, as Outlook for Mac lays its form out (the user's pick).
            Text(label.isEmpty ? "" : label + ":")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
                // Clicks on a label fall through to the empty space behind it.
                .allowsHitTesting(false)
            HStack(alignment: .firstTextBaseline, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Every row at least a field's height, so a row that swaps a popup for a box (Until) or
        // loses one keeps its place.
        .frame(minHeight: 28)
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

/// Outlook's free/busy swatches for the Show as menu: Free an empty square, Working elsewhere
/// dotted, Tentative hatched, Busy the calendar's blue, Away purple. Drawn as untinted images,
/// because a menu draws a template image in the text colour and the colour is the point.
enum ShowAsSwatch {
    static func image(_ state: EventDraft.ShowAs, size: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let box = rect.insetBy(dx: 1, dy: 1)
            let border = NSColor(srgbRed: 0.45, green: 0.5, blue: 0.6, alpha: 1)
            let blue = NSColor(srgbRed: 0.72, green: 0.8, blue: 0.93, alpha: 1)
            switch state {
            case .free:
                NSColor.white.setFill()
                box.fill()
            case .elsewhere:
                NSColor.white.setFill()
                box.fill()
                border.withAlphaComponent(0.8).setFill()
                for x in stride(from: box.minX + 2, to: box.maxX, by: 3) {
                    for y in stride(from: box.minY + 2, to: box.maxY, by: 3) {
                        NSBezierPath(ovalIn: NSRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)).fill()
                    }
                }
            case .tentative:
                NSColor.white.setFill()
                box.fill()
                let hatch = NSBezierPath()
                for offset in stride(from: -box.height, to: box.width, by: 3.5) {
                    hatch.move(to: NSPoint(x: box.minX + offset, y: box.minY))
                    hatch.line(to: NSPoint(x: box.minX + offset + box.height, y: box.maxY))
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: box).addClip()
                blue.withAlphaComponent(1).setStroke()
                hatch.lineWidth = 1.2
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            case .busy:
                blue.setFill()
                box.fill()
            case .away:
                NSColor(srgbRed: 0.55, green: 0.27, blue: 0.5, alpha: 1).setFill()
                box.fill()
            }
            border.setStroke()
            let outline = NSBezierPath(rect: box)
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Empty space in the form: a click there ends editing, so the field loses its focus and its
/// selection, as everywhere on the Mac (the user's call, 2026-09-25). It sits behind the fields,
/// so a click on a field or a control still reaches it.
struct EndEditingArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
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

/// The rooms matching what is typed in Location, under the field, after Outlook's "Search
/// Contacts and Rooms": one row each, a check on those booked. A click selects a room; Add to
/// meeting (or a double-click, or Return) books the selected one, and Check availability asks
/// about every room listed (the user's rule, 2026-09-25).
private struct RoomDropdown: View {
    let rooms: [Room]
    let chosen: [Room]
    let highlighted: Room.ID?
    /// Free or busy by lowercased address, once Check availability has been pressed.
    let availability: [String: String]
    let onSelect: (Room) -> Void
    let onAdd: (Room) -> Void
    let onCheck: () -> Void

    private var selectedRoom: Room? { rooms.first { $0.id == highlighted } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rooms) { room in row(room).id(room.id) }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
            }
            Divider()
            HStack(spacing: 10) {
                Text(rooms.count == 1 ? "1 room" : "\(rooms.count) rooms")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check availability", action: onCheck)
                Button("Add to meeting") { if let selectedRoom { onAdd(selectedRoom) } }
                    .disabled(selectedRoom == nil)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 8).fill(CalendarSurface.background)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func row(_ room: Room) -> some View {
        let booked = chosen.contains(room)
        let state = availability[room.address.lowercased()]
        return Button { onSelect(room) } label: {
            HStack(spacing: 8) {
                Image(systemName: booked ? "checkmark.circle.fill" : "building.2")
                    .foregroundStyle(booked ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    DirectionalText(room.name, font: .system(size: 12.5))
                    Text(room.address).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let state {
                    HStack(spacing: 4) {
                        Circle().fill(state == "Free" ? Color.green : state == "NoData" ? Color.gray : Color.red)
                            .frame(width: 6, height: 6)
                        Text(state == "Free" ? "Free" : state == "NoData" ? "No information" : "Busy")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(highlighted == room.id ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onAdd(room) })
        .accessibilityAddTraits(booked ? .isSelected : [])
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
