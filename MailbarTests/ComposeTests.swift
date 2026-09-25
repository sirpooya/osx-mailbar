import Foundation
import Testing
@testable import Mailbar

@Suite struct RecipientTests {
    @Test func parsesCommasSemicolonsAndNamedAddresses() {
        #expect(Recipients.parse("a@x.com, Sara Rahimi <sara@x.com>; b@y.org,") == ["a@x.com", "sara@x.com", "b@y.org"])
    }

    @Test func validatesShape() {
        #expect(Recipients.isValid("some.one@example.com"))
        #expect(!Recipients.isValid("someone"))
        #expect(!Recipients.isValid("a@b"))
        #expect(!Recipients.isValid("a b@example.com"))
        #expect(!Recipients.isValid("a@.example.com"))
    }

    @Test func replyAllDropsMeAndDuplicates() {
        let result = Recipients.replyAll(from: "boss@x.com",
                                         to: ["Me@x.com", "team@x.com", "boss@x.com"],
                                         cc: ["team@x.com", "hr@x.com"],
                                         me: "me@x.com")
        #expect(result.to == ["boss@x.com", "team@x.com"])
        #expect(result.cc == ["hr@x.com"])
    }

    @Test func completingReplacesTheTokenBeingTyped() {
        #expect(Recipients.currentToken(in: "a@x.com, sa") == "sa")
        #expect(Recipients.completing("a@x.com, sa", with: "sara@x.com") == "a@x.com, sara@x.com, ")
        #expect(Recipients.completing("sa", with: "sara@x.com") == "sara@x.com, ")
    }
}

@Suite struct ComposeRequestTests {
    @Test func persianParagraphsAreSentRightToLeft() {
        let html = ComposeHTML.html(from: "سلام، ممنون\n\nThanks <3")
        #expect(html.contains(#"<div dir="rtl" style="text-align:right">سلام، ممنون</div>"#))
        #expect(html.contains("<div>Thanks &lt;3</div>"))
        #expect(html.contains("<div><br></div>"))
    }

    @Test func replyIsWellFormedInSchemaOrderAndSavesACopy() throws {
        let body = SOAP.respond(.reply, to: "id-1", changeKey: "ck-9", to: ["a@x.com"], cc: [], html: "<div>hi</div>")
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let create = try #require(root.first("CreateItem"))
        #expect(create.attributes["MessageDisposition"] == "SendAndSaveCopy")
        #expect(root.first("SavedItemFolderId")?.first("DistinguishedFolderId")?.attributes["Id"] == "sentitems")
        let reply = try #require(root.first("ReplyToItem"))
        #expect(reply.children.map(\.name) == ["ToRecipients", "ReferenceItemId", "NewBodyContent"])
        #expect(reply.child("ReferenceItemId")?.attributes["ChangeKey"] == "ck-9")
        #expect(reply.child("NewBodyContent")?.text == "<div>hi</div>")
    }

    @Test func newMessageCarriesSubjectBodyAndBothRecipientLists() throws {
        let body = SOAP.newMessage(subject: "Hi & bye", to: ["a@x.com"], cc: ["b@x.com"], html: "<div>x</div>")
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let message = try #require(root.first("Message"))
        #expect(message.children.map(\.name) == ["Subject", "Body", "ToRecipients", "CcRecipients"])
        #expect(message.child("Subject")?.text == "Hi & bye")
    }
}

@MainActor
@Suite struct SendingTests {
    private let work = MockMode.accounts[0]

    private func makeStore(_ transport: MockTransport) async -> MailStore {
        let accounts = AccountStore(inMemory: MockMode.accounts, passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: transport))
        store.selectedAccountID = work.id
        await store.refresh()
        return store
    }

    private func body(of store: MailStore, _ message: MailMessage) async throws -> MessageBody {
        let (url, credential) = try #require(store.connection(for: work.id))
        return try await store.client.message(id: message.id, at: url, credential: credential)
    }

    @Test func aPersianReplyReachesTheServerAsReplyToItem() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let original = try #require(store.state(for: work.id).messages.first)
        store.startResponse(.reply, to: try await body(of: store, original), in: work.id)

        #expect(store.isComposing)
        #expect(Recipients.parse(store.draft?.to ?? "") == [original.senderAddress])
        store.draft?.body = "سلام، ثبت کردم."
        await store.sendDraft()

        #expect(store.draft == nil)
        #expect(!store.isComposing)
        #expect(store.sentNotice == "Sent.")
        let request = try #require(transport.sentRequests.last)
        #expect(request.contains("<t:ReplyToItem>"))
        #expect(request.contains(#"ReferenceItemId Id="\#(original.id)" ChangeKey="ck""#))
        #expect(request.contains("dir=&quot;rtl&quot;"))
    }

    @Test func forwardAndNewMessageUseTheirOwnOperations() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let original = try #require(store.state(for: work.id).messages.first)

        store.startResponse(.forward, to: try await body(of: store, original), in: work.id)
        #expect(store.draft?.to == "")
        store.draft?.to = "someone@example.net"
        await store.sendDraft()
        #expect(transport.sentRequests.last?.contains("<t:ForwardItem>") == true)

        store.startNewMessage()
        store.draft?.to = "a@example.net, b@example.net"
        store.draft?.subject = "Lunch"
        store.draft?.body = "12:30?"
        await store.sendDraft()
        #expect(transport.sentRequests.last?.contains("<t:Subject>Lunch</t:Subject>") == true)
        #expect(store.sentNotice == "Sent to 2 people.")
    }

    @Test func aDraftWithTextIsNeverReplacedByANewOne() async throws {
        let store = await makeStore(MockTransport(mode: .inbox, newMailAfter: 0))
        store.startNewMessage()
        store.draft?.body = "half written"
        store.isComposing = false
        let original = try #require(store.state(for: work.id).messages.first)
        store.startResponse(.reply, to: try await body(of: store, original), in: work.id)
        #expect(store.draft?.kind == .new)
        #expect(store.draft?.body == "half written")
        #expect(store.isComposing)
    }

    @Test func aFailedSendKeepsTheText() async throws {
        let store = await makeStore(MockTransport(mode: .inbox, newMailAfter: 0))
        store.startNewMessage()
        store.draft?.to = "a@example.net"
        store.draft?.body = "keep me"
        // The password disappears between writing and sending.
        try store.accounts.passwords.deletePassword(for: work.id)
        await store.sendDraft()
        #expect(store.draft?.body == "keep me")
        #expect(store.draft?.error != nil)
    }

    @Test func suggestionsComeFromInboxSendersOnly() async {
        let store = await makeStore(MockTransport(mode: .inbox, newMailAfter: 0))
        let names = store.recipientSuggestions(for: "sara", excluding: "").map(\.address)
        #expect(names == ["sara.rahimi@example.com"])
        #expect(store.recipientSuggestions(for: "sara", excluding: "sara.rahimi@example.com").isEmpty)
    }
}
