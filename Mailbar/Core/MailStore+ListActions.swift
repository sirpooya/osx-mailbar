import AppKit
import Foundation

/// M20 (list actions) and M21 (junk and folders): what the rows, the selection bar, the toast
/// and the folder menu ask of the store. Every move goes through `removeMany`, so the rows leave
/// at once and come back on failure, and every move but emptying a folder can be undone from
/// the toast for five seconds.
extension MailStore {

    // MARK: - Moving mail

    /// To Deleted Items. A `MoveItem` there, not `DeleteItem` `MoveToDeletedItems`: the same
    /// result, but the reply names the item's new id, which undo needs to bring it back.
    func delete(_ ids: [String], in accountID: UUID) async {
        let rows = rows(ids, in: accountID)
        let source = sourceFolder(of: ids, in: accountID)
        guard let moved = await removeMany(ids, in: accountID, request: { client, url, credential, _ in
            try await client.moveItems(ids, to: .distinguished("deleteditems"), at: url, credential: credential)
        }) else { return }
        await showToast(Self.phrase("Deleted", count: ids.count), rows: rows, newIDs: moved,
                        from: source, in: accountID)
    }

    /// Moves to the Archive folder. When the mailbox has none, nothing is moved and nothing is
    /// created: `pendingArchive` is set so the popover can ask first.
    func archive(_ ids: [String], in accountID: UUID) async {
        guard let first = ids.first else { return }
        guard let (url, credential) = connection(for: accountID) else {
            actionError = "The password for this account is missing. Enter it in Settings."
            return
        }
        let folder: String
        do {
            guard let found = try await archiveFolderID(for: accountID, url: url, credential: credential) else {
                pendingArchive = OpenMessage(accountID: accountID, messageID: first)
                listActions.pendingArchiveIDs = Array(ids.dropFirst())
                return
            }
            folder = found
        } catch is CancellationError {
            return
        } catch {
            actionError = describe(error, accountID: accountID)
            return
        }
        let rows = rows(ids, in: accountID)
        let source = sourceFolder(of: ids, in: accountID)
        guard let moved = await removeMany(ids, in: accountID, request: { client, url, credential, _ in
            try await client.moveItems(ids, to: .id(folder), at: url, credential: credential)
        }) else { return }
        await showToast(Self.phrase("Archived", count: ids.count), rows: rows, newIDs: moved,
                        from: source, in: accountID)
    }

    /// Move to any folder of the tree (M21). A well-known one is moved to by its distinguished
    /// name, so the Inbox is always the Inbox.
    func move(_ ids: [String], in accountID: UUID, to folder: MailboxFolder) async {
        let target: FolderTarget = folder.wellKnown.flatMap { $0 == "archive" ? nil : FolderTarget.distinguished($0) }
            ?? .id(folder.id)
        let rows = rows(ids, in: accountID)
        let source = sourceFolder(of: ids, in: accountID)
        guard let moved = await removeMany(ids, in: accountID, request: { client, url, credential, _ in
            try await client.moveItems(ids, to: target, at: url, credential: credential)
        }) else { return }
        let name = folder.wellKnown == "inbox" ? "the Inbox" : folder.name
        await showToast(ids.count == 1 ? "Moved to \(name)." : "Moved \(ids.count) messages to \(name).",
                        rows: rows, newIDs: moved, from: source, in: accountID)
        if let shown = list(folder.mailFolder, for: accountID), case .results = shown {
            await loadFolder(folder.mailFolder, accountID)
        }
    }

    /// Deleted Items' and Archive's "Move to Inbox" (undelete).
    func moveToInbox(_ ids: [String], in accountID: UUID) async {
        let rows = rows(ids, in: accountID)
        let source = sourceFolder(of: ids, in: accountID)
        guard let moved = await removeMany(ids, in: accountID, request: { client, url, credential, _ in
            try await client.moveItems(ids, to: .distinguished("inbox"), at: url, credential: credential)
        }) else { return }
        await showToast(ids.count == 1 ? "Moved to the Inbox." : "Moved \(ids.count) messages to the Inbox.",
                        rows: rows, newIDs: moved, from: source, in: accountID)
        await refresh()
    }

