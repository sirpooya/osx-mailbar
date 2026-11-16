import AppKit
import Foundation
import Testing
@testable import Mailbar

/// M23 to M25: compose fields and options, sending, rich compose. Requests are checked for
/// schema order; flows run against `MockTransport`, where nothing is delivered.
@Suite struct ComposeRequestShapeTests {
    @Test func newMessageCarriesBccOptionsAndFromInSchemaOrder() throws {
        var fields = ComposeSOAP.Fields(subject: "Hi", html: "<div>x</div>", to: ["a@x.com"], cc: ["b@x.com"],
                                        bcc: ["c@x.com"], from: "alias@x.com")
        fields.options = MessageOptions(importance: .high, sensitivity: .confidential, readReceipt: true, deliveryReceipt: true)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: ComposeSOAP.message(fields, .send)))
        let message = try #require(root.first("Message"))
        #expect(message.children.map(\.name) == ["Subject", "Sensitivity", "Body", "Importance", "ToRecipients",
                                                 "CcRecipients", "BccRecipients", "IsReadReceiptRequested",
                                                 "IsDeliveryReceiptRequested", "From"])
        #expect(message.child("Sensitivity")?.text == "Confidential")
        #expect(message.child("Importance")?.text == "High")
        #expect(root.first("CreateItem")?.attributes["MessageDisposition"] == "SendAndSaveCopy")
    }

    @Test func aDraftIsSavedOnlyInDrafts() throws {
        let body = ComposeSOAP.message(ComposeSOAP.Fields(subject: "Later"), .draft)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        #expect(root.first("CreateItem")?.attributes["MessageDisposition"] == "SaveOnly")
        #expect(root.first("SavedItemFolderId")?.first("DistinguishedFolderId")?.attributes["Id"] == "drafts")
    }

    @Test func aResponseObjectCarriesBccAndReceiptsButNoImportance() throws {
        var fields = ComposeSOAP.Fields(to: ["a@x.com"], bcc: ["me@x.com"])
        fields.options.readReceipt = true
        let body = ComposeSOAP.response(.replyAll, to: "id-1", changeKey: "ck", fields, newBody: "<div>hi</div>", .send)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let reply = try #require(root.first("ReplyAllToItem"))
        #expect(reply.children.map(\.name) == ["ToRecipients", "BccRecipients", "IsReadReceiptRequested",
                                               "ReferenceItemId", "NewBodyContent"])
    }

    @Test func updateRewritesTheDraftAndClearsEmptyLists() throws {
        let body = ComposeSOAP.update(draftID: "d1", ComposeSOAP.Fields(subject: "S", html: "<b>x</b>", to: ["a@x.com"]),
                                      setsSubject: true)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let uris = root.all("FieldURI").compactMap { $0.attributes["FieldURI"] }
        #expect(uris.contains("item:Subject"))
        #expect(uris.contains("message:CcRecipients"))
        #expect(root.all("DeleteItemField").count == 2)
        #expect(root.first("UpdateItem")?.attributes["MessageDisposition"] == "SaveOnly")
    }

    @Test func sendItemKeepsACopyInSentItems() throws {
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: ComposeSOAP.sendItem("d1")))
        #expect(root.first("SendItem")?.attributes["SaveItemToFolder"] == "true")
        #expect(root.first("SavedItemFolderId")?.first("DistinguishedFolderId")?.attributes["Id"] == "sentitems")
    }

    @Test func filesAndTheForwardedMessageAreAttachments() throws {
        let file = OutgoingFile(name: "a&b.txt", contentType: "text/plain", data: Data("hi".utf8))
        let files = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: ComposeSOAP.attach([file], to: "d1")))
        #expect(files.first("FileAttachment")?.child("Name")?.text == "a&b.txt")
        #expect(files.first("Content")?.text == "aGk=")
        let item = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: ComposeSOAP.attachMessage(mime: "QQ==", name: "Hi", to: "d1")))
        #expect(item.first("ItemAttachment")?.first("MimeContent")?.text == "QQ==")
    }

    @Test func mailTipsAskForAutomaticRepliesAndGroupSizes() throws {
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2,
                                                   body: ComposeSOAP.mailTips(sender: "me@x.com", recipients: ["a@x.com"])))
        #expect(root.first("MailTipsRequested")?.text.contains("OutOfOfficeMessage") == true)
        #expect(root.first("Recipients")?.all("EmailAddress").map(\.text) == ["a@x.com"])
    }
}

