import AppKit
import Foundation

/// Writing mail since M23 to M25: the server copy in Drafts, Undo Send, files, templates,
/// Check Names, MailTips, Forward as Attachment, Redirect, Resend, mailto: links.
extension MailStore {

    // MARK: - Sending

    /// How a draft reaches the server. One request when it can (never saved, no files, nothing
    /// a response object cannot carry); otherwise saved in Drafts, given its files, and sent
    /// from there with `SendItem`, which leaves the copy in Sent Items and none in Drafts.
    func deliver(_ draft: Draft, at url: URL, credential: EWSCredential) async throws {
        // A save under way finishes first, so the message is never created twice.
        await compose.savingTask?.value
        var draft = draft
        if let latest = [self.draft, compose.pending?.draft].compactMap({ $0 }).first(where: { $0.id == draft.id }) {
            draft.serverID = latest.serverID ?? draft.serverID
            draft.baseHTML = latest.baseHTML ?? draft.baseHTML
        }
        compose.autosaveTask?.cancel()
        if Self.needsSavedCopy(draft) {
            let saved = try await client.saveDraft(draft, at: url, credential: credential)
            draft.serverID = saved.id
            if let base = saved.baseHTML { draft.baseHTML = base }
            if self.draft?.id == draft.id { self.draft?.serverID = saved.id }
            try await client.sendSaved(saved.id, draft: draft, at: url, credential: credential)
        } else {
            try await client.sendDirect(draft, at: url, credential: credential)
        }
        compose.saveStatus = .idle
        reloadDraftsList(draft.accountID)
    }

    static func needsSavedCopy(_ draft: Draft) -> Bool {
        draft.serverID != nil || !draft.attachments.isEmpty || draft.style != .standard
            || (draft.kind != .new && draft.quotedSelection == nil
                && (draft.options.importance != .normal || draft.options.sensitivity != .normal))
    }

