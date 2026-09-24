import Foundation
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
        let body = SOAP.searchInbox(#"review "notes""#, limit: 50, modern: true)
        #expect(body.contains("<m:QueryString>review &quot;notes&quot;</m:QueryString>"))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2013, body: body))
        let find = try #require(root.first("FindItem"))
        // Schema order: ParentFolderIds, then QueryString, last.
        #expect(find.children.map(\.name).suffix(2) == ["ParentFolderIds", "QueryString"])
    }

    @Test func olderServersGetASubstringRestrictionBeforeTheSortOrder() throws {
        let body = SOAP.searchInbox("budget", limit: 50, modern: false)
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
