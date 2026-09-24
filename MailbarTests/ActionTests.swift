import Foundation
import Testing
@testable import Mailbar

/// M4 and M5 end to end against the stateful mock server: the same transport `MAILBAR_MOCK`
/// runs, so these exercise the real SOAP, the real parsing and the store's optimistic updates.
@MainActor
@Suite struct ActionTests {
    private let work = MockMode.accounts[0]
    private let team = MockMode.accounts[1]

    private func makeStore(_ transport: any EWSTransport = MockTransport(mode: .inbox)) async -> MailStore {
        let accounts = AccountStore(inMemory: MockMode.accounts, passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: transport))
        await store.refresh()
        return store
    }

    private func first(_ store: MailStore, in account: Account) throws -> MailMessage {
        try #require(store.state(for: account.id).messages.first)
    }

    @Test func markReadDropsTheCountAndSurvivesTheNextPoll() async throws {
        let store = await makeStore()
        let message = try first(store, in: work)
        #expect(!message.isRead)
        let before = store.unreadCount(for: work.id)

        await store.setRead(true, message: message.id, in: work.id)
        #expect(store.message(message.id, in: work.id)?.isRead == true)
        #expect(store.unreadCount(for: work.id) == before - 1)

        await store.refresh()
        #expect(store.message(message.id, in: work.id)?.isRead == true)
        #expect(store.unreadCount(for: work.id) == before - 1)
        #expect(store.actionError == nil)
    }

    @Test func flagAndClearFlag() async throws {
        let store = await makeStore()
        let message = try first(store, in: work)
        #expect(!message.isFlagged)

        await store.setFlag(true, message: message.id, in: work.id)
        await store.refresh()
        #expect(store.message(message.id, in: work.id)?.isFlagged == true)

        await store.setFlag(false, message: message.id, in: work.id)
        await store.refresh()
        #expect(store.message(message.id, in: work.id)?.isFlagged == false)
    }

    @Test func deleteRemovesTheRowAndClosesTheReader() async throws {
        let store = await makeStore()
        let message = try first(store, in: work)
        let count = store.state(for: work.id).messages.count
        store.openMessage = .init(accountID: work.id, messageID: message.id)

        await store.delete(message: message.id, in: work.id)

        #expect(store.message(message.id, in: work.id) == nil)
        #expect(store.state(for: work.id).messages.count == count - 1)
        #expect(store.openMessage == nil)
        await store.refresh()
        #expect(store.message(message.id, in: work.id) == nil)
    }

    @Test func archiveMovesWhenTheFolderExists() async throws {
        let store = await makeStore()
        let message = try first(store, in: work)

        await store.archive(message: message.id, in: work.id)

        #expect(store.pendingArchive == nil)
        #expect(store.message(message.id, in: work.id) == nil)
    }

    /// The team mailbox starts with no Archive folder: nothing moves and nothing is created until
    /// the user says yes.
    @Test func archiveAsksBeforeCreatingTheFolder() async throws {
        let store = await makeStore()
        let message = try first(store, in: team)

        await store.archive(message: message.id, in: team.id)
        #expect(store.pendingArchive == .init(accountID: team.id, messageID: message.id))
        #expect(store.message(message.id, in: team.id) != nil)

        await store.createArchiveFolderAndArchive()
        #expect(store.pendingArchive == nil)
        #expect(store.message(message.id, in: team.id) == nil)
    }

    @Test func aRefusedActionPutsTheRowBack() async throws {
        let transport = RefusingTransport()
        let store = await makeStore(transport)
        let message = try first(store, in: work)
        let unread = store.unreadCount(for: work.id)
        transport.refuseWrites = true

        await store.setRead(true, message: message.id, in: work.id)
        #expect(store.message(message.id, in: work.id)?.isRead == false)
        #expect(store.unreadCount(for: work.id) == unread)
        #expect(store.actionError != nil)

        store.actionError = nil
        await store.delete(message: message.id, in: work.id)
        #expect(store.state(for: work.id).messages.first?.id == message.id)
        #expect(store.actionError != nil)
    }

    @Test func openingAMessageReadsItsBodyAndInlineImage() async throws {
        let store = await makeStore()
        let message = try first(store, in: work)
        let (url, credential) = try #require(store.connection(for: work.id))

        let body = try await store.client.message(id: message.id, at: url, credential: credential)
        #expect(body.subject == message.subject)
        #expect(body.from?.name == message.senderName)
        #expect(body.to.map(\.address) == ["sample.user@example.com"])
        #expect(body.inlineImages.map(\.contentID) == ["logo@mock"])
        #expect(body.files.isEmpty)

        let images = try await store.client.inlineImages(body.inlineImages, at: url, credential: credential)
        let png = try #require(images["att-logo"])
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}

/// The mock server, except that every write fails once `refuseWrites` is set.
private final class RefusingTransport: EWSTransport, @unchecked Sendable {
    private let inner = MockTransport(mode: .inbox)
    var refuseWrites = false

    func send(_ body: Data, to url: URL, credential: EWSCredential) async throws -> (Data, Int) {
        let request = String(decoding: body, as: UTF8.self)
        let isWrite = ["<m:UpdateItem", "<m:DeleteItem", "<m:MoveItem"].contains { request.contains($0) }
        if refuseWrites && isWrite {
            return (Data(MockFixtures.fault.utf8), 500)
        }
        return try await inner.send(body, to: url, credential: credential)
    }
}

@Suite struct ReaderHTMLTests {
    @Test func policyBlocksRemoteImagesUntilAllowed() {
        let blocked = ReaderHTML.document(body: "<p>x</p>", images: [:], allowRemoteImages: false)
        #expect(blocked.contains("img-src data:;"))
        #expect(blocked.contains("default-src 'none'"))
        #expect(blocked.hasPrefix(#"<meta http-equiv="Content-Security-Policy""#))

        let allowed = ReaderHTML.document(body: "<p>x</p>", images: [:], allowRemoteImages: true)
        #expect(allowed.contains("img-src data: https: http:;"))
        #expect(allowed.contains("default-src 'none'"))
    }

    @Test func cidReferencesBecomeDataURIs() {
        let html = ReaderHTML.inlining(["<logo@mock>": (type: "image/png", data: Data([1, 2, 3]))],
                                       into: #"<img src="cid:logo@mock">"#)
        #expect(html == #"<img src="data:image/png;base64,AQID">"#)
    }

    @Test func remoteImageDetection() {
        #expect(ReaderHTML.hasRemoteImages(#"<img src="https://x.example/p.gif">"#))
        #expect(ReaderHTML.hasRemoteImages(#"<td background='http://x.example/bg.png'>"#))
        #expect(ReaderHTML.hasRemoteImages(#"<div style="background:url( https://x.example/a.png)">"#))
        #expect(!ReaderHTML.hasRemoteImages(#"<img src="cid:logo@mock"><a href="https://x.example">link</a>"#))
    }
}
