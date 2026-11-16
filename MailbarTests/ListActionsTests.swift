import Foundation
import Testing
@testable import Mailbar

/// M20 (list actions) and M21 (junk and folders): request shapes, reply parsing, and the store
/// end to end against the stateful mock server.
@Suite struct ListActionsRequestTests {
    @Test func moveAsksForTheNewIdsAndKeepsTheSchemaOrder() throws {
        let body = SOAP.moveItems(ids: ["a", "b&c"], to: .distinguished("deleteditems"))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let move = try #require(root.first("MoveItem"))
        #expect(move.children.map(\.name) == ["ToFolderId", "ItemIds", "ReturnNewItemIds"])
        #expect(move.first("ItemIds")?.children.compactMap { $0.attributes["Id"] } == ["a", "b&c"])
        #expect(body.contains(#"<t:DistinguishedFolderId Id="deleteditems"/>"#))
        #expect(SOAP.moveItems(ids: ["a"], to: .id("F1")).contains(#"<t:FolderId Id="F1"/>"#))
    }

    @Test func junkMovesAndNotJunkMovesBack() {
        #expect(SOAP.markAsJunk(ids: ["a"], junk: true).contains(#"<m:MarkAsJunk IsJunk="true" MoveItem="true">"#))
        #expect(SOAP.markAsJunk(ids: ["a"], junk: false).contains(#"IsJunk="false" MoveItem="true""#))
    }

    @Test func emptyingNeverHardDeletes() {
        let deleted = SOAP.emptyFolder(.distinguished("deleteditems"), deleteType: .softDelete)
        #expect(deleted.contains(#"DeleteType="SoftDelete" DeleteSubFolders="false""#))
        let junk = SOAP.emptyFolder(.distinguished("junkemail"), deleteType: .moveToDeletedItems)
        #expect(junk.contains(#"DeleteType="MoveToDeletedItems""#))
        #expect(!deleted.contains("HardDelete") && !junk.contains("HardDelete"))
        #expect(MailStore.emptyTarget(.inbox) == nil && MailStore.emptyTarget(.archive) == nil)
    }

    @Test func manyReadsAreOneRequestWithAChangeEach() throws {
        let body = SOAP.setRead(ids: ["a", "b", "c"], read: true, modern: true)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2013, body: body))
        #expect(root.all("ItemChange").count == 3)
        #expect(root.first("UpdateItem")?.attributes["SuppressReadReceipts"] == "true")
        let flags = SOAP.setFlag(ids: ["a", "b"], flagged: false, modern: false)
        #expect(flags.components(separatedBy: "<t:DeleteItemField>").count == 3)
    }

    @Test func aCustomFolderIsListedByItsId() {
        let folder = MailboxFolder(id: "F&1", name: "Projects")
        #expect(SOAP.findMessages(in: .custom(folder), limit: 50, modern: true).contains(#"<t:FolderId Id="F&amp;1"/>"#))
        #expect(MailFolder.custom(folder).title == "Projects")
        // Equal by id: a renamed folder is the same list.
        #expect(MailFolder.custom(folder) == .custom(MailboxFolder(id: "F&1", name: "Renamed")))
    }

    @Test func movedIdsAreReadInOrderIncludingJunks() throws {
        let moved = try EWSResponse.movedIDs(from: Data(MockFixtures.moved(["n1", "n2"], operation: "MoveItem").utf8))
        #expect(moved == ["n1", "n2"])
        let junk = try EWSResponse.movedIDs(from: Data(MockFixtures.moved(["j1"], operation: "MarkAsJunk").utf8))
        #expect(junk == ["j1"])
    }

    @Test func theTreeKeepsMailFoldersInOutlooksOrder() throws {
        let known = Dictionary(uniqueKeysWithValues: SOAP.wellKnownNames.map { ($0, MockFixtures.wellKnownID($0, prefix: "work")) })
        let folders = try EWSResponse.mailFolders(from: Data(MockFixtures.findFolderTree(prefix: "work").utf8),
                                                  wellKnown: known, archiveID: "work-archive")
        let names = folders.map { String(repeating: ".", count: $0.depth) + $0.name }
        #expect(names == ["Inbox", ".Receipts", "Sent Items", "Archive", "Deleted Items", "Junk Email",
                          "Newsletters", "Projects", ".Atlas", ".Budget 2026", "گزارش‌ها"])
        // Drafts (and its child), Outbox, the calendar and the hidden folder are left out.
        #expect(!names.contains { $0.contains("Drafts") || $0.contains("Templates") || $0.contains("Outbox")
            || $0.contains("Calendar") || $0.contains("Conversation") })
        #expect(folders.first?.mailFolder == .inbox)
        #expect(folders.first { $0.name == "Archive" }?.mailFolder == .archive)
        #expect(folders.first { $0.name == "Atlas" }?.mailFolder == .custom(MailboxFolder(id: "work-folder-atlas", name: "")))
    }

    @Test func unsubscribePrefersHttpsThenMailto() throws {
        let both = try #require(UnsubscribeLink.parse("<mailto:leave@example.net?subject=bye>, <https://example.net/u?x=1>"))
        #expect(both.preferred == .web(URL(string: "https://example.net/u?x=1")!))
        let mail = try #require(UnsubscribeLink.parse("<mailto:stop@example.net?subject=Remove%20me&body=now>"))
        guard case .mail(let link)? = mail.preferred else { Issue.record("expected mailto"); return }
        #expect(link.address == "stop@example.net" && link.subject == "Remove me" && link.body == "now")
        // Plain http only when there is nothing better.
        let http = try #require(UnsubscribeLink.parse("<http://example.net/u>, <mailto:a@example.net>"))
        guard case .mail? = http.preferred else { Issue.record("expected mailto over http"); return }
        #expect(UnsubscribeLink.parse("no links here") == nil)
    }

    @Test func aFoldedRawHeaderIsJoined() {
        let raw = "Subject: Hi\r\nList-Unsubscribe: <mailto:a@example.net>,\r\n <https://example.net/u>\r\nTo: me@example.com\r\n"
        #expect(UnsubscribeLink.header(inRawHeaders: raw) == "<mailto:a@example.net>, <https://example.net/u>")
    }

    @Test func shiftExtendsAndCommandToggles() async {
        await MainActor.run {
            let state = ListActionsState()
            let order = ["a", "b", "c", "d"]
            #expect(state.click("b", command: true, shift: false, order: order))
            #expect(state.click("d", command: false, shift: true, order: order))
            #expect(state.selection == ["b", "c", "d"])
            #expect(state.click("c", command: true, shift: false, order: order))
            #expect(state.selection == ["b", "d"])
            // A plain click opens, and clears the selection.
            #expect(!state.click("a", command: false, shift: false, order: order))
            #expect(state.selection.isEmpty)
        }
    }

    @Test func swipeDefaultsAndWhatEachFolderOffers() {
        let defaults = UserDefaults(suiteName: "ListActionsTests.swipe")!
        defaults.removePersistentDomain(forName: "ListActionsTests.swipe")
        #expect(SwipeAction.left(defaults) == .delete && SwipeAction.right(defaults) == .archive)
        defaults.set("flag", forKey: Keys.swipeLeft)
        #expect(SwipeAction.left(defaults) == .flag)
        #expect(!SwipeAction.archive.applies(in: .archive) && !SwipeAction.delete.applies(in: .deleted))
        #expect(SwipeAction.toggleRead.applies(in: .deleted) && !SwipeAction.none.applies(in: .inbox))
    }
}