@Suite struct ComposeModelTests {
    @Test func mailtoLinksFillTheMessage() throws {
        let link = try #require(MailtoLink(URL(string: "mailto:a@x.com,b@x.com?cc=c@x.com&subject=Hello%20there&body=Line%201%0ALine%202&bcc=d@x.com")!))
        #expect(link.to == ["a@x.com", "b@x.com"])
        #expect(link.cc == ["c@x.com"])
        #expect(link.bcc == ["d@x.com"])
        #expect(link.subject == "Hello there")
        #expect(link.body == "Line 1\nLine 2")
        #expect(MailtoLink(URL(string: "https://example.com")!) == nil)
    }

    @Test func savedBodiesSplitBackIntoMineAndTheQuote() throws {
        var draft = Draft(kind: .reply, accountID: UUID(), originalID: "o", originalSubject: "S", to: "", cc: "",
                          subject: "", body: "Thanks")
        draft.baseHTML = "<html><body><hr><div>quoted <div>nested</div></div></body></html>"
        let html = draft.outgoingHTML
        #expect(html.hasPrefix(#"<html><body><div class="mailbar-compose">"#))
        let parts = try #require(ComposeHTML.split(html))
        #expect(parts.mine.contains("Thanks"))
        #expect(!parts.mine.contains("quoted"))
        #expect(parts.base == "<html><body><hr><div>quoted <div>nested</div></div></body></html>")
    }

    @Test func aSelectionIsQuotedAlone() {
        var draft = Draft(kind: .reply, accountID: UUID(), originalID: "o", originalSubject: "S", to: "", cc: "",
                          subject: "", body: "Yes")
        draft.quotedSelection = "سلام\nThe line"
        #expect(draft.outgoingHTML.contains("<blockquote"))
        #expect(draft.outgoingHTML.contains(#"<div dir="rtl" style="text-align:right">سلام</div>"#))
        #expect(draft.title == "Reply to Selection")
    }

    @Test func sendProblemsCoverBccNamesAndSize() {
        var draft = Draft(kind: .new, accountID: UUID(), originalID: nil, originalSubject: "", to: "", cc: "",
                          subject: "Hi", body: "x")
        draft.bcc = "a@x.com"
        #expect(draft.sendProblem == nil)
        draft.to = "sara"
        #expect(draft.sendProblem?.contains("Check Names") == true)
        draft.to = ""
        draft.attachments = [OutgoingFile(name: "big", contentType: "application/octet-stream", data: Data(count: OutgoingFile.maxTotal + 1))]
        #expect(draft.sendProblem == "The files come to more than 25 MB.")
    }

    @Test func mailTipLinesSayOutsideAwayAndLarge() {
        let tips = ["sara@x.com": MailTip(address: "sara@x.com", outOfOffice: "Away until Monday."),
                    "all@x.com": MailTip(address: "all@x.com", totalMembers: 300, externalMembers: 2)]
        let lines = MailTipLines.lines(for: ["sara@x.com", "all@x.com", "pat@y.org"], tips: tips, myAddress: "me@x.com")
        #expect(lines.contains("2 recipients are outside your organization."))
        #expect(lines.contains("Automatic reply from sara@x.com: Away until Monday."))
        #expect(lines.contains("all@x.com goes to 300 people."))
    }

    @Test func automaticRepliesAreReadAsPlainText() {
        #expect(ComposeResponse.plainText("<p>Away&nbsp;until <b>Monday</b>.</p>") == "Away until Monday .")
    }

    @Test func checkNamesReplacesAnEntryInPlace() {
        #expect(Recipients.replacing("sara", with: "sara.rahimi@example.com", in: "a@x.com, sara, b@x.com")
                == "a@x.com, sara.rahimi@example.com, b@x.com, ")
    }
}

@MainActor
@Suite struct RichTextTests {
    private let base = NSFont.systemFont(ofSize: 13)

    @Test func formattingBecomesTagsAndListsBecomeLists() {
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let text = NSMutableAttributedString(string: "Hi ", attributes: [.font: base])
        text.append(NSAttributedString(string: "all", attributes: [.font: bold]))
        text.append(NSAttributedString(string: "\n\u{2022} one\n\u{2022} two\n1. first\nسلام ", attributes: [.font: base]))
        text.append(NSAttributedString(string: "link", attributes: [.font: base, .link: URL(string: "https://example.com/?a=1&b=2")!]))
        #expect(RichHTML.hasFormatting(text))
        let html = RichHTML.html(from: text)
        #expect(html.contains("<div>Hi <b>all</b></div>"))
        #expect(html.contains("<ul><li>one</li><li>two</li></ul><ol><li>first</li></ol>"))
        #expect(html.contains(#"<div dir="rtl" style="text-align:right">سلام <a href="https://example.com/?a=1&amp;b=2">link</a></div>"#))
    }

    @Test func plainTextNeedsNoFormatting() {
        #expect(!RichHTML.hasFormatting(NSAttributedString(string: "Just text\nmore", attributes: [.font: base])))
    }

