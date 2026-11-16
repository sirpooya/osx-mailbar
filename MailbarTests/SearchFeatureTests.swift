import Foundation
import Testing
@testable import Mailbar

/// Search after Outlook (2026-11-16): scope, criteria, typed keywords, saved searches, Events
/// and People. Requests are checked against the schema's element order; the store runs
/// against the mock server.
@Suite struct SearchQueryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10))! }

    @Test func criteriaBecomeAQS() {
        var criteria = SearchCriteria()
        criteria.from = "Sara Rahimi"
        criteria.subject = "review"
        criteria.receivedAfter = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))
        criteria.hasAttachments = true
        #expect(criteria.aqs == #"from:"Sara Rahimi" subject:review received:>=11/1/2026 hasattachment:true"#)
        let query = SearchQuery(text: "from:omid budget", criteria: criteria)
        #expect(query.queryString.hasPrefix("from:omid budget from:\"Sara Rahimi\""))
        #expect(query.freeText == "budget")
        #expect(SearchQuery(text: "", criteria: criteria).isSearchable)
        #expect(!SearchQuery(text: "a").isSearchable)
    }

    @Test func typedKeywordsAreReadForOlderServers() {
        let parsed = ParsedSearch.parse(#"from:sara hasattachment:yes received:yesterday "design review" AND to:omid"#,
                                        now: now, calendar: calendar)
        #expect(parsed.from == ["sara"])
        #expect(parsed.to == ["omid"])
        #expect(parsed.hasAttachments == true)
        #expect(parsed.words == ["design review"])
        #expect(parsed.after == calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        #expect(parsed.before == calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let range = ParsedSearch.parse("received:>=11/1/2026 received:<2026-11-10", now: now, calendar: calendar)
        #expect(range.after == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(range.before == calendar.date(from: DateComponents(year: 2026, month: 11, day: 10)))
    }

    @Test func modernSearchOverSeveralFoldersPassesAQSThrough() throws {
        let query = SearchQuery(text: "from:sara hasattachment:yes")
        let body = SOAP.searchMail(in: [.distinguished("inbox"), .folder("AAMk-custom")], query: query,
                                   limit: 50, modern: true)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2013, body: body))
        let find = try #require(root.first("FindItem"))
        #expect(find.attributes["Traversal"] == "Shallow")
        #expect(find.children.map(\.name).suffix(2) == ["ParentFolderIds", "QueryString"])
        #expect(find.child("ParentFolderIds")?.children.count == 2)
        #expect(find.child("QueryString")?.trimmedText == "from:sara hasattachment:yes")
        #expect(body.contains(#"FieldURI="item:ParentFolderId""#))
        #expect(root.first("Restriction") == nil)
    }

    @Test func olderServersGetOneRestrictionFromTheKeywords() throws {
        var criteria = SearchCriteria()
        criteria.receivedBefore = now
        let query = SearchQuery(text: "from:sara subject:tokens hasattachment:true budget", criteria: criteria)
        let body = SOAP.searchMail(in: [.distinguished("sentitems")], query: query, limit: 50, modern: false,
                                   now: now, calendar: calendar)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let find = try #require(root.first("FindItem"))
        #expect(find.children.map(\.name) == ["ItemShape", "IndexedPageItemView", "Restriction", "SortOrder", "ParentFolderIds"])
        #expect(!body.contains("QueryString"))
        let and = try #require(find.child("Restriction")?.child("And"))
        // Words in subject or body, sender name or address, subject, attachments, received before.
        #expect(and.children.map(\.name) == ["Or", "Or", "Contains", "IsEqualTo", "IsLessThan"])
        #expect(body.contains(#"PropertyTag="0x0C1A""#) && body.contains(#"PropertyTag="0x5D01""#))
        #expect(body.contains("2026-11-17T00:00:00Z"))
    }

    @Test func eventsAreFoundByQueryStringOrTitleAndPlace() throws {
        let modern = try XMLTree.parse(SOAP.envelope(.exchange2013, body: SOAP.searchEvents("planning", limit: 25, modern: true)))
        let find = try #require(modern.first("FindItem"))
        #expect(find.child("CalendarView") == nil)
        #expect(find.children.map(\.name).suffix(2) == ["ParentFolderIds", "QueryString"])
        let older = SOAP.searchEvents("planning", limit: 25, modern: false)
        #expect(older.contains(#"FieldURI="calendar:Location""#) && !older.contains("QueryString"))
        #expect(try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: older)).first("Restriction") != nil)
    }

    @Test func keywordNamesAndNonTextValuesAreNeverMarked() {
        #expect(Set(SearchHighlight.terms(in: "from:sara hasattachment:yes received:yesterday review")) == ["sara", "review"])
        var criteria = SearchCriteria()
        criteria.subject = "tokens"
        criteria.hasAttachments = true
        #expect(Set(SearchHighlight.terms(in: SearchQuery(text: "x", criteria: criteria))) == ["tokens"])
    }

    @Test func savedSearchesRoundTripThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "SearchFeatureTests.\(UUID().uuidString)"))
        var criteria = SearchCriteria()
        criteria.from = "sara"
        let saved = [SavedSearch(name: "Sara", query: "tokens", scope: .allFolders, includeDeleted: true, criteria: criteria)]
        SavedSearch.save(saved, to: defaults)
        #expect(SavedSearch.load(defaults) == saved)
        SavedSearch.save([], to: defaults)
        #expect(defaults.object(forKey: Keys.savedSearches) == nil)
    }
}

@MainActor
@Suite struct SearchStoreTests {
    private let work = MockMode.accounts[0]
    private let team = MockMode.accounts[1]

