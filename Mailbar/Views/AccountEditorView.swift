import AppKit
import SwiftUI

/// The add and edit sheet.
///
/// Adding asks for two things, the email address and the password, and Sign In finds the rest
/// with Autodiscover: the server, the display name, and which form of user name the server takes.
/// Everything it found then appears under Server Details, editable, and the connection has
/// already been tested. When Autodiscover is not available the same fields open empty to be
/// typed, as in Outlook for Mac's own sheet. Nothing is ever prefilled from anything but the
/// user's own server.
///
/// Editing an existing account shows every field straight away.
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
    @State private var isWorking = false
    @State private var result: TestResult?
    /// Whether Server Details is open. Always, when editing; after Sign In, when adding.
    @State private var showsDetails: Bool
    /// Whether Autodiscover filled Server Details, so the footnote never claims it did otherwise.
    @State private var discovered = false
    /// Logins already in the login Keychain for this address. Attributes only, no passwords.
    @State private var savedLogins: [LoginKeychain.Item] = []
    /// The saved login the password field was filled from, if any.
    @State private var usedLogin: LoginKeychain.Item?
    /// Mock mode never reads the real Keychain.
    private let loginKeychain: any SavedLogins = MockMode.current != nil ? MockSavedLogins() : LoginKeychain()

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
        case progress(String)
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
        _showsDetails = State(initialValue: !isNew)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Only a new account gets a heading; editing opens straight on its fields (the
            // user's call, 2026-09-25).
            if isNew {
                Text("Add Exchange Account")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.leading, SettingsMetrics.rowHPadding)
            }

            SettingsSection(isNew && !showsDetails ? nil : "Account",
                            footnote: isNew && !showsDetails
                                ? "Mailbar asks your company's Exchange server for the rest, the way Outlook does."
                                : nil) {
                SettingsFieldRow(title: "E-mail address", placeholder: "name@company.com", text: $draft.email)
                SettingsDivider()
                SettingsFieldRow(title: "Password",
                                 placeholder: hasSavedPassword ? "Saved in Keychain" : "Required",
                                 text: $password,
                                 secure: true)
            }

            if isNew { savedLoginLine }

            if showsDetails { details }

            if let result {
                resultLine(result)
                    .padding(.horizontal, SettingsMetrics.rowHPadding)
            }

            buttons

            if showsDetails, let problem = validationProblem {
                SettingsFootnote(problem)
            }
        }
        .padding(SettingsMetrics.bodyHPadding)
        .frame(width: SettingsMetrics.windowWidth + 40)
        .animation(.snappy(duration: 0.25), value: showsDetails)
        .task(id: draft.email) {
            guard isNew else { return }
            // Settle on the address before looking, not on every keystroke.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            savedLogins = loginKeychain.items(forEmail: draft.email)
            if let usedLogin, !savedLogins.contains(usedLogin) {
                self.usedLogin = nil
                password = ""
            }
        }
        .onChange(of: password) {
            if password.isEmpty { usedLogin = nil }
        }
        // Opens with no field focused (the user's call, 2026-09-25): a sheet makes its first text
        // field first responder by itself, so that is undone once the sheet is up.
        .task {
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .task {
            guard isNew else { return }
            if QCFlags.editorEmail { draft.email = MockMode.accounts[0].email }
            guard QCFlags.editorSignIn else { return }
            draft.email = MockMode.accounts[0].email
            password = "mock"
            await signIn()
        }
    }

    /// "Keychain Access has a saved password for mail.example.com. Use It", under the password
    /// field. Pressing Use It is what reads the password, and macOS asks first.
    @ViewBuilder
    private var savedLoginLine: some View {
        if let usedLogin, !password.isEmpty {
            Label("Using the password saved in Keychain Access for \(usedLogin.server).",
                  systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SettingsMetrics.rowHPadding)
        } else if password.isEmpty, let first = savedLogins.first {
            HStack(spacing: 8) {
                Label(savedLogins.count == 1
                          ? "Keychain Access has a saved password for \(first.server)."
                          : "Keychain Access has \(savedLogins.count) saved passwords for this address.",
                      systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if savedLogins.count == 1 {
                    Button("Use It") { Task { await use(first) } }
                } else {
                    Menu("Use One") {
                        ForEach(savedLogins) { item in
                            Button("\(item.server) (\(item.account))") { Task { await use(item) } }
                        }
                    }
                    .fixedSize()
                }
            }
            .controlSize(.small)
            .disabled(isWorking)
            .padding(.horizontal, SettingsMetrics.rowHPadding)
        }
    }

    private var details: some View {
        SettingsSection("Server Details",
                        footnote: discovered
                            ? "Filled in from your server. Change anything that is not right."
                            : "The EWS address from Outlook: Preferences, Accounts, Advanced, Server. A bare host name works too.") {
            SettingsFieldRow(title: "Exchange server", placeholder: "mail.company.com",
                             text: $draft.serverURL, monospaced: true)
            SettingsDivider()
            SettingsFieldRow(title: "User name", placeholder: "name or DOMAIN\\name", text: $draft.username)
            SettingsDivider()
            SettingsFieldRow(title: "Full name", placeholder: "Your name", text: $draft.fullName)
            SettingsDivider()
            SettingsFieldRow(title: "Account description", placeholder: "Work", text: $draft.label)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            if showsDetails {
                Button(isWorking ? "Testing..." : "Test Connection") {
                    Task { await test() }
                }
                .disabled(isWorking || validationProblem != nil)
            } else {
                Button("Enter Server Details Manually") { showsDetails = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            if showsDetails {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || validationProblem != nil)
            } else {
                Button(isWorking ? "Signing In..." : "Sign In") {
                    Task { await signIn() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || Autodiscover.domain(of: draft.email) == nil || password.isEmpty)
            }
        }
        .controlSize(.regular)
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
        case .progress(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private var secret: String? {
        let value = password.isEmpty ? passwords.password(for: draft.id) : password
        return (value?.isEmpty ?? true) ? nil : value
    }

    // MARK: - Actions

    /// Autodiscover, then the same test as Test Connection, so a found account is also a working
    /// one before the user ever presses Save.
    private func signIn() async {
        guard let secret else { return }
        isWorking = true
        defer { isWorking = false }
        result = .progress("Looking up your server...")

        do {
            let found = try await Autodiscover(transport: client.transport)
                .discover(email: draft.email, password: secret)
            draft.serverURL = found.ewsURL.absoluteString
            draft.username = found.username
            if draft.fullName.isEmpty { draft.fullName = found.displayName }
            if draft.label.isEmpty { draft.label = draft.email.trimmingCharacters(in: .whitespaces) }
            discovered = true
            showsDetails = true
            await runTest(url: found.ewsURL, username: found.username, password: secret)
        } catch Autodiscover.Failure.passwordRejected {
            result = .failure("The server did not accept that password. Check it and try again.")
        } catch Autodiscover.Failure.notFound(let reason) {
            if draft.username.isEmpty, let local = Autodiscover.usernames(for: draft.email).first {
                draft.username = local
            }
            discovered = false
            showsDetails = true
            result = .failure("\(reason) Enter the server below.")
        } catch {
            result = .failure("That does not look like an email address.")
        }
    }

    /// Reads the chosen login's password off the main thread, since macOS holds the call while
    /// it asks permission. The password goes into the field and nowhere else until Save.
    private func use(_ item: LoginKeychain.Item) async {
        let source = loginKeychain
        do {
            let secret = try await Task.detached { try source.password(for: item) }.value
            password = secret
            usedLogin = item
            result = nil
        } catch let error as LoginKeychain.LookupError {
            result = .failure(error.message)
        } catch {
            result = .failure(error.localizedDescription)
        }
    }

    private func test() async {
        guard let endpoint, let secret else { return }
        isWorking = true
        defer { isWorking = false }
        await runTest(url: endpoint, username: draft.username.trimmingCharacters(in: .whitespaces), password: secret)
    }

    private func runTest(url: URL, username: String, password: String) async {
        result = .progress("Connecting...")
        do {
            let status = try await client.inboxStatus(at: url, credential: EWSCredential(username: username, password: password))
            let unread = status.unreadCount == 1 ? "1 unread message" : "\(status.unreadCount) unread messages"
            let version = status.version.map { ", \($0.label)" } ?? ""
            result = .success("Connected. Inbox has \(unread)\(version).")
        } catch let error as EWSError {
            result = .failure(error.message(host: url.host ?? "The server"))
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
