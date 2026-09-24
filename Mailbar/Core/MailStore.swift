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

    /// Pre-2013 servers only: previews built from text bodies, so a poll does not refetch them.
    @ObservationIgnored private var legacyPreviews: [String: String] = [:]

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
                unreadCounts[id] = status.unreadCount
                states[id] = .from(messages)
                legacyPreviews.merge(previews) { _, new in new }
            case .failure(let error):
                states[id] = .from(error, host: account.host)
                allHealthy = false
            }
        }
        // Only previews for rows still in some inbox are worth keeping.
        let visible = Set(states.values.flatMap(\.messages).map(\.id))
        legacyPreviews = legacyPreviews.filter { visible.contains($0.key) }

        lastRefresh = Date()
        return allHealthy
    }

    enum AccountResult: Sendable {
        case success(InboxStatus, [MailMessage], previews: [String: String])
        case failure(EWSError)
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
        } catch let error as EWSError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }
}
