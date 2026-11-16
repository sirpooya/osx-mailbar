import SwiftUI

/// Settings, Mail (M23 to M25): how the composer starts, Undo Send, the addresses to send from,
/// and signatures. All configuration in UserDefaults; nothing from the mailbox.
struct MailSettingsSections: View {
    @Bindable var accounts: AccountStore

    @AppStorage(ComposeSettings.showCcBccKey) private var showBcc = false
    @AppStorage(ComposeSettings.alwaysCcMeKey) private var alwaysCc = false
    @AppStorage(ComposeSettings.alwaysBccMeKey) private var alwaysBcc = false
    @AppStorage(ComposeSettings.undoSendSecondsKey) private var undoSeconds = 5
    @AppStorage(ComposeSettings.fromAddressesKey) private var fromAddresses = ""
    @State private var signatures = ComposeSettings.signatures()
    @State private var editing: UUID?
    /// Bumped when a per-account choice changes, so the pickers read it again.
    @State private var choicesVersion = 0

    var body: some View {
        writingSection
        signaturesSection
        if !signatures.isEmpty, !accounts.accounts.isEmpty { defaultsSection }
        sendFromSection
            .onAppear {
                // `--settings-signature` (DEBUG, mock): a sample signature open in the editor,
                // shown only, not saved.
                guard ComposeQC.value("--settings-signature") != nil, signatures.isEmpty else { return }
                let sample = Signature(name: "Work", text: "Sample User\nDesign Systems, Example Co\n+1 555 0100")
                signatures = [sample, Signature(name: "Short", text: "Sample")]
                editing = sample.id
            }
    }

    private var writingSection: some View {
        SettingsSection("Writing", footnote: "Undo Send holds a message this long before it goes.") {
            SettingsRow("Undo Send") {
                Picker("", selection: $undoSeconds) {
                    ForEach(ComposeSettings.undoChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow("Show Bcc") { SettingsSwitch(isOn: $showBcc) }
            SettingsDivider()
            SettingsRow("Always Cc me") { SettingsSwitch(isOn: $alwaysCc) }
            SettingsDivider()
            SettingsRow("Always Bcc me") { SettingsSwitch(isOn: $alwaysBcc) }
        }
    }

    private var signaturesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader(text: "Signatures")
            SettingsCard {
                if signatures.isEmpty {
                    SettingsRow("No signatures yet") { EmptyView() }
                }
                ForEach(Array(signatures.enumerated()), id: \.element.id) { index, signature in
                    if index > 0 { SettingsDivider() }
                    if editing == signature.id {
                        signatureEditor(index)
                    } else {
                        SettingsRow(signature.name.isEmpty ? "Untitled" : signature.name) {
                            HStack(spacing: 6) {
                                Button("Edit...") { editing = signature.id }
                                Button("Delete") { delete(signature.id) }
                            }
                            .controlSize(.small)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = signature.id }
                    }
                }
            }
            SettingsCardActions {
                Button("Add Signature...") {
                    let signature = Signature(name: "Signature \(signatures.count + 1)", text: "")
                    signatures.append(signature)
                    editing = signature.id
                    save()
                }
            }
        }
    }

    private func signatureEditor(_ index: Int) -> some View {
        SettingsBlock {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: Binding(get: { signatures[index].name },
                                                set: { signatures[index].name = $0; save() }))
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: Binding(get: { signatures[index].text },
                                         set: { signatures[index].text = $0; save() }))
                    .font(.system(size: 13))
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                HStack {
                    Spacer()
                    Button("Done") { editing = nil }.controlSize(.small)
                }
            }
        }
    }

    /// Which signature each account adds, to new mail and to replies and forwards.
    private var defaultsSection: some View {
        SettingsSection("Signature for each account") {
            ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { SettingsDivider() }
                SettingsRow("\(account.displayName): new") {
                    signaturePicker(ComposeSettings.newSignatureKey, account: account.id)
                }
                SettingsDivider()
                SettingsRow("\(account.displayName): replies") {
                    signaturePicker(ComposeSettings.replySignatureKey, account: account.id)
                }
            }
        }
    }

    private func signaturePicker(_ key: String, account: UUID) -> some View {
        Picker("", selection: Binding(
            get: { _ = choicesVersion; return ComposeSettings.signatureChoice(key, account: account) },
            set: {
                ComposeSettings.setSignatureChoice(key, account: account, signature: $0)
                choicesVersion += 1
            })) {
            Text("None").tag(UUID?.none)
            ForEach(signatures) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag(UUID?.some($0.id)) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private var sendFromSection: some View {
        SettingsSection("Send from", footnote: "Aliases or mailboxes you may send as. Your server decides.") {
            SettingsFieldRow(title: "Other addresses", placeholder: "alias@example.com", text: $fromAddresses)
        }
    }

    private func delete(_ id: UUID) {
        signatures.removeAll { $0.id == id }
        if editing == id { editing = nil }
        save()
    }

    private func save() { ComposeSettings.setSignatures(signatures) }
}
