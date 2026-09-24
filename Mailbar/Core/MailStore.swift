import Foundation
import Observation

/// Every account's inbox state and unread count, in memory only.
///
/// This is the only place mail content lives, and it never leaves the process: no disk cache, no
/// database. What it holds is the row data (sender, subject, preview, time, read and flag state,
/// ids). A quit or a crash forgets all of it, and the next launch simply asks the server again.
@MainActor
@Observable
final class MailStore {
    let accounts: AccountStore
    let client: EWSClient

    private(set) var states: [UUID: InboxState] = [:]
    private(set) var unreadCounts: [UUID: Int] = [:]
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    /// Which account the popover shows. Persisted only as configuration: an account id.
    var selectedAccountID: UUID? {
        didSet {
            guard accounts.persists else { return }
            UserDefaults.standard.set(selectedAccountID?.uuidString, forKey: Keys.selectedAccount)
        }
    }

    /// The message open in the reader, by id, with the account it belongs to. Only the id: the
    /// body itself lives in the reader's own state and goes when the reader does.
    var openMessage: OpenMessage?

    struct OpenMessage: Equatable {
        let accountID: UUID
        let messageID: String
    }

    /// The last action that failed, shown in a banner under the header until dismissed.
    var actionError: String?

    /// Set when Archive found no Archive folder. The popover asks before one is created.
    var pendingArchive: OpenMessage?

    /// Pre-2013 servers only: previews built from text bodies, so a poll does not refetch them.
    @ObservationIgnored private var legacyPreviews: [String: String] = [:]
    /// Learned from each poll. Decides whether writes use the Exchange 2013 fields.
    @ObservationIgnored private var versions: [UUID: ServerVersion] = [:]
    /// Per account: the Archive folder id, once found. A server id, not mail content.
    @ObservationIgnored private var archiveFolders: [UUID: String] = [:]

    /// Actions applied on screen ahead of the server. A poll that STARTED before an action was
    /// taken can return the old state, and without this it would briefly undo the action on
    /// screen (a deleted row coming back, a flag vanishing) until the poll after it.
    @ObservationIgnored private var edits: [String: Edit] = [:]

    private struct Edit {
        var isRead: Bool?
        var isFlagged: Bool?
        var removed = false
        var at: Date
    }

    init(accounts: AccountStore, client: EWSClient) {
        self.accounts = accounts
        self.client = client
        if accounts.persists,
           let raw = UserDefaults.standard.string(forKey: Keys.selectedAccount) {
            selectedAccountID = UUID(uuidString: raw)
        }
    }

    // MARK: - Reading

    /// The chosen account, or the first one when the chosen one was deleted or never set.
    var selectedAccount: Account? {
        selectedAccountID.flatMap(accounts.account) ?? accounts.accounts.first
    }

    func state(for id: UUID) -> InboxState {
        states[id] ?? .loading
    }

    func unreadCount(for id: UUID) -> Int {
        state(for: id).isHealthy ? (unreadCounts[id] ?? 0) : 0
    }

    /// The menu bar number. Accounts that are failing count zero: a stale count on a rejected
    /// password is a worse lie than no count.
    var totalUnread: Int {
        accounts.accounts.reduce(0) { $0 + unreadCount(for: $1.id) }
    }

    /// True when any account is in a failure state, so the icon can say so.
    var hasProblem: Bool {
        accounts.accounts.contains { !state(for: $0.id).isHealthy }
    }

    // MARK: - Refreshing

