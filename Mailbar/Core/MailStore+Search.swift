import Foundation

// Search, after Outlook (2026-11-16): scope, criteria, typed keywords, saved searches, and the
// Events and People sections. Results stay in memory, the selected account only, and go when
// the search closes, exactly as M8's did.

extension MailStore {

    /// What is typed plus the criteria.
    var currentSearch: SearchQuery { SearchQuery(text: searchQuery, criteria: searchExtras.criteria) }

    /// The field holds something to search for: two characters, or a criterion.
    var hasSearchInput: Bool { isSearchOpen && currentSearch.isSearchable }

    /// The scope the next search uses for the selected account.
    var effectiveSearchScope: SearchScope { searchExtras.scope(for: selectedAccount?.id) }

    /// Everything that decides what a search returns; a result for any other key is stale.
    private func searchKey(accountID: UUID) -> String {
        let extras = searchExtras
        let criteria = String(describing: extras.criteria)
        return [accountID.uuidString, currentSearch.trimmedText, criteria, extras.scope(for: accountID).rawValue,
                "\(extras.includeDeleted)", "\(mailFolder)"].joined(separator: "|")
    }

    /// The search itself, called by `runSearch`: mail in the chosen scope, and beside it the
    /// Events and People sections when plain words were typed. Each part that comes back after
    /// the query, the scope or the folder changed is dropped.
    func performSearch() async {
        let query = currentSearch
        let folder = mailFolder
        guard query.isSearchable, let account = selectedAccount else {
            searchPhase = .idle
            searchExtras.clearResults()
            return
        }
        guard let (url, credential) = connection(for: account.id) else {
            searchPhase = .failed("The password for this account is missing. Enter it in Settings.")
            return
        }
        let key = searchKey(accountID: account.id)
        let current = { [weak self] in self?.searchKey(accountID: account.id) == key }
        let scope = searchExtras.scope(for: account.id)
        let modern = isModern(account.id)
        searchPhase = .searching
        searchAccountID = account.id
        searchFolder = folder

        let words = query.freeText
        async let events: [CalendarEvent] = scope == .onlineArchive || words.count < 2 ? []
            : searchEvents(words, modern: modern, url: url, credential: credential)
        async let people: [PersonSuggestion] = words.count < 2 ? []
            : peopleSuggestions(for: words, excluding: "", accountID: account.id, limit: 5)

        do {
            let found = try await searchMail(query, scope: scope, folder: folder, accountID: account.id,
                                             url: url, credential: credential, modern: modern)
            guard current() else { return }
            searchExtras.folderNames = found.names
            searchExtras.spansFolders = found.spans
            searchPhase = .results(found.messages)
        } catch is CancellationError {
            return
        } catch {
            guard current() else { return }
            searchPhase = .failed(describe(error, accountID: account.id))
        }
        let (foundEvents, foundPeople) = await (events, people)
        guard current() else { return }
        searchExtras.events = foundEvents
        searchExtras.people = foundPeople
    }

    private struct MailFound {
        var messages: [MailMessage]
        var names: [String: String] = [:]
        var spans = false
    }

    private func searchMail(_ query: SearchQuery, scope: SearchScope, folder: MailFolder, accountID: UUID,
                            url: URL, credential: EWSCredential, modern: Bool) async throws -> MailFound {
        switch scope {
        case .thisFolder:
            let parent: SearchParent
            switch folder {
            case .archive:
                guard let id = try await archiveFolderID(for: accountID, url: url, credential: credential) else {
                    return MailFound(messages: [])
                }
                parent = .folder(id)
            case .custom(let custom):
                parent = .folder(custom.id)
            default:
                parent = .distinguished(folder.distinguishedID ?? "inbox")
            }
            var hits = try await client.searchMail(in: [parent], query: query, modern: modern,
                                                   at: url, credential: credential).map(\.message)
            if folder == .flagged { hits = hits.filter(\.isFlagged) }
            return MailFound(messages: hits)

        case .allFolders:
            let (parents, names) = await allFolderParents(accountID: accountID, url: url, credential: credential)
            return try await searchSeveral(parents, names: names, query: query, url: url,
                                           credential: credential, modern: modern)

        case .onlineArchive:
            var folders = searchExtras.archiveFolders[accountID] ?? []
            if folders.isEmpty {
                folders = try await client.onlineArchiveFolders(at: url, credential: credential)
                searchExtras.archiveFolders[accountID] = folders
            }
            let names = Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return try await searchSeveral(folders.map { .folder($0.id) }, names: names, query: query, url: url,
                                           credential: credential, modern: modern)
        }
    }