    /// Junk is offered on Exchange 2013 and later only, where `MarkAsJunk` exists.
    func canUseJunk(_ accountID: UUID) -> Bool { isModern(accountID) }

    /// Mark as Junk and Block Sender are one request (`MarkAsJunk`, the user's decision): the
    /// sender goes on the server's Blocked Senders list and the mail to Junk Email. `block`
    /// only changes what the toast says.
    func markJunk(_ ids: [String], in accountID: UUID, block: Bool) async {
        guard canUseJunk(accountID) else { return }
        let rows = rows(ids, in: accountID)
        let source = sourceFolder(of: ids, in: accountID)
        guard let moved = await removeMany(ids, in: accountID, request: { client, url, credential, _ in
            try await client.markAsJunk(ids, junk: true, at: url, credential: credential)
        }) else { return }
        let senders = Set(rows.map(\.senderAddress).filter { !$0.isEmpty })
        let text: String
        if block, senders.count == 1, let sender = senders.first {
            text = "Blocked \(sender)."
        } else if block {
            text = "Blocked \(senders.count) senders."
        } else {
            text = ids.count == 1 ? "Moved to Junk." : "Moved \(ids.count) messages to Junk."
        }
        await showToast(text, rows: rows, newIDs: moved, from: source, in: accountID, wasJunk: true)
    }

    /// Not Junk: the sender comes off the Blocked Senders list and the mail goes to the Inbox.
    func notJunk(_ ids: [String], in accountID: UUID) async {
        guard canUseJunk(accountID) else { return }
        let rows = rows(ids, in: accountID)
        guard let moved = await removeMany(ids, in: accountID, request: { client, url, credential, _ in
            try await client.markAsJunk(ids, junk: false, at: url, credential: credential)
        }) else { return }
        await showToast(ids.count == 1 ? "Not junk: moved to the Inbox." : "Not junk: \(ids.count) moved to the Inbox.",
                        rows: rows, newIDs: moved, from: .junk, in: accountID)
        await refresh()
    }

    // MARK: - The selection (M20)

    /// The selected rows of the list showing, in list order.
    func selectedIDs(in order: [String]) -> [String] {
        order.filter { listActions.selection.contains($0) }
    }

    func setRead(_ read: Bool, ids: [String], in accountID: UUID) async {
        await performMany(ids, in: accountID, read: read)
    }

    func setFlag(_ flagged: Bool, ids: [String], in accountID: UUID) async {
        await performMany(ids, in: accountID, flagged: flagged)
    }

    /// One swipe across a row (Settings, General, picks what each way does).
    func perform(_ action: SwipeAction, on message: MailMessage, in accountID: UUID) async {
        switch action {
        case .none: return
        case .archive: await archive([message.id], in: accountID)
        case .delete: await delete([message.id], in: accountID)
        case .toggleRead: await setRead(!message.isRead, message: message.id, in: accountID)
        case .flag: await setFlag(!message.isFlagged, message: message.id, in: accountID)
        }
    }

    // MARK: - Undo (M20)

