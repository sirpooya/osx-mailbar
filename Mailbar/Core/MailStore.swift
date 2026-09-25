import AppKit
import Foundation
import Observation
import SwiftUI

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

    // MARK: Search (M8)

    /// Whether the search field is showing, over the selected account's inbox.
    var isSearchOpen = false
    /// What is typed. Searching starts from two characters.
    var searchQuery = ""
    private(set) var searchPhase: SearchPhase = .idle
    /// The account the current results belong to.
    private(set) var searchAccountID: UUID?

    enum SearchPhase: Equatable {
        case idle
        case searching
        case results([MailMessage])
        case failed(String)

        var messages: [MailMessage] {
            if case .results(let list) = self { return list }
            return []
        }
    }

    // MARK: Writing (M12 to M14)

    /// The one message being written, if any. In memory only; see `Draft`.
    var draft: Draft?
    /// Whether the composer is on screen. The draft outlives it: closing the popover, or going
    /// back to read something, keeps the text until it is sent or discarded.
    var isComposing = false
    /// "Sent" confirmation, shown briefly under the header.
    var sentNotice: String?

    // MARK: Today (M19)

    /// Which of the popover's two tabs is showing.
    enum PopoverTab: String { case inbox, today }
    var popoverTab: PopoverTab = .inbox

    /// The rest of today's events per account. In memory only.
    private(set) var today: [UUID: [CalendarEvent]] = [:]
    /// All of today's events per account, past ones included, for the Today tab's day view.
    private(set) var dayEvents: [UUID: [CalendarEvent]] = [:]
    /// Category colours per account, for the Today tab (the calendar window keeps its own).
    private(set) var categoryColors: [UUID: [String: Int]] = [:]
    private(set) var todayLoaded: Set<UUID> = []
    /// Set by the app delegate: fetches today at once, when the Today tab is opened.
    @ObservationIgnored var refreshToday: (() async -> Void)?

    func setDayEvents(_ events: [CalendarEvent], for accountID: UUID) {
        dayEvents[accountID] = events
        todayLoaded.insert(accountID)
    }

    // MARK: Other days on the Today tab

    /// The Today tab's day, in days from today: a sideways swipe moves it, as in the calendar
    /// window, and closing the popover brings it back to today.
    var dayOffset = 0
    /// The strip of three days (-1, 0, 1 around `dayOffset`) that follows the fingers.
    let dayPager = CalendarPager()
    /// The popover's window, so only swipes inside it page the day (the calendar window has its own).
    @ObservationIgnored weak var popoverWindow: NSWindow?
    /// Events of the days around the one shown, per account, keyed by start of day. Only the
    /// days within three of the one shown are kept, in memory, and all of it goes when the
    /// popover closes.
    private(set) var nearbyDays: [UUID: [Date: [CalendarEvent]]] = [:]
    /// Days whose fetch failed, so the header says so instead of spinning for ever.
    private(set) var failedDays: [UUID: Set<Date>] = [:]
    @ObservationIgnored private var loadingDays: [UUID: Set<Date>] = [:]
    /// Bumped when the popover closes, so an answer arriving afterwards is not kept.
    @ObservationIgnored private var nearbyGeneration = 0

    func day(offset: Int) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    /// A day's events, or nil while it is still being fetched. Today's come from the reminders'
    /// fetch, which the stream keeps current.
    func events(onDay day: Date, for accountID: UUID) -> [CalendarEvent]? {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return todayLoaded.contains(accountID) ? (dayEvents[accountID] ?? []) : nil }
        return nearbyDays[accountID]?[calendar.startOfDay(for: day)]
    }

    func dayFailed(_ day: Date, for accountID: UUID) -> Bool {
        failedDays[accountID]?.contains(Calendar.current.startOfDay(for: day)) == true
    }

    /// Fetches the days within two of the one shown that are not in memory yet, in one request.
    /// An answer is never thrown away because the user swiped on while it was coming: over a
    /// slow link each swipe used to discard the fetch that held the very day being swiped to,
    /// so a day never arrived (the user's recording, 2026-09-25).
    func loadNearbyDays(for accountID: UUID) async {
        let calendar = Calendar.current
        let wanted = (-2...2).map { day(offset: dayOffset + $0) }.filter { !calendar.isDateInToday($0) }
        let missing = wanted.filter { nearbyDays[accountID]?[$0] == nil && loadingDays[accountID]?.contains($0) != true }
        guard let first = missing.min(), let last = missing.max(),
              let end = calendar.date(byAdding: .day, value: 1, to: last),
              let (url, credential) = connection(for: accountID) else { return }
        let generation = nearbyGeneration
        loadingDays[accountID, default: []].formUnion(missing)
        failedDays[accountID]?.subtract(missing)
        defer { loadingDays[accountID]?.subtract(missing) }
        do {
            let events = try await client.calendarEvents(from: first, to: end, at: url, credential: credential)
            guard generation == nearbyGeneration else { return }
            var days = nearbyDays[accountID] ?? [:]
            for day in missing { days[day] = TodayAgenda.all(of: events, on: day) }
            // Keep only what is near the day on screen now.
            let keep = Set((-3...3).map { self.day(offset: dayOffset + $0) })
            nearbyDays[accountID] = days.filter { keep.contains($0.key) }
        } catch {
            guard generation == nearbyGeneration else { return }
            failedDays[accountID, default: []].formUnion(missing)
        }
    }

    func resetDay() {
        dayOffset = 0
        nearbyDays = [:]
        failedDays = [:]
        loadingDays = [:]
        nearbyGeneration += 1
    }

    func setCategoryColors(_ colors: [String: Int], for accountID: UUID) {
        categoryColors[accountID] = colors
    }

    func tint(for event: CalendarEvent, in accountID: UUID) -> Color {
        CategoryColors.tint(for: event, colors: categoryColors[accountID] ?? [:])
    }
    /// The join link of each account's next (or current) event, when its notes carry one.
    private(set) var joinLinks: [String: URL] = [:]

    func todayEvents(for accountID: UUID) -> [CalendarEvent] {
        today[accountID] ?? []
    }

    /// Stores the agenda and finds the join links of the first two timed events, the one under
    /// way and the next: one GetItem each, only when not looked up already.
    func setToday(_ events: [CalendarEvent], for accountID: UUID) async {
        today[accountID] = events
        guard let (url, credential) = connection(for: accountID) else { return }
        for event in events.filter({ !$0.isAllDay }).prefix(2) where !linksLookedUp.contains(event.id) {
            linksLookedUp.insert(event.id)
            guard let detail = try? await client.eventDetail(id: event.id, at: url, credential: credential),
                  let link = TodayAgenda.joinLink(inHTML: detail.html + " " + detail.event.location) else { continue }
            joinLinks[event.id] = link
        }
    }

    @ObservationIgnored private var linksLookedUp: Set<String> = []

    // MARK: New mail (M7)

    /// Messages that arrived since the last poll, per account. Wired to notifications.
    @ObservationIgnored var onNewMail: ((Account, [MailMessage]) -> Void)?
    /// Every unread message id across accounts, after anything that can change it, so delivered
    /// notifications for mail that has since been read or removed can be withdrawn.
    @ObservationIgnored var onUnreadChanged: ((Set<String>) -> Void)?
    @ObservationIgnored private var newMail = NewMailTracker()

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
                let fresh = newMail.newMessages(in: shown, account: id)
                if !fresh.isEmpty { onNewMail?(account, fresh) }
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
        unreadChanged()
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

    /// A row from the inbox, or from the search results when it is only there (a search reaches
    /// further back than the 50 newest).
    func message(_ id: String, in account: UUID) -> MailMessage? {
        state(for: account).messages.first { $0.id == id }
            ?? (searchAccountID == account ? searchPhase.messages.first { $0.id == id } : nil)
    }

    private func unreadChanged() {
        let unread = states.values.flatMap(\.messages).filter { !$0.isRead }.map(\.id)
        onUnreadChanged?(Set(unread))
    }

    // MARK: - Writing

    /// Opens the composer for a reply, reply all or forward of an opened message. An unsent draft
    /// with text in it is never thrown away for a new one: the composer shows it instead.
    func startResponse(_ kind: Draft.Kind, to body: MessageBody, in accountID: UUID) {
        if let draft, draft.hasContent {
            isComposing = true
            return
        }
        let me = accounts.account(accountID)?.email ?? ""
        let sender = body.from?.address ?? ""
        var to: [String] = []
        var cc: [String] = []
        switch kind {
        case .reply:
            to = [sender]
        case .replyAll:
            (to, cc) = Recipients.replyAll(from: sender, to: body.to.map(\.address),
                                           cc: body.cc.map(\.address), me: me)
        case .forward, .new:
            break
        }
        draft = Draft(kind: kind, accountID: accountID, originalID: body.id,
                      originalSubject: body.subject,
                      to: Recipients.join(to.filter { !$0.isEmpty }).appendingSeparator,
                      cc: Recipients.join(cc).appendingSeparator,
                      subject: "", body: "")
        isComposing = true
    }

    func startNewMessage() {
        if let draft, draft.hasContent {
            isComposing = true
            return
        }
        guard let account = selectedAccount else { return }
        draft = Draft(kind: .new, accountID: account.id, originalID: nil, originalSubject: "",
                      to: "", cc: "", subject: "", body: "")
        isComposing = true
    }

    func discardDraft() {
        draft = nil
        isComposing = false
    }

    /// Sends the draft. On failure the text stays exactly as typed, with the reason under it.
    func sendDraft() async {
        guard var sending = draft, !sending.isSending, sending.sendProblem == nil else { return }
        guard let (url, credential) = connection(for: sending.accountID) else {
            draft?.error = "The password for this account is missing. Enter it in Settings."
            return
        }
        sending.isSending = true
        sending.error = nil
        draft = sending
        do {
            try await client.send(sending, at: url, credential: credential)
            let count = Recipients.parse(sending.to).count + Recipients.parse(sending.cc).count
            draft = nil
            isComposing = false
            sentNotice = count == 1 ? "Sent." : "Sent to \(count) people."
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.sentNotice = nil
            }
        } catch {
            draft?.isSending = false
            draft?.error = describe(error, accountID: sending.accountID)
        }
    }

    /// Addresses to offer while typing a recipient: everyone who has written to any inbox here,
    /// from the rows already in memory. Nothing is looked up anywhere.
    func recipientSuggestions(for token: String, excluding typed: String) -> [(name: String, address: String)] {
        let needle = token.lowercased()
        guard needle.count >= 2 else { return [] }
        let already = Set(Recipients.parse(typed).map { $0.lowercased() })
        var seen: Set<String> = []
        var result: [(name: String, address: String)] = []
        for message in states.values.flatMap(\.messages) {
            let address = message.senderAddress
            let key = address.lowercased()
            guard Recipients.isValid(address), !already.contains(key), !seen.contains(key),
                  key.contains(needle) || message.senderName.lowercased().contains(needle) else { continue }
            seen.insert(key)
            result.append((message.senderName, address))
            if result.count == 4 { break }
        }
        return result
    }

    // MARK: - Invitations (M17)

    /// Answers an invitation email. The organizer is told; the event in the calendar follows.
    func answerInvitation(_ answer: CalendarSOAP.Answer, message id: String, in accountID: UUID,
                          note: String) async throws {
        guard let (url, credential) = connection(for: accountID) else {
            throw EWSError.server("The password for this account is missing. Enter it in Settings.")
        }
        try await client.answer(answer, to: id, note: note, at: url, credential: credential)
        await setRead(true, message: id, in: accountID)
    }

    // MARK: - Searching

    /// Runs the typed query against the server, for the selected account. A result that comes
    /// back after the query changed is dropped, so fast typing never shows stale matches.
    func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let account = selectedAccount else {
            searchPhase = .idle
            return
        }
        guard let (url, credential) = connection(for: account.id) else {
            searchPhase = .failed("The password for this account is missing. Enter it in Settings.")
            return
        }
        searchPhase = .searching
        searchAccountID = account.id
        do {
            let found = try await client.searchInbox(query, at: url, credential: credential,
                                                     modern: isModern(account.id))
            guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchPhase = .results(found)
        } catch is CancellationError {
            return
        } catch {
            guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchPhase = .failed(describe(error, accountID: account.id))
        }
    }

    func closeSearch() {
        isSearchOpen = false
        searchQuery = ""
        searchPhase = .idle
        searchAccountID = nil
    }

    /// The endpoint and a fresh credential, read from the Keychain for this one call.
    func connection(for accountID: UUID) -> (URL, EWSCredential)? {
        guard let account = accounts.account(accountID),
              let url = account.endpoint,
              let password = accounts.passwords.password(for: accountID) else { return nil }
        return (url, EWSCredential(username: account.username, password: password))
    }

    /// The Exchange version the last poll reported, or nil before the first answer.
    func serverVersion(_ accountID: UUID) -> ServerVersion? {
        versions[accountID]
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
        guard let (url, credential) = connection(for: accountID),
              let removed = message(id, in: accountID) else { return }
        let messages = state(for: accountID).messages
        let index = messages.firstIndex(where: { $0.id == id })
        let searchBefore = searchPhase
        if let index {
            var remaining = messages
            remaining.remove(at: index)
            states[accountID] = .from(remaining)
            if !removed.isRead { unreadCounts[accountID] = max(0, (unreadCounts[accountID] ?? 0) - 1) }
        }
        if case .results(let list) = searchPhase, searchAccountID == accountID {
            searchPhase = .results(list.filter { $0.id != id })
        }
        if openMessage?.messageID == id { openMessage = nil }
        edits[id] = Edit(removed: true, at: Date())

        unreadChanged()

        do {
            try await request(client, url, credential, isModern(accountID))
            edits[id]?.at = Date()
        } catch {
            edits[id] = nil
            if let index {
                var restored = state(for: accountID).messages
                restored.insert(removed, at: min(index, restored.count))
                states[accountID] = .from(restored)
                if !removed.isRead { unreadCounts[accountID] = (unreadCounts[accountID] ?? 0) + 1 }
            }
            if searchAccountID == accountID, case .results = searchBefore { searchPhase = searchBefore }
            actionError = describe(error, accountID: accountID)
        }
    }

    private func replace(_ message: MailMessage, in accountID: UUID, unreadDelta: Int) {
        if case .results(var list) = searchPhase, searchAccountID == accountID,
           let index = list.firstIndex(where: { $0.id == message.id }) {
            list[index] = message
            searchPhase = .results(list)
        }
        var messages = state(for: accountID).messages
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
            states[accountID] = .from(messages)
            unreadCounts[accountID] = max(0, (unreadCounts[accountID] ?? 0) + unreadDelta)
        }
        unreadChanged()
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

private extension String {
    /// "a, b" becomes "a, b, " so the next address can be typed straight away; empty stays empty.
    var appendingSeparator: String { isEmpty ? "" : self + ", " }
}
