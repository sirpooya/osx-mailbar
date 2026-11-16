import AppKit
import SwiftUI

// The search field and its results (2026-11-16, after Outlook): a scope menu at the field's
// left, an Options popover, criteria chips, the keyword hint, saved searches, and Events and
// People sections above the mail.

/// The field under the header. Typing searches the server after a short pause, so each
/// keystroke does not become a request; results that arrive after the text changed are dropped
/// by the store.
struct SearchBarView: View {
    @Bindable var store: MailStore
    var focused: FocusState<Bool>.Binding

    @State private var showsOptions = false
    @State private var editingSaved = false
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private var extras: SearchState { store.searchExtras }
    private var accountID: UUID? { store.selectedAccount?.id }
    private var hasArchive: Bool { accountID.map { extras.onlineArchive[$0] == true } ?? false }

    private var placeholder: String {
        switch extras.scope(for: accountID) {
        case .thisFolder: "Search \(store.mailFolder.title)"
        case .allFolders: "Search All Folders"
        case .onlineArchive: "Search Online Archive"
        }
    }

    /// Everything that changes the results; the search runs again when any of it does.
    private var runKey: String {
        let criteria = String(describing: extras.criteria)
        return [store.searchQuery, criteria, extras.scope.rawValue, "\(extras.includeDeleted)"].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            field
            if naming { nameRow }
            if !extras.criteria.isEmpty {
                SearchCriteriaChips(extras: extras)
            } else if store.searchQuery.isEmpty, !naming {
                Text("Keywords:  \(SearchQuery.keywordHint)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Keywords you can type: from, to, subject, has attachment, received")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .onAppear { focused.wrappedValue = true }
        .task(id: runKey) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.runSearch()
        }
        .task(id: accountID) {
            if let accountID { await store.probeOnlineArchive(for: accountID) }
        }
        .task { await applyQCFlags() }
    }

