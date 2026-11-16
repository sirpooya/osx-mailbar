import AppKit
import SwiftUI

/// Writing a reply, reply all, forward or new message (M12 to M14), with since M23 to M25 Bcc,
/// a From choice, Outlook's message options, Check Names, MailTips, formatting, files,
/// signatures, templates and a copy kept in the server's Drafts folder as you type.
struct ComposeView: View {
    @Bindable var store: MailStore
    let onClose: () -> Void

    @State private var confirmingDiscard = false
    @FocusState private var focus: Field?
    /// What to offer under the field being typed in, from the people directory, the Exchange
    /// directory and inbox senders.
    @State private var suggestions: [PersonSuggestion] = []
    /// The field whose Team and Department picker is open.
    @State private var pickingFor: Field?
    @State private var expanding: Set<String> = []
    @State private var groupProblem: String?
    @State private var showsBcc = ComposeSettings.showCcBcc()
    @State private var editor = RichEditorController()
    @State private var mentionSuggestions: [PersonSuggestion] = []
    @State private var editingLink = false
    @State private var linkText = ""

    private enum Field { case to, cc, bcc, subject }

    static let editorHeight: CGFloat = 220

    var body: some View {
        if let draft = store.draft {
            VStack(spacing: 0) {
                toolbar(draft)
                Divider().opacity(0.5)
                if confirmingDiscard { discardBanner }
                notices
                fields(draft)
                Divider().opacity(0.5)
                formatBar(draft)
                Divider().opacity(0.5)
                if !mentionSuggestions.isEmpty { mentionStrip }
                RichComposeEditor(controller: editor, initial: initialText(draft), plain: draft.body,
                                  onSend: { store.sendWithUndo() },
                                  onDropFiles: { store.attach($0) })
                    .frame(height: Self.editorHeight)
                if let quote = draft.quotedSelection { selectionQuote(quote) }
                if !draft.attachments.isEmpty || !draft.keptFiles.isEmpty || store.compose.isPreparing {
                    attachmentStrip(draft)
                }
                footer(draft)
            }
            .onAppear { appeared() }
            // Closing the composer keeps the message in the server's Drafts folder.
            .onDisappear {
                guard store.draft?.hasContent == true else { return }
                Task { await store.saveDraftToServer() }
            }
            .onChange(of: store.draft?.fingerprint) { _, _ in store.scheduleAutosave() }
            // MailTips once the addresses settle.
            .task(id: draft.allRecipients.joined(separator: ",")) {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                await store.refreshMailTips()
            }
            .task(id: editor.mentionQuery) {
                guard let query = editor.mentionQuery else { mentionSuggestions = []; return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let found = await store.peopleSuggestions(for: query, excluding: "", accountID: draft.accountID, limit: 5)
                guard !Task.isCancelled, editor.mentionQuery == query else { return }
                mentionSuggestions = found
            }
            // A new message or a forward opens with the cursor in To. Set once the composer is on
            // screen, not in onAppear: set while it slid in, the focus was dropped and AppKit put
            // the cursor in Cc (the user's screenshot, 2026-09-25).
            .task {
                guard draft.kind == .forward || draft.kind == .new, draft.to.isEmpty else { return }
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    focus = .to
                }
            }
            .task {
                if draft.kind == .new, store.compose.templates.isEmpty { await store.loadTemplates() }
            }
            .background {
                Button("") { Task { await store.checkNames() } }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func appeared() {
        store.prepareDraft()
        if store.draft?.bcc.isEmpty == false { showsBcc = true }
        editor.onChange = { [store] text in
            guard store.draft != nil else { return }
            if store.draft?.body != text.string { store.draft?.body = text.string }
            let html = RichHTML.hasFormatting(text) ? RichHTML.html(from: text) : nil
            if store.draft?.bodyHTML != html { store.draft?.bodyHTML = html }
            store.compose.richText = NSAttributedString(attributedString: text)
            store.compose.richDraftID = store.draft?.id
        }
        ComposeQC.apply(store: store, editor: editor, showsBcc: $showsBcc)
    }

    /// The stored rich text when coming back to the same draft, else its plain text.
    private func initialText(_ draft: Draft) -> NSAttributedString {
        if store.compose.richDraftID == draft.id, let rich = store.compose.richText, rich.string == draft.body { return rich }
        return NSAttributedString(string: draft.body, attributes: [.font: RichEditorController.baseFont])
    }

    // MARK: - Toolbar

    private func toolbar(_ draft: Draft) -> some View {
        HStack(spacing: 10) {
            Button {
                if draft.hasContent { confirmingDiscard = true } else { store.discardDraftEverywhere(); onClose() }
            } label: {
                Text("Cancel").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Discard this message")

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if draft.options.importance == .high {
                    Image(systemName: "exclamationmark").foregroundStyle(.red).help("High importance")
                } else if draft.options.importance == .low {
                    Image(systemName: "arrow.down").foregroundStyle(.blue).help("Low importance")
                }
                Text(draft.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .font(.system(size: 11, weight: .bold))
            Spacer(minLength: 0)

            optionsMenu(draft)

            if draft.isSending || store.compose.isSendingHeld {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 40)
            } else {
                Button {
                    store.sendWithUndo()
                } label: {
                    Label("Send", systemImage: "paperplane.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draft.sendProblem != nil || store.compose.isPreparing)
                .help(draft.sendProblem ?? "Send  ⌘↩")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Outlook's Options, plus drafts and templates.
    private func optionsMenu(_ draft: Draft) -> some View {
        Menu {
            Picker("Importance", selection: binding(\.options.importance)) {
                ForEach(MessageOptions.Importance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Sensitivity", selection: binding(\.options.sensitivity)) {
                ForEach(MessageOptions.Sensitivity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Request a Read Receipt", isOn: binding(\.options.readReceipt))
            Toggle("Request a Delivery Receipt", isOn: binding(\.options.deliveryReceipt))
            Divider()
            Toggle("Show Bcc", isOn: $showsBcc)
            Button("Check Names  ⌘K") { Task { await store.checkNames() } }
            Divider()
            Button("Save Draft") { Task { await store.saveDraftToServer() } }
                .disabled(!draft.hasContent)
            Button("Save as Template") { Task { await store.saveAsTemplate() } }
                .disabled(!draft.hasContent)
            if draft.kind == .new {
                Menu("Use a Template") {
                    if store.compose.templates.isEmpty {
                        Text(store.compose.templatesLoading ? "Loading..." : "No templates in Drafts, Templates")
                    }
                    ForEach(store.compose.templates) { template in
                        Button(template.subject.isEmpty ? "(No subject)" : template.subject) {
                            Task { await store.applyTemplate(template.id) }
                        }
                    }
                    Divider()
                    Button("Refresh") { Task { await store.loadTemplates() } }
                }
            }
            Divider()
            Button("Remove Formatting") { editor.clearFormatting() }
                .disabled(draft.bodyHTML == nil)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(draft.options.isDefault ? .secondary : Color.accentColor)
        .help("Options, drafts and templates")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Draft, Value>) -> Binding<Value> {
        Binding(get: { store.draft?[keyPath: keyPath] ?? Draft.placeholder[keyPath: keyPath] },
                set: { store.draft?[keyPath: keyPath] = $0 })
    }

    private var discardBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash").foregroundStyle(.orange)
            Text("Discard this message?")
            Spacer(minLength: 4)
            Button("Keep Writing") { confirmingDiscard = false }
            Button("Save Draft") {
                confirmingDiscard = false
                Task {
                    if await store.saveAndCloseDraft() { onClose() }
                }
            }
            Button("Discard") {
                confirmingDiscard = false
                store.discardDraftEverywhere()
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
    }

    @ViewBuilder
    private var notices: some View {
        if store.compose.asksToCreateTemplates {
            noticeRow("folder.badge.plus", tint: .accentColor, "Drafts has no Templates folder yet.") {
                Button("Create and Save") { Task { await store.saveAsTemplate(create: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { store.compose.asksToCreateTemplates = false }
            }
        }
        if let failure = store.compose.sendFailure {
            noticeRow("exclamationmark.triangle.fill", tint: .orange, failure) {
                Button("Dismiss") { store.compose.sendFailure = nil }
            }
        }
        if let notice = store.compose.notice {
            noticeRow("checkmark.circle.fill", tint: .green, notice) {
                Button("OK") { store.compose.notice = nil }
            }
        }
    }

    private func noticeRow<Actions: View>(_ symbol: String, tint: Color, _ text: String,
                                          @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack(spacing: 6) { actions() }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10))
    }

    // MARK: - Fields

    private func fields(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let aliases = ComposeSettings.fromAddresses()
            if !aliases.isEmpty || !draft.from.isEmpty {
                fromRow(draft, aliases: aliases)
                thinDivider
            }
            recipientField("To", text: Binding(get: { store.draft?.to ?? "" }, set: { store.draft?.to = $0 }),
                           other: draft.cc + ", " + draft.bcc, field: .to, accountID: draft.accountID)
            thinDivider
            recipientField("Cc", text: Binding(get: { store.draft?.cc ?? "" }, set: { store.draft?.cc = $0 }),
                           other: draft.to + ", " + draft.bcc, field: .cc, accountID: draft.accountID)
            if showsBcc {
                thinDivider
                recipientField("Bcc", text: Binding(get: { store.draft?.bcc ?? "" }, set: { store.draft?.bcc = $0 }),
                               other: draft.to + ", " + draft.cc, field: .bcc, accountID: draft.accountID)
            }
            if let groupProblem {
                Label(groupProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            unresolvedLines(draft)
            tipLines
            thinDivider
            HStack(spacing: 6) {
                label("Subject")
                if draft.kind == .new {
                    TextField("", text: Binding(get: { store.draft?.subject ?? "" },
                                                set: { store.draft?.subject = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($focus, equals: .subject)
                } else {
                    DirectionalText(draft.subjectPreview, font: .system(size: 12))
                        .foregroundStyle(.secondary)
                        .help("Your server sets the subject, as Outlook does.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// From: the account, or an alias or mailbox listed in Settings. The server decides whether
    /// the account may send as it.
    private func fromRow(_ draft: Draft, aliases: [String]) -> some View {
        let me = store.accounts.account(draft.accountID)?.email ?? ""
        return HStack(spacing: 6) {
            label("From")
            Picker("", selection: binding(\.from)) {
                Text(me.isEmpty ? "This account" : me).tag("")
                ForEach(aliases.filter { $0.lowercased() != me.lowercased() }, id: \.self) { Text($0).tag($0) }
                if !draft.from.isEmpty, !aliases.contains(draft.from) { Text(draft.from).tag(draft.from) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Entries that are not addresses, in red: what Check Names found for each, or a way to ask.
    @ViewBuilder
    private func unresolvedLines(_ draft: Draft) -> some View {
        let entries = draft.allRecipients.filter { !Recipients.isValid($0) && Recipients.currentToken(in: draft.to) != $0 }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(Set(entries)).sorted(), id: \.self) { entry in
                    HStack(spacing: 5) {
                        Text(entry).foregroundStyle(.red).fontWeight(.medium).lineLimit(1)
                        if let found = store.compose.unresolved[entry] {
                            if found.isEmpty {
                                Text("No one by that name.").foregroundStyle(.secondary)
                            } else {
                                ForEach(found.prefix(3)) { person in
                                    Button(person.display) { store.resolve(entry, as: person) }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                        .help(person.address)
                                }
                            }
                        } else if store.compose.isCheckingNames {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button("Check Names") { Task { await store.checkNames() } }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.leading, 68)
            .padding(.trailing, 12)
            .padding(.bottom, 4)
        }
    }

    /// MailTips under the recipients, as Outlook shows them above the message.
    @ViewBuilder
    private var tipLines: some View {
        let lines = store.mailTipLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in
                    Label {
                        Text(line).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.07))
        }
    }

    // MARK: - Formatting bar

    private func formatBar(_ draft: Draft) -> some View {
        HStack(spacing: 2) {
            formatButton("bold", on: editor.isBold, help: "Bold  ⌘B") { editor.toggleBold() }
                .keyboardShortcut("b", modifiers: .command)
            formatButton("italic", on: editor.isItalic, help: "Italic  ⌘I") { editor.toggleItalic() }
                .keyboardShortcut("i", modifiers: .command)
            formatButton("underline", on: editor.isUnderlined, help: "Underline  ⌘U") { editor.toggleUnderline() }
                .keyboardShortcut("u", modifiers: .command)
            Divider().frame(height: 14).padding(.horizontal, 4)
            formatButton("list.bullet", on: false, help: "Bulleted list") { editor.toggleList(.bulleted) }
            formatButton("list.number", on: false, help: "Numbered list") { editor.toggleList(.numbered) }
            formatButton("link", on: false, help: "Link") {
                linkText = ""
                editingLink = true
            }
            .popover(isPresented: $editingLink, arrowEdge: .bottom) { linkEditor }
            Spacer(minLength: 0)
            formatButton("person.crop.circle.badge.checkmark", on: false, help: "Check Names  ⌘K") {
                Task { await store.checkNames() }
            }
            formatButton("paperclip", on: false, help: "Attach files, or drop them on the message") { pickFiles() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func formatButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.accentColor : .secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private var linkEditor: some View {
        HStack(spacing: 6) {
            TextField("https://example.com", text: $linkText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(applyLink)
            Button("Add Link", action: applyLink)
                .keyboardShortcut(.defaultAction)
                .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
        .padding(10)
    }

    private func applyLink() {
        editor.setLink(linkText)
        editingLink = false
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        WindowActivation.claim()
        if panel.runModal() == .OK { store.attach(panel.urls) }
    }

    private var mentionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Image(systemName: "at").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(mentionSuggestions) { person in
                    Button {
                        editor.completeMention(person)
                        store.addMention(person)
                        mentionSuggestions = []
                    } label: {
                        Text(person.name.isEmpty ? person.address : "\(person.name)  \(person.address)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Mention \(person.display): adds them to To")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    /// Reply to Selection: what will be quoted, and a way back to quoting the whole message.
    private func selectionQuote(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
            DirectionalText(quote, font: .system(size: 11), lines: 3)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                store.draft?.quotedSelection = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Quote the whole message instead")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Files

    private func attachmentStrip(_ draft: Draft) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if store.compose.isPreparing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Adding the original's files")
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(draft.attachments) { file in
                    fileChip(file.name, size: file.sizeLabel) {
                        store.draft?.attachments.removeAll { $0.id == file.id }
                    }
                }
                ForEach(draft.keptFiles, id: \.self) { name in
                    fileChip(name, size: "in Drafts", remove: nil)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func fileChip(_ name: String, size: String, remove: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
            Text(size).foregroundStyle(.tertiary)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove \(name)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
    /// A recipient line: the addresses, a button for a whole team or department when a people
    /// directory is set, and one strip under it with the groups in the field (each with Expand,
    /// which swaps it for its members) and suggestions for what is being typed.
    private func recipientField(_ title: String, text: Binding<String>, other: String, field: Field,
                                accountID: UUID) -> some View {
        let groups = Recipients.parse(text.wrappedValue).filter(store.isGroup)
        let offered = focus == field ? suggestions : []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                label(title)
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focus, equals: field)
                if store.directory.isConfigured {
                    Button { pickingFor = field } label: {
                        Image(systemName: "person.3").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a team or department")
                    .popover(isPresented: Binding(get: { pickingFor == field }, set: { if !$0 { pickingFor = nil } }),
                             arrowEdge: .bottom) {
                        DirectoryPicker(directory: store.directory,
                                        already: Set((Recipients.parse(text.wrappedValue) + Recipients.parse(other))
                                            .map { $0.lowercased() })) { people in
                            text.wrappedValue = Recipients.appending(people.map(\.address), to: text.wrappedValue,
                                                                     elsewhere: other)
                            pickingFor = nil
                        }
                    }
                }
            }
            if !groups.isEmpty || !offered.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(groups, id: \.self) { address in
                            groupChip(address, text: text, other: other, accountID: accountID)
                        }
                        ForEach(offered) { person in
                            Button {
                                text.wrappedValue = Recipients.completing(text.wrappedValue, with: person.address)
                            } label: {
                                HStack(spacing: 4) {
                                    if person.isGroup { Image(systemName: "person.3.fill").font(.system(size: 9)) }
                                    Text(person.name.isEmpty ? person.address : "\(person.name)  \(person.address)")
                                }
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help(person.detail.isEmpty ? (person.isGroup ? "A group" : person.address) : person.detail)
                        }
                    }
                }
                .padding(.leading, 56)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task(id: focus == field ? Recipients.currentToken(in: text.wrappedValue) : "") {
            let token = focus == field ? Recipients.currentToken(in: text.wrappedValue) : ""
            guard token.count >= 2 else {
                if focus == field { suggestions = [] }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await store.peopleSuggestions(for: token, excluding: text.wrappedValue + ", " + other,
                                                      accountID: accountID, limit: 5)
            guard !Task.isCancelled, focus == field else { return }
            suggestions = found
        }
        // Which addresses are groups: asked once each, after typing settles.
        .task(id: text.wrappedValue) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await store.checkGroups(Recipients.parse(text.wrappedValue), accountID: accountID)
        }
    }

    private func groupChip(_ address: String, text: Binding<String>, other: String, accountID: UUID) -> some View {
        let name = store.groupName(address) ?? address
        return HStack(spacing: 5) {
            Image(systemName: "person.3.fill").font(.system(size: 9))
            Text(name).lineLimit(1)
            if expanding.contains(address.lowercased()) {
                ProgressView().controlSize(.mini)
            } else {
                Button("Expand") {
                    Task { await expand(address, name: name, text: text, other: other, accountID: accountID) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .fontWeight(.medium)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
        .help("\(address) is a group. Expand puts its members here instead.")
    }

    /// The group's address swapped for its members. A group inside it stays, to expand in turn.
    private func expand(_ address: String, name: String, text: Binding<String>, other: String, accountID: UUID) async {
        expanding.insert(address.lowercased())
        defer { expanding.remove(address.lowercased()) }
        do {
            let result = try await store.expandGroup(address, accountID: accountID)
            guard !result.members.isEmpty else {
                groupProblem = "The server lists no members for \(name)."
                return
            }
            let me = store.accounts.account(accountID)?.email ?? ""
            text.wrappedValue = Recipients.expanding(text.wrappedValue, group: address,
                                                     into: result.members.map(\.address), elsewhere: other + ", " + me)
            groupProblem = result.complete ? nil : "The server listed only some of \(name)'s members."
        } catch {
            groupProblem = "Could not expand \(name): \(error.localizedDescription)"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
    }

    private var thinDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.leading, 12)
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ draft: Draft) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let error = draft.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = Self.note(for: draft) {
                Text(note).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            saveStatus
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    static func note(for draft: Draft) -> String? {
        if draft.quotedSelection != nil { return "Only the text you selected is quoted below." }
        switch (draft.kind, draft.style) {
        case (.forward, .asAttachment): return "The original message goes attached, as it is."
        case (.forward, .redirect): return "The original message and its files go on as they are, from you."
        case (.forward, _): return "The original message and its attachments are added below by your server."
        case (.reply, _), (.replyAll, _): return "The original message is quoted below by your server."
        case (.new, _): return (draft.baseHTML ?? "").isEmpty ? nil : "The earlier message is kept below what you write."
        }
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch store.compose.saveStatus {
        case .idle: EmptyView()
        case .saving: Text("Saving...").foregroundStyle(.tertiary)
        case .saved(let date):
            Text("Saved in Drafts \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary)
        case .failed(let reason):
            Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange).help("Not saved in Drafts: \(reason)")
        }
    }
}

/// The text box: plain text, grows no taller than its frame and scrolls, turns right to left
/// when the text starts in Persian, and sends on Cmd+Return. The NSTextView pieces are from
/// osx-jirabar's comment composer.
struct ComposeEditor: NSViewRepresentable {
    @Binding var text: String
    var onSend: () -> Void
    /// The mail composer starts typing here; the event form starts at its title instead.
    var takesFocus = true

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SendingTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        if takesFocus { DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) } }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SendingTextView else { return }
        textView.onSend = onSend
        if textView.string != text { textView.string = text }
        Self.applyDirection(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            ComposeEditor.applyDirection(textView)
        }
    }

    /// Every paragraph takes its own direction from its own first strong character, the same
    /// rule `ComposeHTML` uses for what is sent: a Persian line runs right to left and sits on
    /// the right, and an English line after it runs left to right, "Thanks!" and not "!Thanks".
    /// (osx-jirabar's composer set one direction for the whole box, which is right for a comment
    /// but flipped every English line of a mixed email.)
    static func applyDirection(_ textView: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .natural
        style.alignment = .natural
        if textView.defaultParagraphStyle?.baseWritingDirection != .natural {
            textView.defaultParagraphStyle = style
            textView.typingAttributes[.paragraphStyle] = style
        }
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var needsFix = false
        storage.enumerateAttribute(.paragraphStyle, in: whole) { value, _, stop in
            let current = value as? NSParagraphStyle
            if current?.baseWritingDirection != .natural || current?.alignment != .natural {
                needsFix = true
                stop.pointee = true
            }
        }
        guard needsFix else { return }
        storage.addAttribute(.paragraphStyle, value: style, range: whole)
    }
}

/// Cmd+Return sends, matched by key code so it works on the Persian layout (`ComposerShortcut`).
final class SendingTextView: NSTextView {
    var onSend: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command,
           ComposerShortcut.isSend(keyCode: event.keyCode, command: true), let onSend {
            onSend()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
