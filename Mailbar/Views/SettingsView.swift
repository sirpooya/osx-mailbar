import SwiftUI

struct SettingsView: View {
    @Bindable var accounts: AccountStore
    let client: EWSClient
    /// Called after an account is added, edited or deleted, so the menu bar refreshes.
    let onChange: () -> Void

    @AppStorage(Keys.pollMinutes) private var pollMinutes = 2

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

    private var privacySection: some View {
        SettingsFootnote("Passwords are kept in your Keychain. Mail is held in memory only while Mailbar runs and is never written to disk. Mailbar talks to your accounts' servers and nothing else.")
    }
}
