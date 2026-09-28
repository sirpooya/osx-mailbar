import Foundation
import Testing
@testable import Mailbar

@Suite struct MeetingRequestShapeTests {
    @Test func theItemClassSaysWhatAMeetingEmailIs() {
        #expect(MeetingMail(element: "Message", itemClass: "IPM.Schedule.Meeting.Request") == .request)
        #expect(MeetingMail(element: "MeetingCancellation", itemClass: "IPM.Schedule.Meeting.Canceled") == .cancellation)
        #expect(MeetingMail(element: "MeetingResponse", itemClass: "IPM.Schedule.Meeting.Resp.Pos") == .response("Accept"))
        #expect(MeetingMail(element: "MeetingResponse", itemClass: "IPM.Schedule.Meeting.Resp.Neg") == .response("Decline"))
        // Without a class, the element name decides; plain mail is none.
        #expect(MeetingMail(element: "MeetingResponse", itemClass: nil) == .response(nil))
        #expect(MeetingMail(element: "Message", itemClass: "IPM.Note") == nil)
    }

    @Test func theInboxAsksForTheItemClass() {
        #expect(SOAP.findInbox(limit: 50, modern: true).contains("item:ItemClass"))
    }

    @Test func aSilentAnswerIsSavedInDeletedItemsNeverDrafts() throws {
        let body = CalendarSOAP.answer(.accept, to: "m-1", changeKey: "ck", note: "", send: false)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        #expect(root.first("CreateItem")?.attributes["MessageDisposition"] == "SaveOnly")
        #expect(root.first("SavedItemFolderId")?.first("DistinguishedFolderId")?.attributes["Id"] == "deleteditems")
        #expect(CalendarSOAP.answer(.accept, to: "m-1", changeKey: "ck", note: "").contains("SendAndSaveCopy"))
    }

    @Test func aProposedTimeFollowsTheReference() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let proposal = DateInterval(start: start, duration: 1800)
        let body = CalendarSOAP.answer(.decline, to: "m-1", changeKey: "ck", note: "Clash", proposal: proposal)
        let root = try XMLTree.parse(SOAP.envelope(.exchange2013, body: body))
        let answer = try #require(root.first("DeclineItem"))
        #expect(answer.children.map(\.name) == ["Body", "ReferenceItemId", "ProposedStart", "ProposedEnd"])
        #expect(answer.child("ProposedStart")?.trimmedText == SOAP.isoDate(start))
        // Accepting proposes nothing.
        #expect(!CalendarSOAP.answer(.accept, to: "m-1", changeKey: "ck", note: "", proposal: proposal).contains("Proposed"))
    }

    @Test func removingACancelledMeetingNamesTheCancellation() throws {
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: CalendarSOAP.removeCancelled("m-9", changeKey: "ck")))
        #expect(root.first("RemoveItem")?.child("ReferenceItemId")?.attributes["Id"] == "m-9")
    }

    @Test func freeBusyLeavesTheMeetingItselfOut() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let meeting = CalendarEvent(id: "m", changeKey: "", subject: "Review", start: start, end: start.addingTimeInterval(1800),
                                    isAllDay: false, location: "", organizer: "", isRecurring: false, isMeeting: true,
                                    isCancelled: false, myResponse: "NoResponseReceived", showAs: "Tentative", isPrivate: false)
        let hold = BusyBlock(start: meeting.start, end: meeting.end, type: "Tentative")
        let clash = BusyBlock(start: start.addingTimeInterval(900), end: start.addingTimeInterval(3600), type: "Busy")
        let states = MeetingCard.states(["a@x": [hold], "b@x": [hold, clash], "c@x": nil], during: meeting)
        #expect(states == ["a@x": "Free", "b@x": "Busy", "c@x": "NoData"])
    }

    @Test func aBlankInvitationHasNoText() {
        #expect(MeetingCard.isBlank("<html><head><style>p{}</style></head><body><p>&nbsp;</p></body></html>"))
        #expect(!MeetingCard.isBlank("<p>Agenda attached</p>"))
        #expect(!MeetingCard.isBlank(#"<img src="cid:x">"#))
    }
}

@MainActor
@Suite struct MeetingCardTests {
    private func makeStore() async -> MailStore {
        Keys.registerDefaults()
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0)))
        await store.refresh()
        return store
    }

    private func card(_ store: MailStore, where match: (MailMessage) -> Bool) async throws -> MeetingCard {
        let work = MockMode.accounts[0].id
        let found = store.state(for: work).messages.first(where: match)
        let mail = try #require(found)
        let card = MeetingCard(kind: try #require(mail.meeting), mailID: mail.id, accountID: work, store: store)
        await card.load(senderAddress: mail.senderAddress)
        return card
    }

    @Test func anInvitationShowsItsMeetingDayAndAttendees() async throws {
        let store = await makeStore()
        let card = try await card(store) { $0.isMeetingRequest }
        let details = try #require(card.details)
        #expect(details.calendarItemID == "ev-next-planning")
        #expect(details.event.subject == "Quarterly planning")
        #expect(card.myAnswer == nil)
        #expect(card.joinLink(bodyHTML: "")?.host == "teams.microsoft.com")
        // The day's other events are there, the meeting itself drawn once.
        let (others, meeting) = card.previewEvents()
        #expect(meeting?.id == "ev-next-planning")
        #expect(!others.isEmpty)
        #expect(!others.contains { $0.id == "ev-next-planning" })
        #expect(card.attendees(optional: false).map(\.display).contains("Sara Rahimi"))
    }

    @Test func answeringWithoutSendingStillAnswers() async throws {
        let store = await makeStore()
        let card = try await card(store) { $0.isMeetingRequest }
        await card.answer(.accept, send: false)
        #expect(card.problem == nil)
        #expect(card.myAnswer == .accept)
        #expect(card.answeredSilently)
        #expect(!card.showsAnswerButtons)
    }

    @Test func aProposalMovesInQuarterHoursWithinTheDay() async throws {
        let store = await makeStore()
        let card = try await card(store) { $0.isMeetingRequest }
        let meeting = try #require(card.details?.event)
        card.startProposing(as: .decline)
        #expect(card.proposal?.start == meeting.start)
        card.moveProposal(to: meeting.start.addingTimeInterval(37 * 60))
        #expect(card.proposal?.start == meeting.start.addingTimeInterval(30 * 60))
        #expect(card.proposal?.duration == meeting.end.timeIntervalSince(meeting.start))
        // Never past the day's end.
        card.moveProposal(to: card.day.addingTimeInterval(30 * 3600))
        #expect(card.proposal?.end == card.day.addingTimeInterval(24 * 3600))
        await card.sendProposal()
        #expect(card.myAnswer == .decline)
        #expect(card.proposal == nil)
        #expect(card.proposed != nil)
    }

    @Test func aCancellationCanRemoveTheEvent() async throws {
        let store = await makeStore()
        let card = try await card(store) { $0.meeting == .cancellation }
        #expect(card.details?.calendarItemID == "ev-sat-update")
        await card.removeFromCalendar()
        #expect(card.removedFromCalendar)
        // Read again, the email no longer points at an event.
        let again = try await self.card(store) { $0.meeting == .cancellation }
        #expect(again.details == nil || again.details?.calendarItemID == nil)
    }

    @Test func anAnswerCarriesTheTimeProposed() async throws {
        let store = await makeStore()
        let card = try await card(store) { $0.meeting == .response("Tentative") }
        let details = try #require(card.details)
        #expect(details.proposal?.start == details.event.start.addingTimeInterval(3600))
    }
}
