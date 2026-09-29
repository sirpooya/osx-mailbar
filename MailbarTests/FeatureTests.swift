import Foundation
import WebKit
import Testing
@testable import Mailbar

private func message(_ id: String, read: Bool = false) -> MailMessage {
    MailMessage(id: id, changeKey: "", senderName: "A", senderAddress: "", subject: "S", preview: "",
                received: Date(), isRead: read, isFlagged: false, hasAttachments: false)
}

/// M7: which messages are announced.
@Suite struct NewMailTrackerTests {
    private let account = UUID()

    @Test func theFirstPollIsABaselineAndAnnouncesNothing() {
        var tracker = NewMailTracker()
        #expect(tracker.newMessages(in: [message("1"), message("2")], account: account).isEmpty)
    }

    @Test func anUnreadArrivalIsAnnouncedOnce() {
        var tracker = NewMailTracker()
        _ = tracker.newMessages(in: [message("1")], account: account)
        #expect(tracker.newMessages(in: [message("2"), message("1")], account: account).map(\.id) == ["2"])
        #expect(tracker.newMessages(in: [message("2"), message("1")], account: account).isEmpty)
    }

    @Test func mailThatArrivesAlreadyReadIsNotAnnounced() {
        var tracker = NewMailTracker()
        _ = tracker.newMessages(in: [], account: account)
        #expect(tracker.newMessages(in: [message("3", read: true)], account: account).isEmpty)
    }

    @Test func accountsAreTrackedSeparately() {
        var tracker = NewMailTracker()
        let other = UUID()
        _ = tracker.newMessages(in: [message("1")], account: account)
        // First sight of the other account is its own baseline, even for an id seen elsewhere.
        #expect(tracker.newMessages(in: [message("9")], account: other).isEmpty)
    }
}

/// M8: the search request.
@Suite struct SearchRequestTests {
    @Test func modernSearchUsesTheServerIndex() throws {
        let body = SOAP.search(#"review "notes""#, limit: 50, modern: true)
        #expect(body.contains("<m:QueryString>review &quot;notes&quot;</m:QueryString>"))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2013, body: body))
        let find = try #require(root.first("FindItem"))
        // Schema order: ParentFolderIds, then QueryString, last.
        #expect(find.children.map(\.name).suffix(2) == ["ParentFolderIds", "QueryString"])
    }

    @Test func sentItemsIsListedAndSearchedWithItsRecipients() {
        let list = SOAP.findMessages(in: .sent, limit: 50, modern: true)
        #expect(list.contains(#"<t:DistinguishedFolderId Id="sentitems"/>"#))
        #expect(list.contains("item:DisplayTo"))
        #expect(SOAP.search("agenda", in: .sent, limit: 50, modern: true).contains(#"Id="sentitems""#))
        #expect(SOAP.search("agenda", limit: 50, modern: true).contains(#"Id="inbox""#))
    }

    @Test func highlightTermsDropQuotesAndOperators() {
        #expect(Set(SearchHighlight.terms(in: #"from:sara "review" AND notes"#)) == ["sara", "review", "notes"])
    }

    @Test func highlightMatchesIgnoreCaseAndTheArabicYeAndKaf() {
        let text = "Design Review, then the review notes"
        #expect(SearchHighlight.ranges(of: ["review"], in: text).map { String(text[$0]) } == ["Review", "review"])
        // Typed on an Arabic keyboard (ي, ك), found in Persian text (ی, ک).
        let persian = "تیکت فیگما ماه شهریور"
        #expect(SearchHighlight.ranges(of: ["تيكت"], in: persian).map { String(persian[$0]) } == ["تیکت"])
        // Overlapping terms mark one run.
        #expect(SearchHighlight.ranges(of: ["desi", "sign"], in: "Design").count == 1)
    }

    @Test func olderServersGetASubstringRestrictionBeforeTheSortOrder() throws {
        let body = SOAP.search("budget", limit: 50, modern: false)
        #expect(!body.contains("QueryString"))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let find = try #require(root.first("FindItem"))
        #expect(find.children.map(\.name) == ["ItemShape", "IndexedPageItemView", "Restriction", "SortOrder", "ParentFolderIds"])
        #expect(root.all("Contains").count == 2)
    }
}

@MainActor
@Suite struct SearchAndAttachmentTests {
    private let work = MockMode.accounts[0]

