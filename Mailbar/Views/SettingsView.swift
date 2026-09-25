import SwiftUI

struct SettingsView: View {
    @Bindable var accounts: AccountStore
    let client: EWSClient
    let directory: PeopleDirectory
    /// Called after an account is added, edited or deleted, so the menu bar refreshes.
    let onChange: () -> Void

    @AppStorage(Keys.pollMinutes) private var pollMinutes = 2
    @AppStorage(Keys.notifyNewMail) private var notifyNewMail = true
    @AppStorage(Keys.eventReminders) private var eventReminders = true
    @AppStorage(Keys.peopleDirectoryURL) private var directoryURL = ""
    @State private var launchAtLogin = false
    @State private var directoryDraft = ""
    @State private var editingDirectory = false
    @State private var launchAtLoginMessage: String?

    /// The account open in the editor sheet. A fresh `Account` means "add".
    @State private var editing: EditorTarget?
    @State private var pendingDelete: Account?

    struct EditorTarget: Identifiable {
        let account: Account
        let isNew: Bool
        var id: UUID { account.id }
    }

    /// Three tabs (the user's split, 2026-09-25): refresh, notifications and startup on General,
    /// the account list on Accounts, event reminders and the people directory on Calendar. Kept while the window lives.
    @State private var tab: SettingsTab = QCFlags.settingsTab ?? .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.primary.opacity(0.03))
            switch tab {
            case .general:
                SettingsTabBody {
                    refreshSection
                    notificationsSection
                    generalSection
                    privacySection
                }
            case .accounts:
                SettingsTabBody { accountsSection }
            case .calendar:
                SettingsTabBody {
                    calendarSection
                    directorySection
                }
            }
        }
        .onAppear {
            // With no account yet, Settings is opened to add one.
            if accounts.accounts.isEmpty, QCFlags.settingsTab == nil { tab = .accounts }
            if QCFlags.openEditor {
                tab = .accounts
                editing = EditorTarget(account: Account(), isNew: true)
            }
        }
        .sheet(item: $editing) { target in
            AccountEditorView(account: target.account,
                              isNew: target.isNew,
                              hasSavedPassword: accounts.hasPassword(target.account.id),
                              client: client,
                              passwords: accounts.passwords,
                              onSave: { account, password in
                                  try accounts.save(account, password: password)
                                  editing = nil
                                  onChange()
                              },
                              onCancel: { editing = nil })
        }
        .alert("Delete \(pendingDelete?.displayName ?? "this account")?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { account in
            Button("Delete", role: .destructive) {
                accounts.delete(account.id)
                pendingDelete = nil
                onChange()
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Mailbar forgets the account and removes its password from your Keychain. Nothing on the mail server changes.")
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader(text: "Accounts")
            SettingsCard {
                if accounts.accounts.isEmpty {
                    SettingsRow("No accounts yet",
                                subtitle: "Add your Exchange account with the same details Outlook uses.") {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { SettingsDivider() }
                        accountRow(account)
                    }
                }
            }
            SettingsCardActions {
                Button("Add Account...") {
                    editing = EditorTarget(account: Account(), isNew: true)
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        SettingsRow(account.displayName) {
            HStack(spacing: 6) {
                if !accounts.hasPassword(account.id) {
                    Label("No password", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help("No password saved for this account")
                }
                Button("Edit...") {
                    editing = EditorTarget(account: account, isNew: false)
                }
                Button("Delete") { pendingDelete = account }
            }
            .controlSize(.small)
        }
        // A click anywhere on the row opens its editor (the user's call); the buttons keep
        // their own clicks.
        .contentShape(Rectangle())
        .onTapGesture { editing = EditorTarget(account: account, isNew: false) }
    }

    // MARK: - Other sections

    private var refreshSection: some View {
        SettingsSection("Refresh",
                        footnote: "Also checked each time you open Mailbar.") {
            SettingsRow("Check every") {
                Picker("", selection: $pollMinutes) {
                    ForEach(Keys.pollMinuteChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .onChange(of: pollMinutes) { _, _ in onChange() }
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSection("Notifications",
                        footnote: "Withdrawn once the message is read, archived or deleted.") {
            SettingsRow("Notify me about new mail") {
                SettingsSwitch(isOn: $notifyNewMail)
            }
        }
    }

    private var calendarSection: some View {
        SettingsSection("Calendar") {
            SettingsRow("Event reminders") {
                SettingsSwitch(isOn: $eventReminders)
            }
        }
    }

    // MARK: - Tabs

    /// osx-launchpad's tab bar: right under the floating close button, 8 pt between items.
    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { item in
                SettingsTabItem(tab: item, isSelected: tab == item) { tab = item }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    /// An optional JSON list of people (name, work email, team, department, photo). It adds the
    /// Team and Department picker to the event form and the composer, and its photos are shown
    /// for the addresses it lists. Shown like the compliance-audit plugin's endpoints: a status
    /// dot, the saved address locked behind Edit, and Connect to read a new one.
    private var directorySection: some View {
        SettingsSection("People directory",
                        footnote: "Optional. People for the team pickers and photos.") {
            HStack(spacing: 8) {
                Circle().fill(directoryDot).frame(width: 7, height: 7)
                    .help(directoryFailure ?? directoryStatus)
                Text("Address").font(.system(size: 13))
                TextField("https://example.com/api/users", text: $directoryDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13))
                    .foregroundStyle(directoryLocked ? .secondary : .primary)
                    .disabled(directoryLocked)
                    .onSubmit { Task { await connectDirectory() } }
                if directoryLocked {
                    Button("Edit") { editingDirectory = true }
                } else {
                    Button("Connect") { Task { await connectDirectory() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(directory.phase == .loading)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, SettingsMetrics.rowHPadding)
            .frame(minHeight: SettingsMetrics.rowHeight)
            if !directoryURL.trimmingCharacters(in: .whitespaces).isEmpty || directoryFailure != nil {
                SettingsDivider()
                SettingsRow(directoryStatus) {
                    if let read = directory.lastReadAt, directory.phase != .loading, directoryFailure == nil {
                        Text("Read \(read.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if directory.phase == .loading {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                }
                .foregroundStyle(directoryFailure == nil ? Color.primary : Color.red)
                .help(directoryFailure ?? "")
            }
        }
        .onAppear { directoryDraft = directoryURL }
        .task {
            // Checked each time Settings shows it, so the dot says whether it works now.
            if !directoryURL.trimmingCharacters(in: .whitespaces).isEmpty { await directory.loadIfNeeded() }
        }
    }

    /// Locked while an address is saved and not being edited.
    private var directoryLocked: Bool {
        !editingDirectory && !directoryURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Saves the typed address and reads it. It locks again only once it has worked; a failed
    /// read leaves it open with the reason under it.
    private func connectDirectory() async {
        let address = directoryDraft.trimmingCharacters(in: .whitespaces)
        directoryDraft = address
        if address != directoryURL { directoryURL = address; directory.reset() }
        guard !address.isEmpty else { editingDirectory = false; return }
        await directory.load()
        if directory.phase == .loaded { editingDirectory = false }
    }

    private var directoryFailure: String? {
        if case .failed(let message) = directory.phase { return message }
        return nil
    }

    /// Green when the last read worked, red when it failed, amber while only the remembered count
    /// is known, grey when no address is set.
    private var directoryDot: Color {
        if directoryURL.trimmingCharacters(in: .whitespaces).isEmpty { return Color(white: 0.8) }
        switch directory.phase {
        case .loaded: return Color(red: 0.04, green: 0.81, blue: 0.51)
        case .failed: return Color(red: 0.95, green: 0.31, blue: 0.12)
        case .idle, .loading: return Color(red: 1, green: 0.76, blue: 0.03)
        }
    }

    private var directoryStatus: String {
        if case .failed = directory.phase { return "Could not load" }
        let count = directory.phase == .loaded ? directory.people.count : directory.lastCount
        guard let count else { return directory.phase == .loading ? "Loading..." : "Not read yet" }
        return "\(count) \(count == 1 ? "person" : "people")"
    }

    private var generalSection: some View {
        SettingsSection("Startup", footnote: launchAtLoginMessage) {
            SettingsRow("Launch at login") {
                SettingsSwitch(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LaunchAtLogin.isEnabled else { return }
                        launchAtLoginMessage = LaunchAtLogin.set(enabled)
                        // Write back what macOS actually did, not what was asked for.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private var privacySection: some View {
        SettingsFootnote("Passwords stay in your Keychain. Mail is never written to disk.")
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case accounts = "Accounts"
    case calendar = "Calendar"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .accounts: return "at"
        case .calendar: return "calendar"
        }
    }
}

/// Glyph over label, accent when selected, on a faint grey pill (osx-launchpad's tab button).
private struct SettingsTabItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                Text(tab.rawValue)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(width: 72)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.04) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