@MainActor
@Suite struct ListActionsStoreTests {
    private let work = MockMode.accounts[0]

    private func makeStore(_ transport: MockTransport = MockTransport(mode: .inbox)) async -> MailStore {
        let accounts = AccountStore(inMemory: MockMode.accounts, passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: transport))
        store.selectedAccountID = work.id
        await store.refresh()
        return store
    }

    @Test func archiveShowsAToastAndUndoPutsItBack() async throws {
        let store = await makeStore()
        let first = try #require(store.state(for: work.id).messages.first)
        let unread = store.unreadCount(for: work.id)
        await store.archive(message: first.id, in: work.id)
        #expect(store.message(first.id, in: work.id) == nil)
        let toast = try #require(store.listActions.toast)
        #expect(toast.text == "Archived.")
        #expect(toast.undo?.back == .distinguished("inbox"))
        await store.undo(toast)
        #expect(store.listActions.toast == nil)
        #expect(store.state(for: work.id).messages.first?.id == first.id)
        #expect(store.unreadCount(for: work.id) == unread)
        await store.loadFolder(.archive, work.id)
        #expect(store.list(.archive, for: work.id)?.messages.isEmpty == true)
    }

    @Test func deleteIsAMoveSoItCanBeUndone() async throws {
        let transport = MockTransport(mode: .inbox)
        let store = await makeStore(transport)
        let ids = store.state(for: work.id).messages.prefix(3).map(\.id)
        await store.delete(Array(ids), in: work.id)
        #expect(store.listActions.toast?.text == "Deleted 3 messages.")
        await store.loadFolder(.deleted, work.id)
        #expect(Set(store.list(.deleted, for: work.id)?.messages.map(\.id) ?? []) == Set(ids))
        let toast = try #require(store.listActions.toast)
        await store.undo(toast)
        #expect(Array(store.state(for: work.id).messages.prefix(3).map(\.id)) == Array(ids))
    }

    @Test func manyRowsAreMarkedAndFlaggedAtOnce() async throws {
        let store = await makeStore()
        let unread = store.state(for: work.id).messages.filter { !$0.isRead }.prefix(2).map(\.id)
        let before = store.unreadCount(for: work.id)
        await store.setRead(true, ids: Array(unread), in: work.id)
        #expect(store.unreadCount(for: work.id) == before - unread.count)
        await store.setFlag(true, ids: Array(unread), in: work.id)
        await store.refresh()
        #expect(unread.allSatisfy { store.message($0, in: work.id)?.isFlagged == true && store.message($0, in: work.id)?.isRead == true })
    }

    @Test func undeleteMovesBackToTheInbox() async throws {
        let store = await makeStore()
        let first = try #require(store.state(for: work.id).messages.first)
        await store.delete(message: first.id, in: work.id)
        store.mailFolder = .deleted
        await store.loadFolder(.deleted, work.id)
        await store.moveToInbox([first.id], in: work.id)
        #expect(store.list(.deleted, for: work.id)?.messages.isEmpty == true)
        #expect(store.state(for: work.id).messages.contains { $0.id == first.id })
    }

    @Test func junkAndNotJunk() async throws {
        let store = await makeStore()
        let letter = try #require(store.state(for: work.id).messages.first { $0.senderName == "Newsletter" })
        await store.markJunk([letter.id], in: work.id, block: true)
        #expect(store.listActions.toast?.text == "Blocked news@example.net.")
        await store.loadFolder(.junk, work.id)
        #expect(store.list(.junk, for: work.id)?.messages.first?.id == letter.id)
        store.mailFolder = .junk
        await store.notJunk([letter.id], in: work.id)
        #expect(store.state(for: work.id).messages.contains { $0.id == letter.id })
        #expect(store.list(.junk, for: work.id)?.messages.contains { $0.id == letter.id } == false)
    }

    @Test func emptyingAsksWithTheCountFirst() async throws {
        let store = await makeStore()
        let ids = store.state(for: work.id).messages.prefix(2).map(\.id)
        await store.delete(Array(ids), in: work.id)
        await store.askToEmpty(.deleted, in: work.id)
        #expect(store.listActions.pending == .empty(.deleted, accountID: work.id, count: 2))
        await store.empty(.deleted, in: work.id)
        #expect(store.listActions.pending == nil)
        #expect(store.list(.deleted, for: work.id)?.messages.isEmpty == true)
        // Junk empties into Deleted Items.
        await store.askToEmpty(.junk, in: work.id)
        guard case .empty(.junk, _, let count)? = store.listActions.pending else { Issue.record("no question"); return }
        #expect(count == MockFixtures.workJunk.count)
        await store.empty(.junk, in: work.id)
        await store.loadFolder(.deleted, work.id)
        #expect(store.list(.deleted, for: work.id)?.messages.count == count)
    }

    @Test func foldersOpenMoveAndFavorite() async throws {
        let store = await makeStore()
        await store.loadFolderTree(for: work.id)
        let folders = try #require(store.listActions.folderTrees[work.id]).folders
        let atlas = try #require(folders.first { $0.name == "Atlas" })
        store.open(atlas)
        #expect(store.mailFolder == .custom(atlas))
        await store.loadFolder()
        #expect(store.list(.custom(atlas), for: work.id)?.messages.count == 2)
        // Move a message from the Inbox into it, then undo.
        store.mailFolder = .inbox
        let first = try #require(store.state(for: work.id).messages.first)
        await store.move([first.id], in: work.id, to: atlas)
        #expect(store.listActions.toast?.text == "Moved to Atlas.")
        await store.loadFolder(.custom(atlas), work.id)
        #expect(store.list(.custom(atlas), for: work.id)?.messages.first?.id == first.id)
        store.listActions.toggleFavorite(atlas, accountID: work.id, persist: false)
        #expect(store.listActions.isFavorite(atlas, accountID: work.id))
    }

    @Test func unsubscribeAsksThenOpensOrSends() async throws {
        let transport = MockTransport(mode: .inbox)
        let store = await makeStore(transport)
        let letter = try #require(store.state(for: work.id).messages.first { $0.senderName == "Newsletter" })
        await store.askToUnsubscribe(message: letter.id, in: work.id)
        guard case .unsubscribe(.web(let url), "Newsletter", _)? = store.listActions.pending else {
            Issue.record("expected the web link"); return
        }
        #expect(url.host == "news.example.net")
        store.listActions.pending = nil
        // A message with no header says so, and asks nothing.
        let other = try #require(store.state(for: work.id).messages.first { $0.senderName != "Newsletter" })
        await store.askToUnsubscribe(message: other.id, in: work.id)
        #expect(store.listActions.pending == nil && store.actionError != nil)
        // A mailto-only list is sent through the app's own send path, nowhere real.
        store.listActions.pending = .unsubscribe(.mail(try #require(UnsubscribeMail("mailto:stop@example.net?subject=Remove%20me"))),
                                                 sender: "Prize Desk", accountID: work.id)
        await store.confirmUnsubscribe()
        let sent = try #require(transport.sentRequests.last)
        #expect(sent.contains("stop@example.net") && sent.contains("Remove me"))
    }
}