    private func makeStore() async -> MailStore {
        let accounts = AccountStore(inMemory: MockMode.accounts, passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox)))
        store.selectedAccountID = work.id
        await store.refresh()
        return store
    }

    @Test func searchReturnsOnlyMatches() async {
        let store = await makeStore()
        store.searchQuery = "booking"
        await store.runSearch()
        #expect(store.searchPhase.messages.map(\.subject) == ["Your booking is confirmed"])
    }

    @Test func aOneLetterQueryDoesNotSearch() async {
        let store = await makeStore()
        store.searchQuery = "b"
        await store.runSearch()
        #expect(store.searchPhase == .idle)
    }

    @Test func actingOnASearchResultUpdatesTheResults() async throws {
        let store = await makeStore()
        store.searchQuery = "Travel"
        await store.runSearch()
        let hit = try #require(store.searchPhase.messages.first)
        await store.setFlag(true, message: hit.id, in: work.id)
        #expect(store.searchPhase.messages.first?.isFlagged == true)
        await store.delete(message: hit.id, in: work.id)
        #expect(store.searchPhase.messages.isEmpty)
    }

    @Test func theSentTabListsSentItemsByRecipient() async throws {
        let store = await makeStore()
        store.mailFolder = .sent
        await store.loadSent()
        let sent = try #require(store.sent[work.id]).messages
        #expect(sent.count == MockFixtures.workSent.count)
        #expect(sent.first?.displayTo == "Sara Rahimi")
        // Rows act like Inbox rows: deleting one takes it out of the list.
        let first = try #require(sent.first)
        #expect(store.message(first.id, in: work.id) != nil)
        await store.delete(message: first.id, in: work.id)
        #expect(store.sent[work.id]?.messages.contains { $0.id == first.id } == false)
    }

    @Test func searchLooksInTheFolderTheTabShows() async {
        let store = await makeStore()
        store.isSearchOpen = true
        store.searchQuery = "agenda"
        store.mailFolder = .sent
        await store.runSearch()
        #expect(store.searchFolder == .sent)
        #expect(store.searchPhase.messages.map(\.subject) == ["Quarterly planning agenda"])
        #expect(store.highlightTerms == ["agenda"])
        store.mailFolder = .inbox
        await store.runSearch()
        #expect(store.searchFolder == .inbox)
        #expect(store.searchPhase.messages.isEmpty)
    }

    @Test func realAttachmentsAreListedAndDrawnImagesAreNot() async throws {
        let store = await makeStore()
        let sara = try #require(store.state(for: work.id).messages.first { $0.hasAttachments })
        let (url, credential) = try #require(store.connection(for: work.id))
        let body = try await store.client.message(id: sara.id, at: url, credential: credential)

        #expect(body.files.map(\.name) == ["Review notes.txt"])
        #expect(body.files.first?.size == MockFixtures.notesText.utf8.count)
        let bytes = try await store.client.attachmentContent(id: "att-notes", at: url, credential: credential)
        #expect(String(decoding: bytes, as: UTF8.self) == MockFixtures.notesText)
    }

    @Test func attachmentNamesCannotEscapeTheirFolder() {
        #expect(Attachments.safeName("../../etc/passwd") == "-..-etc-passwd")
        #expect(Attachments.safeName(".hidden") == "hidden")
        #expect(Attachments.safeName("  ") == "Attachment")
        #expect(Attachments.safeName("Report: Q3/final.pdf") == "Report- Q3-final.pdf")
    }
}

/// The reader's body marks, run in a real web view with the page's own script off, as the reader has it.
@MainActor
@Suite struct SearchHighlightBodyTests {
    @Test func theBodyScriptMarksEveryMatchAndLeavesTheRestAlone() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        web.loadHTMLString("<html><body><p>گزارش شهریور</p><div>تیکت <b>شهریور</b> و Review</div></body></html>", baseURL: nil)
        for _ in 0..<50 {
            let loaded = try? await web.evaluateJavaScript("document.body ? document.body.innerText.length : 0",
                                                           in: nil, contentWorld: .defaultClient)
            if ((loaded as? NSNumber)?.intValue ?? 0) > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Typed with the Arabic ye, as on an Arabic keyboard.
        let count = try await web.callAsyncJavaScript(SearchHighlight.bodyScript, arguments: ["terms": ["شهريور", "review"]],
                                                      in: nil, contentWorld: .defaultClient)
        #expect((count as? NSNumber)?.intValue == 3)
        let text = try await web.evaluateJavaScript("document.body.innerText", in: nil, contentWorld: .defaultClient) as? String
        #expect(text?.contains("تیکت شهریور و Review") == true)
    }
}