    private var field: some View {
        HStack(spacing: 6) {
            scopeMenu
            TextField(placeholder, text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focused)
                .onSubmit { Task { await store.runSearch() } }
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear")
            }
            Button {
                showsOptions.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(extras.criteria.isEmpty ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help("Search Options")
            .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
                SearchOptionsView(extras: extras)
            }
            Button("Done") { store.closeSearch() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
        // On the field, not the menu: a popover anchored to a menu's button does not show.
        .popover(isPresented: $editingSaved, arrowEdge: .bottom) {
            SavedSearchesEditor(store: store)
        }
    }

    /// Where to look, Outlook's scope menu, with the saved searches under it.
    private var scopeMenu: some View {
        Menu {
            Picker("Search In", selection: Bindable(extras).scope) {
                Text("This Folder (\(store.mailFolder.title))").tag(SearchScope.thisFolder)
                Text("All Folders").tag(SearchScope.allFolders)
                if hasArchive { Text("Online Archive").tag(SearchScope.onlineArchive) }
            }
            .pickerStyle(.inline)
            Toggle("Include Deleted Items", isOn: Bindable(extras).includeDeleted)
                .disabled(extras.scope != .allFolders)
            Divider()
            if !extras.saved.isEmpty {
                Section("Saved Searches") {
                    ForEach(extras.saved) { saved in
                        Button(saved.name) { store.runSavedSearch(saved) }
                    }
                }
            }
            Button("Save Search...") {
                newName = store.searchQuery.trimmingCharacters(in: .whitespaces)
                naming = true
            }
            .disabled(!store.currentSearch.isSearchable)
            Button("Edit Saved Searches...") { editingSaved = true }
                .disabled(extras.saved.isEmpty)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(extras.scope(for: accountID) == .thisFolder ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.accentColor))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where to Search, Saved Searches")
    }

    /// "Save Search": the name, in a row under the field (an alert in a popover draws badly).
    private var nameRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Name this search", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($nameFocused)
                .onSubmit(save)
                .onExitCommand { naming = false }
            Button("Cancel") { naming = false }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Save", action: save)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.5)))
        .onAppear { nameFocused = true }
    }

    private func save() {
        store.saveSearch(named: newName)
        naming = false
    }

    /// DEBUG launch flags that put each state on screen without a click (`SearchQC`).
    private func applyQCFlags() async {
        #if DEBUG
        guard QCFlags.searchText != nil else { return }
        if let scope = SearchQC.scope {
            if scope == .onlineArchive, let accountID { await store.probeOnlineArchive(for: accountID) }
            extras.scope = scope
        }
        if SearchQC.includeDeleted { extras.includeDeleted = true }
        if SearchQC.criteria {
            extras.criteria.from = "sara"
            extras.criteria.hasAttachments = true
            extras.criteria.receivedAfter = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        }
        if SearchQC.savedSearches, extras.saved.isEmpty {
            extras.saved = [SavedSearch(name: "Sara's files", query: "from:sara hasattachment:true", scope: .allFolders),
                            SavedSearch(name: "Planning", query: "planning", scope: .thisFolder)]
        }
        try? await Task.sleep(for: .seconds(1))
        if SearchQC.options { showsOptions = true }
        if SearchQC.savedSearches { editingSaved = true }
        if SearchQC.naming {
            newName = "Design reviews"
            naming = true
        }
        #endif
    }
}

/// The criteria set in Options, as chips under the field; the cross clears one.
struct SearchCriteriaChips: View {
    @Bindable var extras: SearchState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(extras.criteria.fields, id: \.self) { field in
                    HStack(spacing: 4) {
                        Text(extras.criteria.label(field)).lineLimit(1)
                        Button {
                            extras.criteria.clear(field)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// Outlook's advanced search, small: From, To, Subject, the received dates, attachments.
struct SearchOptionsView: View {
    @Bindable var extras: SearchState
    @Environment(\.dismiss) private var dismiss

    private static let labelWidth: CGFloat = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Search Options").font(.system(size: 13, weight: .semibold))
            row("From:") { textField("Name or address", text: $extras.criteria.from) }
            row("To:") { textField("Name or address", text: $extras.criteria.to) }
            row("Subject:") { textField("Contains", text: $extras.criteria.subject) }
            row("Received:") {
                dateRow("After", date: $extras.criteria.receivedAfter, fallback: -7)
            }
            row("") {
                dateRow("Before", date: $extras.criteria.receivedBefore, fallback: 0)
            }
            row("") {
                Toggle("Has attachments", isOn: $extras.criteria.hasAttachments)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            HStack {
                Button("Clear") { extras.criteria = SearchCriteria() }
                    .disabled(extras.criteria.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 310)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }

    private func textField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
    }

    /// A checkbox that turns the date on, and the date beside it.
    private func dateRow(_ title: String, date: Binding<Date?>, fallback days: Int) -> some View {
        let on = Binding<Bool>(
            get: { date.wrappedValue != nil },
            set: { date.wrappedValue = $0 ? Calendar.current.date(byAdding: .day, value: days,
                                                                   to: Calendar.current.startOfDay(for: Date())) : nil })
        let value = Binding<Date>(get: { date.wrappedValue ?? Date() }, set: { date.wrappedValue = $0 })
        return HStack(spacing: 8) {
            Toggle(title, isOn: on)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .frame(width: 64, alignment: .leading)
            DatePicker("", selection: value, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .disabled(date.wrappedValue == nil)
        }
    }
}

/// The saved searches, to rename or delete.
struct SavedSearchesEditor: View {
    let store: MailStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved Searches").font(.system(size: 13, weight: .semibold))
            if store.searchExtras.saved.isEmpty {
                Text("No saved searches.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(store.searchExtras.saved) { saved in
                SavedSearchRow(saved: saved, store: store)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 310)
    }
}

private struct SavedSearchRow: View {
    let saved: SavedSearch
    let store: MailStore
    @State private var name = ""

    private var summary: String {
        var parts = [saved.query.isEmpty ? nil : "\u{201C}\(saved.query)\u{201D}", saved.scope.title]
        if !saved.criteria.isEmpty { parts.append(saved.criteria.fields.map(saved.criteria.label).joined(separator: ", ")) }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { store.renameSavedSearch(saved.id, to: name) }
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Button {
                store.deleteSavedSearch(saved.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Delete \(saved.name)")
        }
        .onAppear { name = saved.name }
        .onDisappear { if name != saved.name { store.renameSavedSearch(saved.id, to: name) } }
        .contextMenu {
            Button("Run") { store.runSavedSearch(saved) }
            Button("Delete", role: .destructive) { store.deleteSavedSearch(saved.id) }
        }
    }
}

// MARK: - Results

/// What a search found: Events and People (when plain words were typed) above the mail.
struct SearchResultsView: View {
    @Bindable var store: MailStore
    let account: Account
    let onOpenEvent: (UUID, String) -> Void

    private var extras: SearchState { store.searchExtras }

    private var whereText: String {
        switch extras.scope(for: account.id) {
        case .thisFolder: "\(store.searchFolder.title) of \(account.displayName)"
        case .allFolders: "any folder of \(account.displayName)"
        case .onlineArchive: "the Online Archive of \(account.displayName)"
        }
    }

    private var queryText: String {
        let typed = store.searchQuery.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? "these options" : "\u{201C}\(typed)\u{201D}"
    }

    var body: some View {
        switch store.searchPhase {
        case .idle, .searching:
            SkeletonListView(rowCount: 3)
        case .results(let found):
            // The filters and order apply here, to what the server matched.
            let messages = store.listOptions.apply(to: found, in: store.searchFolder)
            if messages.isEmpty, extras.events.isEmpty, extras.people.isEmpty {
                if found.isEmpty {
                    StatePlaceholder(symbol: "magnifyingglass", tint: .secondary,
                                     title: "No messages match",
                                     message: "Nothing in \(whereText) matches \(queryText).") {
                        if extras.scope(for: account.id) == .thisFolder {
                            Button("Search All Folders") { extras.scope = .allFolders }
                        }
                    }
                } else {
                    StatePlaceholder(symbol: "line.3.horizontal.decrease.circle", tint: .secondary,
                                     title: "No messages match",
                                     message: "None of the matches for \(queryText) is \(store.listOptions.summary(in: store.searchFolder).lowercased()).") {
                        Button("Clear Filters") { store.listOptions.filters = [] }
                    }
                }
            } else {
                list(messages)
            }
        case .failed(let message):
            GenericFailureView(message: message) { Task { await store.runSearch() } }
        }
    }

    private func list(_ messages: [MailMessage]) -> some View {
        let sections = !extras.events.isEmpty || !extras.people.isEmpty
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !extras.events.isEmpty {
                    Section {
                        ForEach(extras.events) { event in
                            SearchEventRow(event: event, highlight: store.highlightTerms) { open(event) }
                        }
                    } header: { header("Events") }
                }
                if !extras.people.isEmpty {
                    Section {
                        ForEach(extras.people) { person in
                            SearchPersonRow(person: person, accountID: account.id, store: store)
                        }
                    } header: { header("People") }
                }
                Section {
                    if messages.isEmpty {
                        Text("No messages match.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
                            .padding(.vertical, 8)
                    }
                    rows(messages)
                } header: {
                    if sections { header("Mail") }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
        }
        .frame(maxHeight: PopoverRootView.contentHeight)
        .task(id: messages.map(\.id)) {
            await store.loadRowDetails(for: messages, accountID: account.id)
        }
    }

    @ViewBuilder
    private func rows(_ messages: [MailMessage]) -> some View {
        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            if index > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
            }
            let folderName = extras.spansFolders ? extras.folderNames[message.id] : nil
            VStack(alignment: .leading, spacing: 0) {
                MessageRowView(message: message, accountID: account.id, store: store,
                               folder: folder(named: folderName), highlight: store.highlightTerms) {
                    store.actionError = nil
                    store.openMessage = .init(accountID: account.id, messageID: message.id)
                }
                if let folderName {
                    // Which folder, when the results come from several (Outlook's "In Folder").
                    Label(folderName, systemImage: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .labelStyle(SmallLabelStyle())
                        .padding(.leading, MessageRowView.Metrics.horizontalPadding + MessageRowView.Metrics.textIndent)
                        .padding(.top, -5)
                        .padding(.bottom, 6)
                        .accessibilityLabel("In \(folderName)")
                }
            }
        }
    }

    /// The standard folder a result's name stands for, so its row offers the right actions
    /// (no Archive in Archive, no Delete in Deleted Items).
    private func folder(named name: String?) -> MailFolder {
        guard let name else { return store.searchFolder }
        return MailFolder.standard.first { $0.title == name && $0 != .flagged } ?? .inbox
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityAddTraits(.isHeader)
    }

    /// The calendar window, on the event's day, with the event selected.
    private func open(_ event: CalendarEvent) {
        CalendarWindow.shared.show(mail: store)
        CalendarWindow.shared.store?.accountID = account.id
        CalendarWindow.shared.store?.anchor = event.start
        onOpenEvent(account.id, event.id)
    }
}

private struct SmallLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5))
            configuration.title
        }
    }
}

/// An event in the search's Events section: title, then day, time and place.
struct SearchEventRow: View {
    let event: CalendarEvent
    let highlight: [String]
    let onOpen: () -> Void

