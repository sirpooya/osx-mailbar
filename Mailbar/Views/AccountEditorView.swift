import SwiftUI

/// The add and edit sheet. Same fields as Outlook for Mac's Exchange account sheet, nothing
/// prefilled: every value is the user's to type.
struct AccountEditorView: View {
    let isNew: Bool
    let hasSavedPassword: Bool
    let client: EWSClient
    let passwords: any PasswordStore
    let onSave: (Account, String?) throws -> Void
    let onCancel: () -> Void

    @State private var draft: Account
    /// Never loaded from the Keychain. Empty while editing means "keep the saved one".
    @State private var password = ""
    @State private var isTesting = false
    @State private var result: TestResult?

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    init(account: Account,
         isNew: Bool,
         hasSavedPassword: Bool,
         client: EWSClient,
         passwords: any PasswordStore,
         onSave: @escaping (Account, String?) throws -> Void,
         onCancel: @escaping () -> Void) {
        self.isNew = isNew
        self.hasSavedPassword = hasSavedPassword
        self.client = client
        self.passwords = passwords
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: account)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Exchange Account" : "Edit \(draft.displayName)")
                .font(.system(size: 15, weight: .semibold))
                .padding(.leading, SettingsMetrics.rowHPadding)

            SettingsSection("Account") {
                SettingsFieldRow(title: "Account description", placeholder: "Work", text: $draft.label)
                SettingsDivider()
                SettingsFieldRow(title: "Full name", placeholder: "Your name", text: $draft.fullName)
                SettingsDivider()
                SettingsFieldRow(title: "E-mail address", placeholder: "name@company.com", text: $draft.email)
            }

            SettingsSection("Server",
                            footnote: "The EWS address from Outlook: Preferences, Accounts, Advanced, Server. A bare host name works too.") {
                SettingsFieldRow(title: "Exchange server",
                                 placeholder: "mail.company.com",
                                 text: $draft.serverURL,
                                 monospaced: true)
                SettingsDivider()
                SettingsFieldRow(title: "User name", placeholder: "name or DOMAIN\\name", text: $draft.username)
                SettingsDivider()
                SettingsFieldRow(title: "Password",
                                 placeholder: hasSavedPassword ? "Saved in Keychain" : "Required",
                                 text: $password,
                                 secure: true)
            }

            if let result {
                resultLine(result)
                    .padding(.horizontal, SettingsMetrics.rowHPadding)
            }

            HStack(spacing: 8) {
                Button(isTesting ? "Testing..." : "Test Connection") {
                    Task { await test() }
                }
                .disabled(isTesting || validationProblem != nil)

                Spacer(minLength: 0)

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationProblem != nil)
            }
            .controlSize(.regular)

            if let problem = validationProblem {
                SettingsFootnote(problem)
            }
        }
        .padding(SettingsMetrics.bodyHPadding)
        .frame(width: SettingsMetrics.windowWidth + 40)
    }

    @ViewBuilder
    private func resultLine(_ result: TestResult) -> some View {
        switch result {
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Validation

    private var endpoint: URL? { Account.normalizedEndpoint(draft.serverURL) }

    /// The first thing stopping a save, or nil. Shown under the buttons so a disabled Save is
    /// never a mystery.
    private var validationProblem: String? {
        if draft.serverURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the Exchange server address."
        }
        if endpoint == nil {
            return "The server address must be an https address."
        }
        if draft.username.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter your user name."
        }
        if password.isEmpty && !hasSavedPassword {
            return "Enter your password."
        }
        return nil
    }

    private var credential: EWSCredential? {
        let typed = password
        let secret = typed.isEmpty ? passwords.password(for: draft.id) : typed
        guard let secret, !secret.isEmpty else { return nil }
        return EWSCredential(username: draft.username.trimmingCharacters(in: .whitespaces),
                             password: secret)
    }

    // MARK: - Actions

    private func test() async {
        guard let endpoint, let credential else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let status = try await client.inboxStatus(at: endpoint, credential: credential)
            let unread = status.unreadCount == 1 ? "1 unread message" : "\(status.unreadCount) unread messages"
            let version = status.version.map { ", \($0.label)" } ?? ""
            result = .success("Connected. Inbox has \(unread)\(version).")
        } catch let error as EWSError {
            result = .failure(error.message(host: endpoint.host ?? "The server"))
        } catch {
            result = .failure(error.localizedDescription)
        }
    }

    private func save() {
        guard let endpoint else { return }
        var account = draft
        account.label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        account.fullName = account.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        account.email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        account.username = account.username.trimmingCharacters(in: .whitespaces)
        account.serverURL = endpoint.absoluteString
        do {
            try onSave(account, password.isEmpty ? nil : password)
            password = ""
        } catch {
            result = .failure("The password could not be saved to the Keychain.")
        }
    }
}