    /// Send with Undo (Settings, 0 to 20 seconds): the composer closes at once, the message waits
    /// in memory under a "Sending" toast, and goes when the time is up. Undo brings it back.
    func sendWithUndo() {
        guard let held = draft, !held.isSending, held.sendProblem == nil else { return }
        let seconds = ComposeSettings.undoSeconds()
        guard seconds > 0 else {
            Task { await sendDraft() }
            return
        }
        compose.autosaveTask?.cancel()
        compose.sendFailure = nil
        draft = nil
        isComposing = false
        compose.pending = .init(draft: held, deadline: Date().addingTimeInterval(TimeInterval(seconds)))
        compose.pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.sendHeld(held.id)
        }
    }

    func undoSend() {
        guard let pending = compose.pending else { return }
        compose.pendingTask?.cancel()
        compose.pending = nil
        if let current = draft, current.hasContent, current.id != pending.draft.id {
            // Another message was started meanwhile and has text: this one waits in Drafts.
            Task { await saveHeldToDrafts(pending.draft) }
            return
        }
        draft = pending.draft
        isComposing = true
    }

    /// Sends a held message now, without waiting out the Undo time.
    func sendHeldNow() {
        guard let pending = compose.pending else { return }
        compose.pendingTask?.cancel()
        compose.pendingTask = Task { [weak self] in await self?.sendHeld(pending.draft.id) }
    }

    private func sendHeld(_ id: UUID) async {
        guard let pending = compose.pending, pending.draft.id == id else { return }
        let sending = pending.draft
        guard let (url, credential) = connection(for: sending.accountID) else {
            failHeld(sending, "The password for this account is missing. Enter it in Settings.")
            return
        }
        compose.isSendingHeld = true
        defer { compose.isSendingHeld = false }
        do {
            try await deliver(sending, at: url, credential: credential)
            compose.pending = nil
            let count = sending.allRecipients.count
            sentNotice = count == 1 ? "Sent." : "Sent to \(count) people."
            if list(.sent, for: sending.accountID) != nil { Task { await loadFolder(.sent, sending.accountID) } }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.sentNotice = nil
            }
            await markResponded(sending)
        } catch is CancellationError {
            compose.pending = nil
        } catch {
            failHeld(sending, composeDescribe(error, accountID: sending.accountID))
        }
    }

    /// A held message that could not go: back in the composer with the reason, unless another
    /// message is being written, in which case it waits in Drafts.
    private func failHeld(_ held: Draft, _ reason: String) {
        compose.pending = nil
        var failed = held
        failed.error = reason
        if let current = draft, current.hasContent, current.id != held.id {
            compose.sendFailure = "Not sent: \(reason) It is in Drafts."
            Task { await saveHeldToDrafts(failed) }
        } else {
            draft = failed
            compose.sendFailure = "Not sent: \(reason)"
        }
    }

    private func saveHeldToDrafts(_ held: Draft) async {
        guard let (url, credential) = connection(for: held.accountID) else { return }
        _ = try? await client.saveDraft(held, at: url, credential: credential)
        reloadDraftsList(held.accountID)
        compose.notice = "Saved in Drafts."
    }

    // MARK: - Drafts on the server

    /// A few seconds after typing stops, the server copy is brought up to date.
    func scheduleAutosave() {
        compose.autosaveTask?.cancel()
        guard let current = draft, current.hasContent, current.fingerprint != current.savedFingerprint else { return }
        compose.autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.saveDraftToServer()
        }
    }

    /// Saves the draft in the server's Drafts folder now (closing the composer does this).
    func saveDraftToServer() async {
        if let running = compose.savingTask { await running.value }
        guard let current = draft, current.hasContent, current.fingerprint != current.savedFingerprint,
              !current.isSending, let (url, credential) = connection(for: current.accountID) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.compose.saveStatus = .saving
            do {
                let saved = try await self.client.saveDraft(current, at: url, credential: credential)
                var stored = current
                stored.serverID = saved.id
                if let base = saved.baseHTML { stored.baseHTML = base }
                if self.draft?.id == current.id {
                    self.draft?.serverID = saved.id
                    if let base = saved.baseHTML { self.draft?.baseHTML = base }
                    self.draft?.savedFingerprint = stored.fingerprint
                } else if self.compose.pending?.draft.id == current.id, let pending = self.compose.pending {
                    var held = pending.draft
                    held.serverID = saved.id
                    held.baseHTML = stored.baseHTML
                    self.compose.pending = .init(draft: held, deadline: pending.deadline)
                } else if current.serverID == nil {
                    // Discarded while it saved: the copy just made goes too.
                    try? await self.client.deleteDraft(saved.id, at: url, credential: credential)
                }
                self.compose.saveStatus = .saved(Date())
                self.reloadDraftsList(current.accountID)
            } catch is CancellationError {
                self.compose.saveStatus = .idle
            } catch {
                self.compose.saveStatus = .failed(self.composeDescribe(error, accountID: current.accountID))
            }
        }
        compose.savingTask = task
        await task.value
        if compose.savingTask == task { compose.savingTask = nil }
    }

    /// Close, keeping the message only in the server's Drafts folder. False when it could not
    /// be saved there, and then it stays open.
    func saveAndCloseDraft() async -> Bool {
        await saveDraftToServer()
        guard let current = draft, current.serverID != nil, current.fingerprint == current.savedFingerprint else {
            if draft?.error == nil, case .failed(let reason) = compose.saveStatus { draft?.error = reason }
            return false
        }
        discardDraft()
        compose.richText = nil
        compose.saveStatus = .idle
        compose.notice = nil
        return true
    }

    /// Discard: the text goes, and so does the server copy (to Deleted Items, as everywhere).
    func discardDraftEverywhere() {
        compose.autosaveTask?.cancel()
        let gone = draft
        discardDraft()
        compose.saveStatus = .idle
        compose.richText = nil
        compose.unresolved = [:]
        guard let gone, let id = gone.serverID, let (url, credential) = connection(for: gone.accountID) else { return }
        Task {
            try? await client.deleteDraft(id, at: url, credential: credential)
            reloadDraftsList(gone.accountID)
        }
    }

    func reloadDraftsList(_ accountID: UUID) {
        guard list(.drafts, for: accountID) != nil else { return }
        Task { await loadFolder(.drafts, accountID) }
    }

    /// A row in Drafts opens in the composer, not the reader. A message being written is saved
    /// to Drafts first, so nothing is lost.
    func openDraft(_ id: String, in accountID: UUID) async {
        if let current = draft, current.hasContent {
            if current.serverID == id { isComposing = true; return }
            await saveDraftToServer()
            guard draft?.serverID != nil else { isComposing = true; return }
        }
        guard let (url, credential) = connection(for: accountID) else { return }
        do {
            let saved = try await client.savedMessage(id, at: url, credential: credential)
            var opened = Draft(kind: .new, accountID: accountID, originalID: nil, originalSubject: "",
                               to: Recipients.field(saved.to), cc: Recipients.field(saved.cc),
                               subject: saved.subject, body: "")
            opened.bcc = Recipients.field(saved.bcc)
            opened.options = saved.options
            opened.serverID = id
            opened.keptFiles = saved.fileNames
            opened.prepared = true
            fill(&opened, fromHTML: saved.html)
            opened.savedFingerprint = opened.fingerprint
            draft = opened
            isComposing = true
        } catch {
            actionError = composeDescribe(error, accountID: accountID)
        }
    }

    /// The user's part of a saved body into the editor, the rest kept underneath as it was.
    private func fill(_ target: inout Draft, fromHTML html: String) {
        let parts = ComposeHTML.split(html)
        let mine = parts?.mine ?? html
        target.baseHTML = parts.map(\.base)
        let text = RichHTML.attributed(fromHTML: mine)
        target.body = text.string
        target.bodyHTML = RichHTML.hasFormatting(text) ? RichHTML.html(from: text) : nil
        compose.richText = text
        compose.richDraftID = target.id
    }

    // MARK: - Starting

    /// Signature and "always Cc or Bcc me", once, when the composer first shows a fresh draft.
    func prepareDraft() {
        guard var current = draft, !current.prepared else { return }
        current.prepared = true
        let me = accounts.account(current.accountID)?.email ?? ""
        if !me.isEmpty {
            let mine = Set(current.allRecipients.map { $0.lowercased() })
            if ComposeSettings.alwaysCcMe(), !mine.contains(me.lowercased()) {
                current.cc = Recipients.appending([me], to: current.cc)
            }
            if ComposeSettings.alwaysBccMe(), !mine.contains(me.lowercased()) {
                current.bcc = Recipients.appending([me], to: current.bcc)
            }
        }
        if let signature = ComposeSettings.signature(for: current.kind, account: current.accountID),
           !current.body.contains(signature.text) {
            current.body += ComposeSettings.signatureBlock(signature)
        }
        draft = current
    }

    /// Reply or reply all quoting only the text selected in the reader.
    func startResponse(_ kind: Draft.Kind, to body: MessageBody, in accountID: UUID, selection: String?) {
        let before = draft?.id
        startResponse(kind, to: body, in: accountID)
        guard let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty,
              draft?.id != before, kind != .forward else { return }
        draft?.quotedSelection = selection
    }

    /// Forward as Attachment or Redirect of an opened message.
    func startForward(_ style: Draft.Style, of body: MessageBody, in accountID: UUID) {
        if let current = draft, current.hasContent { isComposing = true; return }
        var started = Draft(kind: .forward, accountID: accountID, originalID: body.id, originalSubject: body.subject,
                            to: "", cc: "", subject: "", body: "")
        started.style = style
        if style == .redirect { started.baseHTML = body.html }
        draft = started
        isComposing = true
        if style == .redirect { copyFiles(of: body, into: started.id, accountID: accountID) }
    }

    /// Resend, from Sent Items: a new message with the original's recipients, subject, body
    /// and files, all of it editable before it goes.
    func startResend(of body: MessageBody, in accountID: UUID) {
        if let current = draft, current.hasContent { isComposing = true; return }
        var started = Draft(kind: .new, accountID: accountID, originalID: nil, originalSubject: "",
                            to: Recipients.field(body.to.map(\.address)),
                            cc: Recipients.field(body.cc.map(\.address)),
                            subject: body.subject, body: "")
        started.prepared = true
        started.baseHTML = body.html
        draft = started
        isComposing = true
        copyFiles(of: body, into: started.id, accountID: accountID)
    }

    /// The original's files, into memory on the draft, for Redirect and Resend.
    private func copyFiles(of body: MessageBody, into draftID: UUID, accountID: UUID) {
        guard !body.files.isEmpty, let (url, credential) = connection(for: accountID) else { return }
        compose.isPreparing = true
        Task {
            defer { compose.isPreparing = false }
            for file in body.files {
                guard let data = try? await client.attachmentContent(id: file.id, at: url, credential: credential),
                      draft?.id == draftID else { continue }
                draft?.attachments.append(OutgoingFile(name: file.name, contentType: file.contentType, data: data))
            }
        }
    }

    /// A `mailto:` link: a new message filled from it. A message being written is shown instead.
    func startMailto(_ link: MailtoLink) {
        if let current = draft, current.hasContent { isComposing = true; return }
        guard let account = selectedAccount ?? accounts.accounts.first else { return }
        var started = Draft(kind: .new, accountID: account.id, originalID: nil, originalSubject: "",
                            to: Recipients.field(link.to), cc: Recipients.field(link.cc),
                            subject: link.subject, body: link.body)
        started.bcc = Recipients.field(link.bcc)
        draft = started
        compose.richText = nil
        isComposing = true
    }

    // MARK: - Files

    /// Adds files from Finder (Attach or a drop). Over 25 MB together, the extra ones are refused.
    func attach(_ urls: [URL]) {
        guard draft != nil else { return }
        for url in urls {
            guard let file = try? OutgoingFile.from(url) else {
                draft?.error = "Could not read \(url.lastPathComponent)."
                continue
            }
            if (draft?.attachedBytes ?? 0) + file.data.count > OutgoingFile.maxTotal {
                draft?.error = "\(file.name) would take the files over 25 MB."
                continue
            }
            draft?.attachments.append(file)
        }
    }

    // MARK: - Templates

    /// Saves the message as a template in Drafts/Templates. With no such folder the composer
    /// asks first; `create` is the answer.
    func saveAsTemplate(create: Bool = false) async {
        guard let current = draft, let (url, credential) = connection(for: current.accountID) else { return }
        do {
            guard let folder = try await templatesFolder(current.accountID, url: url, credential: credential, create: create) else {
                compose.asksToCreateTemplates = true
                return
            }
            compose.asksToCreateTemplates = false
            try await client.saveTemplate(current, in: folder, at: url, credential: credential)
            compose.notice = "Saved as a template."
            compose.templates = []
        } catch {
            compose.notice = "Could not save the template: \(composeDescribe(error, accountID: current.accountID))"
        }
    }

    private func templatesFolder(_ accountID: UUID, url: URL, credential: EWSCredential, create: Bool) async throws -> String? {
        if let id = compose.templatesFolder[accountID] { return id }
        if let id = try await client.templatesFolderID(at: url, credential: credential) {
            compose.templatesFolder[accountID] = id
            return id
        }
        guard create else { return nil }
        let id = try await client.createTemplatesFolder(at: url, credential: credential)
        compose.templatesFolder[accountID] = id
        return id
    }

    /// The templates of the draft's account, for New from Template. Looking never creates the folder.
    func loadTemplates() async {
        guard let accountID = draft?.accountID ?? selectedAccount?.id,
              let (url, credential) = connection(for: accountID) else { return }
        compose.templatesLoading = true
        defer { compose.templatesLoading = false }
        guard let folder = try? await templatesFolder(accountID, url: url, credential: credential, create: false) else {
            compose.templates = []
            return
        }
        compose.templates = (try? await client.items(inFolder: folder, at: url, credential: credential)) ?? []
    }

    /// Fills the message being written from a template: recipients, subject and text.
    func applyTemplate(_ id: String) async {
        guard let current = draft, let (url, credential) = connection(for: current.accountID) else { return }
        do {
            let saved = try await client.savedMessage(id, at: url, credential: credential)
            var filled = current
            filled.to = Recipients.appending(saved.to, to: current.to)
            filled.cc = Recipients.appending(saved.cc, to: current.cc)
            if current.kind == .new, current.subject.isEmpty { filled.subject = saved.subject }
            filled.options = saved.options
            let base = filled.baseHTML
            fill(&filled, fromHTML: saved.html)
            filled.baseHTML = base
            draft = filled
        } catch {
            compose.notice = "Could not open the template: \(composeDescribe(error, accountID: current.accountID))"
        }
    }

    // MARK: - Check Names and MailTips

    /// Outlook's Check Names: every typed entry that is not an address is looked up in the
    /// directory. One match replaces it; none or several leave it marked, with what was found.
    func checkNames() async {
        guard let current = draft, let (url, credential) = connection(for: current.accountID) else { return }
        compose.isCheckingNames = true
        defer { compose.isCheckingNames = false }
        var unresolved: [String: [PersonSuggestion]] = [:]
        for keyPath in [\Draft.to, \Draft.cc, \Draft.bcc] {
            for entry in Recipients.parse(current[keyPath: keyPath]) where !Recipients.isValid(entry) {
                let found = (try? await client.resolveNames(entry, at: url, credential: credential)) ?? []
                if found.count == 1, let only = found.first {
                    let field = draft?[keyPath: keyPath] ?? ""
                    draft?[keyPath: keyPath] = Recipients.replacing(entry, with: only.address, in: field)
                } else {
                    unresolved[entry] = found
                }
            }
        }
        compose.unresolved = unresolved
    }

    /// Picks one of the people Check Names offered for an entry.
    func resolve(_ entry: String, as person: PersonSuggestion) {
        for keyPath in [\Draft.to, \Draft.cc, \Draft.bcc] where Recipients.parse(draft?[keyPath: keyPath] ?? "").contains(entry) {
            let field = draft?[keyPath: keyPath] ?? ""
            draft?[keyPath: keyPath] = Recipients.replacing(entry, with: person.address, in: field)
        }
        compose.unresolved[entry] = nil
    }

    /// Asks the server about recipients not asked about yet. Quiet on failure: tips are a help,
    /// never in the way of sending.
    func refreshMailTips() async {
        guard let current = draft, let (url, credential) = connection(for: current.accountID) else { return }
        let wanted = current.allRecipients.filter(Recipients.isValid).map { $0.lowercased() }
            .filter { !compose.tipsAsked.contains($0) }
        guard !wanted.isEmpty else { return }
        compose.tipsAsked.formUnion(wanted)
        let me = current.from.isEmpty ? (accounts.account(current.accountID)?.email ?? "") : current.from
        guard let tips = try? await client.mailTips(sender: me, recipients: Array(Set(wanted)), at: url, credential: credential) else {
            compose.tipsAsked.subtract(wanted)
            return
        }
        for tip in tips { compose.mailTips[tip.address.lowercased()] = tip }
    }

    /// The lines to show under the recipients.
    var mailTipLines: [String] {
        guard let current = draft else { return [] }
        let me = current.from.isEmpty ? (accounts.account(current.accountID)?.email ?? "") : current.from
        return MailTipLines.lines(for: current.allRecipients.filter(Recipients.isValid), tips: compose.mailTips, myAddress: me)
    }

    /// An @mention in the body: the person joins To, as in Outlook.
    func addMention(_ person: PersonSuggestion) {
        guard let current = draft else { return }
        let all = Set(current.allRecipients.map { $0.lowercased() })
        guard !all.contains(person.address.lowercased()) else { return }
        draft?.to = Recipients.appending([person.address], to: current.to)
    }

    func composeDescribe(_ error: Error, accountID: UUID) -> String {
        let host = accounts.account(accountID)?.host ?? "The server"
        if let error = error as? EWSError { return error.message(host: host) }
        return error.localizedDescription
    }
}

extension Recipients {
    /// A field's text for these addresses, ready for the next one.
    static func field(_ addresses: [String]) -> String {
        let kept = addresses.filter { !$0.isEmpty }
        return kept.isEmpty ? "" : join(kept) + ", "
    }

    /// One entry in a field swapped for an address, where it stands.
    static func replacing(_ entry: String, with address: String, in text: String) -> String {
        let result = parse(text).map { $0 == entry ? address : $0 }
        return result.isEmpty ? "" : join(result) + ", "
    }
}