    /// The toast, and its timer: it goes after five seconds unless a newer one replaced it.
    private func showToast(_ text: String, rows: [MailMessage], newIDs: [String?], from source: MailFolder,
                           in accountID: UUID, wasJunk: Bool = false) async {
        var back: FolderTarget?
        switch source {
        case .inbox, .flagged: back = .distinguished("inbox")
        case .sent: back = .distinguished("sentitems")
        case .deleted: back = .distinguished("deleteditems")
        case .junk: back = .distinguished("junkemail")
        case .drafts: back = .distinguished("drafts")
        case .custom(let folder): back = .id(folder.id)
        case .archive:
            if let (url, credential) = connection(for: accountID),
               let id = try? await archiveFolderID(for: accountID, url: url, credential: credential) { back = .id(id) }
        }
        // Only the rows the server gave a new id can be put back.
        var ids: [String] = []
        var restorable: [MailMessage] = []
        for (row, newID) in zip(rows, newIDs) {
            guard let newID else { continue }
            ids.append(newID)
            restorable.append(row.withID(newID))
        }
        let undo = back.flatMap { back in
            ids.isEmpty ? nil : UndoToast.Undo(ids: ids, back: back, wasJunk: wasJunk && back == .distinguished("inbox"),
                                               rows: restorable, folder: source)
        }
        let toast = UndoToast(text: text, accountID: accountID, undo: undo)
        listActions.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(UndoToast.seconds))
            guard let self, self.listActions.toast?.id == toast.id else { return }
            self.listActions.toast = nil
        }
    }

    /// Puts the moved mail back where it was: `MoveItem` with the ids from the move's reply,
    /// or, after junk, `MarkAsJunk` IsJunk false, which also takes the sender off the list again.
    func undo(_ toast: UndoToast) async {
        guard let undo = toast.undo else { return }
        if listActions.toast?.id == toast.id { listActions.toast = nil }
        guard let (url, credential) = connection(for: toast.accountID) else { return }
        do {
            let newIDs = undo.wasJunk
                ? try await client.markAsJunk(undo.ids, junk: false, at: url, credential: credential)
                : try await client.moveItems(undo.ids, to: undo.back, at: url, credential: credential)
            let rows = zip(undo.rows, newIDs).map { row, id in row.withID(id ?? row.id) }
            restoreRows(rows, in: toast.accountID, folder: undo.folder)
        } catch is CancellationError {
            return
        } catch {
            actionError = describe(error, accountID: toast.accountID)
            return
        }
        // The server's own view of both lists, now that it has settled.
        await refresh()
        if undo.folder != .inbox { await loadFolder(undo.folder, toast.accountID) }
        for folder in [MailFolder.archive, .deleted, .junk] where folder != undo.folder {
            if case .results = list(folder, for: toast.accountID) { await loadFolder(folder, toast.accountID) }
        }
    }

    // MARK: - Emptying (M21)

    /// Asks how many items there are, then asks the user. Nothing is deleted here.
    func askToEmpty(_ folder: MailFolder, in accountID: UUID) async {
        guard let target = Self.emptyTarget(folder), let (url, credential) = connection(for: accountID) else { return }
        do {
            let count = try await client.folderCount(target, at: url, credential: credential)
            guard count > 0 else {
                actionError = "\(folder.title) is already empty."
                return
            }
            listActions.pending = .empty(folder, accountID: accountID, count: count)
        } catch is CancellationError {
            return
        } catch {
            actionError = describe(error, accountID: accountID)
        }
    }

    /// The user confirmed. Deleted Items is emptied with `SoftDelete` (the server keeps it in
    /// its recoverable items for a while), Junk Email into Deleted Items.
    func empty(_ folder: MailFolder, in accountID: UUID) async {
        listActions.pending = nil
        guard let target = Self.emptyTarget(folder), let (url, credential) = connection(for: accountID) else { return }
        do {
            try await client.emptyFolder(target, deleteType: folder == .deleted ? .softDelete : .moveToDeletedItems,
                                         at: url, credential: credential)
        } catch is CancellationError {
            return
        } catch {
            actionError = describe(error, accountID: accountID)
            return
        }
        listActions.clearSelection()
        await loadFolder(folder, accountID)
        if folder == .junk, case .results = list(.deleted, for: accountID) { await loadFolder(.deleted, accountID) }
    }

    nonisolated static func emptyTarget(_ folder: MailFolder) -> FolderTarget? {
        switch folder {
        case .deleted: .distinguished("deleteditems")
        case .junk: .distinguished("junkemail")
        default: nil
        }
    }

    // MARK: - Folders (M21)

    /// The mailbox's mail folders, read once per account per run (names and ids only, in
    /// memory), or again when `force`.
    func loadFolderTree(for accountID: UUID, force: Bool = false) async {
        switch listActions.folderTrees[accountID] {
        case .loading: return
        case .loaded where !force: return
        default: break
        }
        guard let (url, credential) = connection(for: accountID) else { return }
        listActions.folderTrees[accountID] = .loading
        do {
            let archive = try? await archiveFolderID(for: accountID, url: url, credential: credential)
            let folders = try await client.mailFolders(archiveID: archive, at: url, credential: credential)
            listActions.folderTrees[accountID] = .loaded(folders)
        } catch {
            listActions.folderTrees[accountID] = .failed
        }
    }

    /// A folder of the tree or a favorite: the standard view for a well-known folder.
    func open(_ folder: MailboxFolder) {
        // Each custom folder is its own key (equal by id), so another folder's rows never show.
        mailFolder = folder.mailFolder
        listActions.clearSelection()
    }

    // MARK: - Unsubscribe (M20)

    /// The message's `List-Unsubscribe` links, looked up once per message while the popover is
    /// open. Nil when it has none or the server could not say.
    func unsubscribeLink(for id: String, in accountID: UUID) async -> UnsubscribeLink? {
        if let known = listActions.unsubscribeLinks[id] { return known.isEmpty ? nil : known }
        guard let (url, credential) = connection(for: accountID) else { return nil }
        guard let found = try? await client.unsubscribeLink(for: id, at: url, credential: credential) else {
            listActions.unsubscribeLinks[id] = UnsubscribeLink()
            return nil
        }
        listActions.unsubscribeLinks[id] = found
        return found
    }

    /// From a row's menu: look the header up, then ask before doing anything.
    func askToUnsubscribe(message id: String, in accountID: UUID) async {
        guard let link = await unsubscribeLink(for: id, in: accountID), let preferred = link.preferred else {
            actionError = "This message has no unsubscribe link."
            return
        }
        let sender = message(id, in: accountID).map { $0.senderName.isEmpty ? $0.senderAddress : $0.senderName } ?? "this sender"
        listActions.pending = .unsubscribe(preferred, sender: sender, accountID: accountID)
    }

    /// The user confirmed: the page opens in the browser, or the request mail goes out through
    /// the app's own send path (never the composer's draft).
    func confirmUnsubscribe() async {
        guard case .unsubscribe(let way, _, let accountID) = listActions.pending else { return }
        listActions.pending = nil
        switch way {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .mail(let mail):
            guard let (url, credential) = connection(for: accountID) else { return }
            let request = Draft(kind: .new, accountID: accountID, originalID: nil, originalSubject: "",
                                to: mail.address, cc: "", subject: mail.subject, body: mail.body)
            do {
                try await client.send(request, at: url, credential: credential)
                sentNotice = "Unsubscribe request sent to \(mail.address)."
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.sentNotice = nil
                }
            } catch is CancellationError {
                return
            } catch {
                actionError = describe(error, accountID: accountID)
            }
        }
    }

    // MARK: - Helpers

    private func rows(_ ids: [String], in accountID: UUID) -> [MailMessage] {
        ids.compactMap { message($0, in: accountID) }
    }

    /// Which list the mail is leaving: the folder showing when the rows are in it, the Inbox
    /// when they are only there (a notification's action), else the folder showing.
    private func sourceFolder(of ids: [String], in accountID: UUID) -> MailFolder {
        let shown = isSearchOpen ? searchFolder : mailFolder
        guard let first = ids.first else { return shown }
        if list(shown, for: accountID)?.messages.contains(where: { $0.id == first }) == true { return shown }
        if state(for: accountID).messages.contains(where: { $0.id == first }) { return .inbox }
        return shown
    }

    nonisolated static func phrase(_ verb: String, count: Int) -> String {
        count == 1 ? "\(verb)." : "\(verb) \(count) messages."
    }
}