    @State private var hovering = false

    private var when: String {
        let thisYear = Calendar.current.isDate(event.start, equalTo: Date(), toGranularity: .year)
        let day = thisYear ? event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            : event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        guard !event.isAllDay else { return "\(day), all day" }
        let time = { (date: Date) in date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) }
        return "\(day), \(time(event.start)) to \(time(event.end))"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    DirectionalText(event.subject, font: .system(size: 12, weight: .medium),
                                    pinnedLeading: true, highlight: highlight)
                    Text(event.location.isEmpty ? when : "\(when) · \(event.location)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: event.isRecurring ? "repeat" : "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in Calendar")
    }
}

/// A person in the search's People section; a click shows their contact card with New
/// Message and Search Their Mail.
struct SearchPersonRow: View {
    let person: PersonSuggestion
    let accountID: UUID
    let store: MailStore

    @State private var open = false
    @State private var hovering = false

    private var subtitle: String {
        person.detail.isEmpty ? person.address : "\(person.address) · \(person.detail)"
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 9) {
                Avatar(name: person.display, size: 26, isGroup: person.isGroup)
                VStack(alignment: .leading, spacing: 1) {
                    DirectionalText(person.display, font: .system(size: 12, weight: .medium), pinnedLeading: true,
                                    highlight: store.highlightTerms)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(person.address)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ReaderPersonCard(name: person.display, address: person.address, accountID: accountID, store: store)
                Divider()
                HStack(spacing: 8) {
                    Button {
                        open = false
                        store.searchQuery = "from:" + person.address
                    } label: {
                        Label("Search Their Mail", systemImage: "magnifyingglass")
                    }
                    Spacer()
                    Button {
                        open = false
                        store.startMessage(to: person.address)
                    } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.regular)
                .padding(12)
            }
            .frame(width: 330)
            // Opaque, as the popover itself is: the glass under a child popover read dark.
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            #if DEBUG
            guard SearchQC.person == person.id else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            open = true
            #endif
        }
    }
}

#if DEBUG
/// Launch flags for the search's states, used with `--search=<text>` (`QCFlags.searchText`):
///
///     --search-scope=all | archive | folder     the scope
///     --search-deleted                          All Folders with Deleted Items
///     --search-criteria                         From sara, has attachments, the last 30 days
///     --search-options                          the Options popover open
///     --saved-searches                          two sample saved searches, the editor open
///     --search-save                             the "Save Search" name row
///     --search-person=<address>                 that person's card open
enum SearchQC {
    static var scope: SearchScope? {
        switch value("--search-scope=") {
        case "all": .allFolders
        case "archive": .onlineArchive
        case "folder": .thisFolder
        default: nil
        }
    }
    static var includeDeleted: Bool { CommandLine.arguments.contains("--search-deleted") }
    static var criteria: Bool { CommandLine.arguments.contains("--search-criteria") }
    static var options: Bool { CommandLine.arguments.contains("--search-options") }
    static var savedSearches: Bool { CommandLine.arguments.contains("--saved-searches") }
    static var naming: Bool { CommandLine.arguments.contains("--search-save") }
    static var person: String? { value("--search-person=")?.lowercased() }

    private static func value(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
#endif