    private func makeStore() async -> MailStore {
        let accounts = AccountStore(inMemory: MockMode.accounts, passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox)))
        store.selectedAccountID = work.id
        await store.refresh()
        store.isSearchOpen = true
        return store
    }

    @Test func allFoldersFindsMailEverywhereAndNamesTheFolder() async {
        let store = await makeStore()
        store.searchQuery = "design review notes"
        await store.runSearch()
        #expect(store.searchPhase.messages.count == 1)
        #expect(store.searchExtras.spansFolders == false)

        store.searchExtras.scope = .allFolders
        await store.runSearch()
        let found = store.searchPhase.messages
        #expect(found.map(\.subject).sorted() == ["Design review notes and the updated spacing tokens",
                                                  "Re: Design review notes and the updated spacing tokens"])
        #expect(store.searchExtras.spansFolders)
        #expect(Set(found.compactMap { store.searchExtras.folderNames[$0.id] }) == ["Inbox", "Sent Items"])
    }

    @Test func deletedItemsJoinOnlyWhenAsked() async {
        let store = await makeStore()
        let sara = store.state(for: work.id).messages.first { $0.subject.hasPrefix("Design review notes") }!
        await store.delete(message: sara.id, in: work.id)
        store.searchExtras.scope = .allFolders
        store.searchQuery = "spacing tokens"
        await store.runSearch()
        #expect(!store.searchPhase.messages.contains { $0.id == sara.id })
        store.searchExtras.includeDeleted = true
        await store.runSearch()
        #expect(store.searchExtras.folderNames[sara.id] == "Deleted Items")
    }

    @Test func theOnlineArchiveIsProbedOnceAndSearched() async {
        let store = await makeStore()
        await store.probeOnlineArchive(for: work.id)
        await store.probeOnlineArchive(for: team.id)
        #expect(store.searchExtras.onlineArchive[work.id] == true)
        #expect(store.searchExtras.onlineArchive[team.id] == false)

        store.searchExtras.scope = .onlineArchive
        store.searchQuery = "review"
        await store.runSearch()
        #expect(store.searchPhase.messages.map(\.subject) == ["Design review: last year's component audit",
                                                              "Project Atlas wrap-up and review"])
        #expect(store.searchPhase.messages.compactMap { store.searchExtras.folderNames[$0.id] } == ["Archive 2024", "Old Projects"])
        // No Events section for the archive.
        #expect(store.searchExtras.events.isEmpty)

        // The team mailbox has none, so the same scope searches the folder showing.
        store.selectedAccountID = team.id
        #expect(store.effectiveSearchScope == .thisFolder)
    }

    @Test func typedKeywordsAndCriteriaNarrowTheResults() async {
        let store = await makeStore()
        store.searchQuery = "from:sara hasattachment:yes"
        await store.runSearch()
        let typed = store.searchPhase.messages
        #expect(!typed.isEmpty)
        #expect(typed.allSatisfy { $0.senderAddress.hasPrefix("sara") && $0.hasAttachments })

        store.searchQuery = ""
        store.searchExtras.criteria.from = "sara"
        store.searchExtras.criteria.hasAttachments = true
        #expect(store.hasSearchInput)
        await store.runSearch()
        #expect(store.searchPhase.messages.map(\.id) == typed.map(\.id))
        #expect(store.highlightTerms == ["sara"])
    }

    @Test func eventsAndPeopleSitBesideTheMail() async {
        let store = await makeStore()
        store.searchQuery = "planning"
        await store.runSearch()
        #expect(store.searchExtras.events.contains { $0.subject == "Quarterly planning" })
        #expect(store.searchExtras.events.count <= 5)

        store.searchQuery = "sara"
        await store.runSearch()
        #expect(store.searchExtras.people.contains { $0.address == "sara.rahimi@example.com" })
        #expect(store.searchExtras.people.count <= 5)

        // Keywords alone look for mail only.
        store.searchQuery = "from:sara"
        await store.runSearch()
        #expect(store.searchExtras.people.isEmpty && store.searchExtras.events.isEmpty)
    }

    @Test func savedSearchesRunAgainAndAreNotWrittenFromTests() async {
        let store = await makeStore()
        let before = UserDefaults.standard.data(forKey: Keys.savedSearches)
        store.searchExtras.saved = []
        store.searchQuery = "booking"
        store.searchExtras.scope = .allFolders
        store.saveSearch(named: "Trips")
        #expect(store.searchExtras.saved.map(\.name) == ["Trips"])
        #expect(UserDefaults.standard.data(forKey: Keys.savedSearches) == before)

        store.closeSearch()
        #expect(store.searchExtras.criteria.isEmpty)
        store.runSavedSearch(store.searchExtras.saved[0])
        #expect(store.isSearchOpen && store.searchQuery == "booking" && store.searchExtras.scope == .allFolders)
        await store.runSearch()
        // All Folders reaches the folders of the tree too: a receipt filed under Inbox/Receipts.
        let found = store.searchPhase.messages
        #expect(found.map(\.subject) == ["Your booking is confirmed", "Receipt: train tickets"])
        #expect(found.map { store.searchExtras.folderNames[$0.id] } == ["Inbox", "Receipts"])

        store.renameSavedSearch(store.searchExtras.saved[0].id, to: "Travel")
        #expect(store.searchExtras.saved.map(\.name) == ["Travel"])
        store.deleteSavedSearch(store.searchExtras.saved[0].id)
        #expect(store.searchExtras.saved.isEmpty)
    }

    @Test func aPersonsCardStartsAMessageToThem() async {
        let store = await makeStore()
        store.startMessage(to: "sara.rahimi@example.com")
        #expect(store.draft?.to == "sara.rahimi@example.com")
        #expect(store.isComposing)
    }
}
