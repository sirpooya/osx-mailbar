import SwiftUI

struct SettingsView: View {
    @Bindable var accounts: AccountStore
    let client: EWSClient
    let directory: PeopleDirectory
    /// Called after an account is added, edited or deleted, so the menu bar refreshes.
    let onChange: () -> Void

    @AppStorage(Keys.pollMinutes) private var pollMinutes = 2
    @AppStorage(Keys.notifyNewMail) private var notifyNewMail = true
    @AppStorage(Keys.notificationDetails) private var notificationDetails = true
    @AppStorage(Keys.eventReminders) private var eventReminders = true
    @AppStorage(Keys.showToday) private var showToday = true
    @AppStorage(Keys.peopleDirectoryURL) private var directoryURL = ""
    @State private var launchAtLogin = false
    @State private var launchAtLoginMessage: String?

    /// The account open in the editor sheet. A fresh `Account` means "add".
    @State private var editing: EditorTarget?
    @State private var pendingDelete: Account?

    struct EditorTarget: Identifiable {
        let account: Account
        let isNew: Bool
        var id: UUID { account.id }
    }

    var body: some View {
        SettingsTabBody {
            accountsSection
            refreshSection
            notificationsSection
            directorySection
            generalSection
            privacySection
        }
        .onAppear {
            if QCFlags.openEditor { editing = EditorTarget(account: Account(), isNew: true) }
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
        SettingsRow(account.displayName, subtitle: accountSubtitle(account)) {
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
    }

    private func accountSubtitle(_ account: Account) -> String {
        [account.email, account.host].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Other sections

    private var refreshSection: some View {
        SettingsSection("Refresh",
                        footnote: "Mailbar checks the inbox on this interval and whenever you open it. Checking pauses while the Mac sleeps.") {
            SettingsRow("Check every") {
                Picker("", selection: $pollMinutes) {
                    ForEach(Keys.pollMinuteChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
                .onChange(of: pollMinutes) { _, _ in onChange() }
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSection("Notifications",
                        footnote: "macOS keeps notifications in Notification Center until they are cleared. Mailbar withdraws each one as soon as that message is read, archived or deleted. With details off, a notification names only the account.") {
            SettingsRow("Notify me about new mail") {
                SettingsSwitch(isOn: $notifyNewMail)
            }
            SettingsDivider()
            SettingsRow("Show sender and subject") {
                SettingsSwitch(isOn: $notificationDetails)
                    .disabled(!notifyNewMail && !eventReminders)
            }
            SettingsDivider()
            SettingsRow("Event reminders", subtitle: "One notification at each event's reminder time.") {
                SettingsSwitch(isOn: $eventReminders)
            }
            SettingsDivider()
            SettingsRow("Today tab in the popover", subtitle: "Today as a one-day calendar, beside the Inbox.") {
                SettingsSwitch(isOn: $showToday)
            }
        }
    }

    /// An optional JSON list of people (name, work email, team, department, photo). It adds the
    /// Team and Department picker to the event form and the composer, and its photos are shown
    /// for the addresses it lists.
    private var directorySection: some View {
        SettingsSection("People directory",
                        footnote: "Optional. An https address that returns a JSON list of people with their work email, team and department. It adds a team and department picker when inviting people or writing mail, and its photos are shown for the addresses it lists. Mailbar reads it with a plain request, keeps it in memory only, and loads photos from the same server without saving them.") {
            SettingsFieldRow(title: "Address", placeholder: "https://example.com/api/users", text: $directoryURL)
                .onChange(of: directoryURL) { _, _ in directory.reset() }
            SettingsDivider()
            SettingsRow(directoryStatus.title, subtitle: directoryStatus.subtitle) {
                Button(directory.phase == .loaded ? "Reload" : "Load") { Task { await directory.load() } }
                    .controlSize(.small)
                    .disabled(directoryURL.trimmingCharacters(in: .whitespaces).isEmpty || directory.phase == .loading)
            }
        }
    }

    private var directoryStatus: (title: String, subtitle: String?) {
        switch directory.phase {
        case .idle:
            return directoryURL.trimmingCharacters(in: .whitespaces).isEmpty
                ? ("Not set", nil) : ("Not loaded yet", "Loads the first time a picker opens.")
        case .loading:
            return ("Loading...", nil)
        case .failed(let message):
            return ("Could not load", message)
        case .loaded:
            let people = directory.people.count
            let teams = directory.teams(in: nil).count
            let departments = directory.departments.count
            return ("\(people) \(people == 1 ? "person" : "people")",
                    "\(teams) \(teams == 1 ? "team" : "teams") in \(departments) \(departments == 1 ? "department" : "departments")")
        }
    }

    private var generalSection: some View {
        SettingsSection("General", footnote: launchAtLoginMessage) {
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
        SettingsFootnote("Passwords are kept in your Keychain. Mail is held in memory only while Mailbar runs and is never written to disk, except an attachment you choose to open, which waits in a private temporary folder until Mailbar quits. Mailbar talks to your accounts' servers and, when you set one, the people directory, and nothing else.")
    }
}