    /// Every mail folder to look in, with the name of each id the server may report: the
    /// standard folders by their distinguished ids, the Archive folder, and every other folder
    /// of the tree the folder menu reads (`loadFolderTree`). Deleted Items and the folders under
    /// it only when asked for.
    private func allFolderParents(accountID: UUID, url: URL,
                                  credential: EWSCredential) async -> ([SearchParent], [String: String]) {
        let includeDeleted = searchExtras.includeDeleted
        var standard: [MailFolder] = [.inbox, .sent, .junk]
        if includeDeleted { standard.append(.deleted) }
        var parents: [SearchParent] = standard.compactMap { $0.distinguishedID.map(SearchParent.distinguished) }
        var names: [String: String] = [:]
        for folder in standard { if let id = folder.distinguishedID { names[id] = folder.title } }
        let archiveID = try? await archiveFolderID(for: accountID, url: url, credential: credential)
        if let archiveID {
            parents.append(.folder(archiveID))
            names[archiveID] = MailFolder.archive.title
        }
        await loadFolderTree(for: accountID)
        let tree = listActions.folderTrees[accountID]?.folders ?? []
        var skipBelow: Int?
        for folder in tree {
            if let depth = skipBelow {
                if folder.depth > depth { continue }
                skipBelow = nil
            }
            if folder.wellKnown == "deleteditems", !includeDeleted {
                skipBelow = folder.depth
                continue
            }
            names[folder.id] = folder.name
            if folder.wellKnown == nil, folder.id != archiveID { parents.append(.folder(folder.id)) }
        }
        return (parents, names)
    }

    /// One request over several folders (`ParentFolderIds` takes many). If the server refuses
    /// that, or is older than 2013, each folder is asked on its own, at most twenty at once,
    /// and the answers are merged newest first.
    private func searchSeveral(_ parents: [SearchParent], names: [String: String], query: SearchQuery,
                               url: URL, credential: EWSCredential, modern: Bool) async throws -> MailFound {
        guard !parents.isEmpty else { return MailFound(messages: []) }
        var hits: [SearchHit]
        do {
            guard modern else { throw EWSError.server("One folder at a time.") }
            hits = try await client.searchMail(in: parents, query: query, modern: modern, at: url, credential: credential)
        } catch EWSError.server {
            let client = self.client
            hits = try await withThrowingTaskGroup(of: [SearchHit].self) { group in
                for parent in parents.prefix(20) {
                    group.addTask {
                        do {
                            return try await client.searchMail(in: [parent], query: query, modern: modern,
                                                               at: url, credential: credential)
                                .map { SearchHit(message: $0.message, folderID: $0.folderID ?? parent.id) }
                        } catch EWSError.server {
                            return []
                        }
                    }
                }
                var all: [SearchHit] = []
                for try await part in group { all += part }
                return all
            }
        }
        var seen = Set<String>()
        hits = hits.filter { seen.insert($0.message.id).inserted }
            .sorted { $0.message.received > $1.message.received }
        hits = Array(hits.prefix(EWSClient.pageSize))
        var byItem: [String: String] = [:]
        for hit in hits { if let id = hit.folderID, let name = names[id] { byItem[hit.message.id] = name } }
        return MailFound(messages: hits.map(\.message), names: byItem, spans: true)
    }

    /// Up to five events: those still to come, soonest first, then past ones, latest first.
    private func searchEvents(_ text: String, modern: Bool, url: URL, credential: EWSCredential) async -> [CalendarEvent] {
        guard let found = try? await client.searchEvents(text, modern: modern, at: url, credential: credential) else { return [] }
        let now = Date()
        let coming = found.filter { $0.end >= now }.sorted { $0.start < $1.start }
        let past = found.filter { $0.end < now }.sorted { $0.start > $1.start }
        // One row per title: a series the server lists occurrence by occurrence shows once.
        var titles = Set<String>()
        return Array((coming + past).filter { titles.insert($0.subject.lowercased()).inserted }.prefix(5))
    }

    // MARK: - Online Archive

    /// Asks once per account whether the mailbox has an Online Archive; the answer is kept in
    /// memory. A failed ask is asked again next time.
    func probeOnlineArchive(for accountID: UUID) async {
        guard searchExtras.onlineArchive[accountID] == nil, !searchExtras.probing.contains(accountID),
              let (url, credential) = connection(for: accountID) else { return }
        searchExtras.probing.insert(accountID)
        defer { searchExtras.probing.remove(accountID) }
        if let has = try? await client.hasOnlineArchive(at: url, credential: credential) {
            searchExtras.onlineArchive[accountID] = has
        }
    }

    // MARK: - Saved searches

    /// Keeps what is typed, the scope and the criteria under `name`. Written to UserDefaults
    /// only when the account list itself is (never in tests).
    func saveSearch(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let saved = SavedSearch(name: clean, query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                                scope: searchExtras.scope, includeDeleted: searchExtras.includeDeleted,
                                criteria: searchExtras.criteria)
        searchExtras.saved.removeAll { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
        searchExtras.saved.append(saved)
        persistSavedSearches()
    }

    func deleteSavedSearch(_ id: UUID) {
        searchExtras.saved.removeAll { $0.id == id }
        persistSavedSearches()
    }

    func renameSavedSearch(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = searchExtras.saved.firstIndex(where: { $0.id == id }) else { return }
        searchExtras.saved[index].name = clean
        persistSavedSearches()
    }

    /// Puts a saved search back in the field; the field's own task runs it.
    func runSavedSearch(_ saved: SavedSearch) {
        isSearchOpen = true
        searchExtras.scope = saved.scope
        searchExtras.includeDeleted = saved.includeDeleted
        searchExtras.criteria = saved.criteria
        searchQuery = saved.query
    }

    private func persistSavedSearches() {
        guard accounts.persists else { return }
        SavedSearch.save(searchExtras.saved)
    }

    // MARK: - People

    /// Starts a message to `address`, unless a draft with text is already open, which is kept.
    func startMessage(to address: String) {
        startNewMessage()
        if draft?.hasContent == false, draft?.to.isEmpty == true {
            draft?.to = address
        }
    }
}