    /// Polls every account at once. Returns true when every account succeeded, which is what the
    /// poller uses to reset its backoff.
    @discardableResult
    func refresh() async -> Bool {
        guard !isRefreshing else { return true }
        isRefreshing = true
        defer { isRefreshing = false }
        let started = Date()

        let snapshot = accounts.accounts
        let live = Set(snapshot.map(\.id))
        states = states.filter { live.contains($0.key) }
        unreadCounts = unreadCounts.filter { live.contains($0.key) }

        var jobs: [(UUID, URL, EWSCredential)] = []
        for account in snapshot {
            guard let url = account.endpoint else {
                states[account.id] = .failed("The server address in Settings is not a valid https address.")
                continue
            }
            // Read from the Keychain for this poll only. The credential goes out of scope with
            // the task that uses it.
            guard let password = accounts.passwords.password(for: account.id) else {
                states[account.id] = .needsPassword
                continue
            }
            let credential = EWSCredential(username: account.username, password: password)
            jobs.append((account.id, url, credential))
        }

        let client = self.client
        let knownPreviews = legacyPreviews
        let results = await withTaskGroup(of: (UUID, AccountResult).self) { group in
            for (id, url, credential) in jobs {
                group.addTask {
                    (id, await Self.load(client: client, url: url, credential: credential,
                                         knownPreviews: knownPreviews))
                }
            }
            var collected: [(UUID, AccountResult)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var allHealthy = jobs.count == snapshot.count
        for (id, result) in results {
            // Deleted while the request was out: drop the answer.
            guard let account = accounts.account(id) else { continue }
            switch result {
            case .success(let status, let messages, let previews):
                if let version = status.version { versions[id] = version }
                let (shown, unreadDelta) = applyEdits(to: messages, since: started)
                unreadCounts[id] = max(0, status.unreadCount + unreadDelta)
                states[id] = .from(shown)
                legacyPreviews.merge(previews) { _, new in new }
            case .failure(let error):
                states[id] = .from(error, host: account.host)
                allHealthy = false
            case .cancelled:
                // Not an answer about the mailbox, so it changes nothing on screen.
                continue
            }
        }
        // Only previews for rows still in some inbox are worth keeping.
        let visible = Set(states.values.flatMap(\.messages).map(\.id))
        legacyPreviews = legacyPreviews.filter { visible.contains($0.key) }

        // Edits made before this poll began are reflected in what the server just said.
        edits = edits.filter { $0.value.at >= started }
        lastRefresh = Date()
        return allHealthy
    }

    /// Replays edits made while this poll was in flight over what it returned, and says how far
    /// that moves the unread count the server reported alongside it.
    private func applyEdits(to messages: [MailMessage], since started: Date) -> ([MailMessage], Int) {
        var delta = 0
        var shown: [MailMessage] = []
        for var message in messages {
            guard let edit = edits[message.id], edit.at >= started else {
                shown.append(message)
                continue
            }
            if edit.removed {
                if !message.isRead { delta -= 1 }
                continue
            }
            if let read = edit.isRead, read != message.isRead {
                delta += read ? -1 : 1
                message.isRead = read
            }
            if let flagged = edit.isFlagged { message.isFlagged = flagged }
            shown.append(message)
        }
        return (shown, delta)
    }

    // MARK: - Opening and acting

    func message(_ id: String, in account: UUID) -> MailMessage? {
        state(for: account).messages.first { $0.id == id }
    }

    /// The endpoint and a fresh credential, read from the Keychain for this one call.
    func connection(for accountID: UUID) -> (URL, EWSCredential)? {
        guard let account = accounts.account(accountID),
              let url = account.endpoint,
              let password = accounts.passwords.password(for: accountID) else { return nil }
        return (url, EWSCredential(username: account.username, password: password))
    }

    func isModern(_ accountID: UUID) -> Bool {
        versions[accountID]?.isModern ?? true
    }

    func setRead(_ read: Bool, message id: String, in accountID: UUID) async {
        guard let original = message(id, in: accountID), original.isRead != read else { return }
        await perform(on: id, in: accountID, edit: { $0.isRead = read }, change: { message in
            message.isRead = read
        }, unreadDelta: read ? -1 : 1) { client, url, credential, modern in
            try await client.setRead(read, id: id, modern: modern, at: url, credential: credential)
        }
    }

    func setFlag(_ flagged: Bool, message id: String, in accountID: UUID) async {
        guard let original = message(id, in: accountID), original.isFlagged != flagged else { return }
        await perform(on: id, in: accountID, edit: { $0.isFlagged = flagged }, change: { message in
            message.isFlagged = flagged
        }, unreadDelta: 0) { client, url, credential, modern in
            try await client.setFlag(flagged, id: id, modern: modern, at: url, credential: credential)
        }
    }

    func delete(message id: String, in accountID: UUID) async {
        await remove(id, in: accountID) { client, url, credential, _ in
            try await client.moveToDeletedItems(id: id, at: url, credential: credential)
        }
    }

    /// Moves to the Archive folder. When the mailbox has none, nothing is moved and nothing is
    /// created: `pendingArchive` is set so the popover can ask first.
    func archive(message id: String, in accountID: UUID) async {
        guard let (url, credential) = connection(for: accountID) else {
            actionError = "The password for this account is missing. Enter it in Settings."
            return
        }
        let folder: String
        if let known = archiveFolders[accountID] {
            folder = known
        } else {
            do {
                guard let found = try await client.archiveFolderID(at: url, credential: credential) else {
                    pendingArchive = OpenMessage(accountID: accountID, messageID: id)
                    return
                }
                archiveFolders[accountID] = found
                folder = found
            } catch {
                actionError = describe(error, accountID: accountID)
                return
            }
        }
        await remove(id, in: accountID) { client, url, credential, _ in
            try await client.move(id: id, toFolder: folder, at: url, credential: credential)
        }
    }

    /// The user said yes: make the Archive folder, then archive the message that asked for it.
    func createArchiveFolderAndArchive() async {
        guard let pending = pendingArchive else { return }
        pendingArchive = nil
        guard let (url, credential) = connection(for: pending.accountID) else { return }
        do {
            archiveFolders[pending.accountID] = try await client.createArchiveFolder(at: url, credential: credential)
        } catch {
            actionError = describe(error, accountID: pending.accountID)
            return
        }
        await archive(message: pending.messageID, in: pending.accountID)
    }

    private typealias Request = @Sendable (EWSClient, URL, EWSCredential, Bool) async throws -> Void

    /// Changes one row on screen straight away, asks the server, and puts the row back if the
    /// server refuses.
    private func perform(on id: String,
                         in accountID: UUID,
                         edit: (inout Edit) -> Void,
                         change: (inout MailMessage) -> Void,
                         unreadDelta: Int,
                         request: @escaping Request) async {
        guard let (url, credential) = connection(for: accountID),
              let before = message(id, in: accountID) else { return }
        var after = before
        change(&after)
        replace(after, in: accountID, unreadDelta: unreadDelta)
        var record = edits[id] ?? Edit(at: Date())
        edit(&record)
        record.at = Date()
        edits[id] = record

        do {
            try await request(client, url, credential, isModern(accountID))
            edits[id]?.at = Date()
        } catch {
            edits[id] = nil
            if message(id, in: accountID) != nil { replace(before, in: accountID, unreadDelta: -unreadDelta) }
            actionError = describe(error, accountID: accountID)
        }
    }

    /// Delete and archive: the row leaves at once, and comes back where it was on failure.
    private func remove(_ id: String, in accountID: UUID, request: @escaping Request) async {
        guard let (url, credential) = connection(for: accountID) else { return }
        let messages = state(for: accountID).messages
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removed = messages[index]
        var remaining = messages
        remaining.remove(at: index)
        states[accountID] = .from(remaining)
        if !removed.isRead { unreadCounts[accountID] = max(0, (unreadCounts[accountID] ?? 0) - 1) }
        if openMessage?.messageID == id { openMessage = nil }
        edits[id] = Edit(removed: true, at: Date())

        do {
            try await request(client, url, credential, isModern(accountID))
            edits[id]?.at = Date()
        } catch {
            edits[id] = nil
            var restored = state(for: accountID).messages
            restored.insert(removed, at: min(index, restored.count))
            states[accountID] = .from(restored)
            if !removed.isRead { unreadCounts[accountID] = (unreadCounts[accountID] ?? 0) + 1 }
            actionError = describe(error, accountID: accountID)
        }
    }

    private func replace(_ message: MailMessage, in accountID: UUID, unreadDelta: Int) {
        var messages = state(for: accountID).messages
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index] = message
        states[accountID] = .from(messages)
        unreadCounts[accountID] = max(0, (unreadCounts[accountID] ?? 0) + unreadDelta)
    }

    private func describe(_ error: Error, accountID: UUID) -> String {
        let host = accounts.account(accountID)?.host ?? "The server"
        if let error = error as? EWSError { return error.message(host: host) }
        return error.localizedDescription
    }

    enum AccountResult: Sendable {
        case success(InboxStatus, [MailMessage], previews: [String: String])
        case failure(EWSError)
        case cancelled
    }

    /// One account's poll: the unread count and version first, then the rows in whichever shape
    /// that version supports. Runs off the main actor.
    nonisolated static func load(client: EWSClient,
                                 url: URL,
                                 credential: EWSCredential,
                                 knownPreviews: [String: String]) async -> AccountResult {
        do {
            let status = try await client.inboxStatus(at: url, credential: credential)
            // No version header at all is treated as modern; every server this app is likely to
            // meet is 2013 or later.
            let modern = status.version?.isModern ?? true
            var messages = try await client.inboxMessages(at: url, credential: credential, modern: modern)
            var previews: [String: String] = [:]

            if !modern {
                let missing = messages.map(\.id).filter { knownPreviews[$0] == nil }
                // A preview is a nicety. If the body fetch fails, the rows still show.
                previews = (try? await client.previews(for: missing, at: url, credential: credential)) ?? [:]
                let all = knownPreviews.merging(previews) { _, new in new }
                for index in messages.indices {
                    messages[index].preview = all[messages[index].id] ?? ""
                }
            }
            return .success(status, messages, previews: previews)
        } catch is CancellationError {
            return .cancelled
        } catch let error as EWSError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }
}