    @Test func htmlComesBackWithItsFormatting() {
        let text = RichHTML.attributed(fromHTML: "<div>Hello <b>you</b></div><ul><li>one</li><li>two</li></ul>")
        #expect(text.string.contains("Hello you"))
        #expect(text.string.contains("\u{2022} one"))
        #expect(RichHTML.hasFormatting(text))
    }
}

@MainActor
@Suite(.serialized) struct ComposeFlowTests {
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

    @Test func aSavedDraftIsSentFromDraftsWithItsFiles() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        store.startNewMessage()
        store.draft?.to = "a@example.net"
        store.draft?.bcc = "b@example.net"
        store.draft?.subject = "Report"
        store.draft?.body = "Attached."
        await store.saveDraftToServer()
        #expect(store.draft?.serverID?.hasPrefix("draft-") == true)
        #expect(transport.compose.draftCount == 1)
        if case .saved = store.compose.saveStatus {} else { Issue.record("not saved") }

        store.draft?.attachments = [OutgoingFile(name: "r.pdf", contentType: "application/pdf", data: Data("pdf".utf8))]
        await store.sendDraft()
        #expect(store.draft == nil)
        #expect(transport.compose.draftCount == 0)
        let sent = try #require(transport.compose.sentItems.last)
        #expect(sent.bcc == ["b@example.net"])
        #expect(sent.files == ["r.pdf"])
        #expect(transport.sentRequests.last?.contains("<m:SendItem") == true)
    }

    @Test func aReplyDraftKeepsTheServersQuoteUnderTheText() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let original = try #require(store.state(for: work.id).messages.first)
        store.startResponse(.reply, to: try await body(of: store, original), in: work.id)
        store.draft?.body = "Sounds good."
        await store.saveDraftToServer()
        #expect(store.draft?.baseHTML?.contains("quoted by the server") == true)
        let id = try #require(store.draft?.serverID)

        // Reopened from Drafts, only the user's part is in the editor; the quote stays below.
        store.discardDraft()
        await store.openDraft(id, in: work.id)
        #expect(store.draft?.body == "Sounds good.")
        #expect(store.draft?.baseHTML?.contains("quoted by the server") == true)
        #expect(store.draft?.serverID == id)
    }

    @Test func discardMovesTheServerCopyToDeletedItems() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        store.startNewMessage()
        store.draft?.body = "never mind"
        await store.saveDraftToServer()
        store.discardDraftEverywhere()
        try await Task.sleep(for: .milliseconds(600))
        #expect(transport.compose.draftCount == 0)
        #expect(transport.sentRequests.last?.contains(#"DeleteType="MoveToDeletedItems""#) == true)
    }

    @Test func undoSendHoldsTheMessageAndBringsItBack() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let before = transport.sentRequests.count
        store.startNewMessage()
        store.draft?.to = "a@example.net"
        store.draft?.body = "oops"
        UserDefaults.standard.set(5, forKey: ComposeSettings.undoSendSecondsKey)
        defer { UserDefaults.standard.removeObject(forKey: ComposeSettings.undoSendSecondsKey) }
        store.sendWithUndo()
        #expect(store.draft == nil)
        #expect(store.compose.pending != nil)
        store.undoSend()
        #expect(store.draft?.body == "oops")
        #expect(store.isComposing)
        try await Task.sleep(for: .milliseconds(300))
        #expect(transport.sentRequests.count == before)

        // Send Now skips the wait; the mail goes.
        store.sendWithUndo()
        store.sendHeldNow()
        for _ in 0..<20 where store.compose.pending != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(store.compose.pending == nil)
        #expect(store.sentNotice == "Sent.")
        #expect(transport.sentRequests.last?.contains("<t:Subject></t:Subject>") == true)
    }

    @Test func importanceOnAReplyGoesThroughADraft() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let original = try #require(store.state(for: work.id).messages.first)
        store.startResponse(.reply, to: try await body(of: store, original), in: work.id)
        store.draft?.body = "Urgent"
        store.draft?.options.importance = .high
        await store.sendDraft()
        #expect(transport.compose.sentItems.last?.importance == "High")
        #expect(store.message(original.id, in: work.id)?.lastVerb == .replied)
    }

    @Test func replyToSelectionIsANewMessageInTheThread() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let original = try #require(store.state(for: work.id).messages.first)
        store.startResponse(.reply, to: try await body(of: store, original), in: work.id, selection: "Only this line")
        store.draft?.body = "Agreed."
        await store.sendDraft()
        let request = try #require(transport.sentRequests.last { $0.contains("<m:CreateItem") })
        #expect(request.contains("<t:InReplyTo>&lt;original-1@example.net&gt;</t:InReplyTo>"))
        #expect(request.contains("Only this line"))
        #expect(!request.contains("<t:ReplyToItem>"))
    }

    @Test func forwardAsAttachmentAttachesTheOriginalsMime() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let original = try #require(store.state(for: work.id).messages.first)
        store.startForward(.asAttachment, of: try await body(of: store, original), in: work.id)
        store.draft?.to = "someone@example.net"
        await store.sendDraft()
        #expect(transport.sentRequests.contains { $0.contains("<t:ItemAttachment>") && $0.contains("<t:MimeContent") })
        #expect(transport.sentRequests.contains { $0.contains("<m:SendItem") })
        #expect(transport.compose.sentItems.last?.files == ["Hi"] || transport.compose.sentItems.count == 1)
        #expect(store.message(original.id, in: work.id)?.lastVerb == .forwarded)
    }

    @Test func checkNamesResolvesOneMatchAndMarksTheRest() async throws {
        let store = await makeStore(MockTransport(mode: .inbox, newMailAfter: 0))
        store.startNewMessage()
        store.draft?.to = "narges, karimi, nobody-here, "
        await store.checkNames()
        let to = Recipients.parse(store.draft?.to ?? "")
        #expect(to.contains("narges@example.com"))
        #expect((store.compose.unresolved["karimi"]?.count ?? 0) >= 2)
        #expect(store.compose.unresolved["nobody-here"] == [])
    }

    @Test func mailTipsComeBackForTypedRecipients() async throws {
        let store = await makeStore(MockTransport(mode: .inbox, newMailAfter: 0))
        store.startNewMessage()
        store.draft?.to = "sara.rahimi@example.com, designteam@example.com, someone@example.net"
        await store.refreshMailTips()
        let lines = store.mailTipLines
        #expect(lines.contains { $0.hasPrefix("Automatic reply from sara.rahimi@example.com") })
        #expect(lines.contains("designteam@example.com goes to 42 people."))
        #expect(lines.contains("someone@example.net is outside your organization."))
    }

    @Test func templatesAskBeforeTheFolderIsMadeThenSave() async throws {
        let transport = MockTransport(mode: .inbox, newMailAfter: 0)
        let store = await makeStore(transport)
        let team = MockMode.accounts[1]
        store.selectedAccountID = team.id
        store.startNewMessage()
        store.draft?.subject = "Standup"
        store.draft?.body = "Yesterday, today, blockers."
        await store.saveAsTemplate()
        #expect(store.compose.asksToCreateTemplates)
        await store.saveAsTemplate(create: true)
        #expect(!store.compose.asksToCreateTemplates)
        #expect(store.compose.notice == "Saved as a template.")

        // The work account has one ready; New from Template fills the message from it.
        store.discardDraft()
        store.selectedAccountID = work.id
        store.startNewMessage()
        await store.loadTemplates()
        let template = try #require(store.compose.templates.first)
        await store.applyTemplate(template.id)
        #expect(store.draft?.subject == "Weekly status")
        #expect(store.draft?.body.contains("\u{2022} Done:") == true)
        let to = Recipients.parse(store.draft?.to ?? "")
        #expect(to == ["designteam@example.com"])
    }

    @Test func signatureAndAlwaysBccMeAreAppliedOnce() async throws {
        let store = await makeStore(MockTransport(mode: .inbox, newMailAfter: 0))
        let signature = Signature(name: "Work", text: "Sample User\nExample Co")
        let defaults = UserDefaults.standard
        ComposeSettings.setSignatures([signature])
        ComposeSettings.setSignatureChoice(ComposeSettings.newSignatureKey, account: work.id, signature: signature.id)
        defaults.set(true, forKey: ComposeSettings.alwaysBccMeKey)
        defer {
            defaults.removeObject(forKey: ComposeSettings.signaturesKey)
            defaults.removeObject(forKey: ComposeSettings.newSignatureKey)
            defaults.removeObject(forKey: ComposeSettings.alwaysBccMeKey)
        }
        store.startNewMessage()
        store.prepareDraft()
        store.prepareDraft()
        #expect(store.draft?.body == "\n\nSample User\nExample Co")
        let bcc = Recipients.parse(store.draft?.bcc ?? "")
        #expect(bcc == [work.email])
    }

    @Test func mailtoOpensAFilledComposer() async throws {
        let store = await makeStore(MockTransport(mode: .inbox, newMailAfter: 0))
        store.startMailto(try #require(MailtoLink(URL(string: "mailto:a@example.net?subject=Hi&body=Hello")!)))
        #expect(store.isComposing)
        #expect(store.draft?.subject == "Hi")
        #expect(store.draft?.body == "Hello")
    }
}
