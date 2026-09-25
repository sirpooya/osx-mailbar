import Foundation
import Testing
@testable import Mailbar

@Suite struct EventRequestTests {
    private func draft(_ configure: (inout EventDraft) -> Void = { _ in }) -> EventDraft {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var draft = EventDraft(accountID: UUID(), start: start, end: start.addingTimeInterval(3600))
        draft.subject = "Review"
        configure(&draft)
        return draft
    }

    @Test func anAppointmentSendsNoInvitations() throws {
        let body = CalendarSOAP.createEvent(draft())
        #expect(body.contains(#"SendMeetingInvitations="SendToNone""#))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body, timeZone: "Iran Standard Time"))
        #expect(root.first("TimeZoneDefinition")?.attributes["Id"] == "Iran Standard Time")
        let item = try #require(root.first("CalendarItem"))
        // The schema's order: item fields first, then calendar ones.
        #expect(item.children.map(\.name) == ["Subject", "Sensitivity", "Body", "ReminderIsSet",
                                              "ReminderMinutesBeforeStart", "Start", "End", "IsAllDayEvent",
                                              "LegacyFreeBusyStatus", "Location"])
    }

    @Test func peopleAndRoomsMakeItAMeetingThatSendsInvitations() throws {
        let body = CalendarSOAP.createEvent(draft {
            $0.attendees = "a@example.com, b@example.com"
            $0.rooms = [Room(name: "Room Blue", address: "room.blue@example.com")]
        })
        #expect(body.contains(#"SendMeetingInvitations="SendToAllAndSaveCopy""#))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        #expect(root.first("RequiredAttendees")?.children.count == 2)
        #expect(root.first("Resources")?.first("EmailAddress")?.trimmedText == "room.blue@example.com")
        // No location typed: the room's name is the location, as OWA fills it.
        #expect(root.first("Location")?.trimmedText == "Room Blue")
    }

    @Test func anAllDayEventRunsMidnightToMidnight() {
        let d = draft { $0.isAllDay = true }
        let calendar = Calendar.current
        #expect(d.requestStart == calendar.startOfDay(for: d.start))
        #expect(d.requestEnd == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: d.start)))
    }

    @Test func aWeeklyRepeatNamesItsDay() throws {
        let body = CalendarSOAP.createEvent(draft { $0.repeatRule = .weekly })
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        #expect(root.first("WeeklyRecurrence")?.child("DaysOfWeek") != nil)
        #expect(root.first("NoEndRecurrence")?.child("StartDate") != nil)
    }

    @Test func deletingAMeetingSendsTheCancellationAndAnAppointmentDoesNot() {
        #expect(CalendarSOAP.deleteEvent(id: "x", cancelMeeting: true).contains(#"SendMeetingCancellations="SendToAllAndSaveCopy""#))
        #expect(CalendarSOAP.deleteEvent(id: "x", cancelMeeting: false).contains(#"SendMeetingCancellations="SendToNone""#))
    }

    @Test func anAnswerCarriesItsNoteBeforeTheReference() throws {
        let body = CalendarSOAP.answer(.tentative, to: "ev-1", changeKey: "ck", note: "Might be late")
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let answer = try #require(root.first("TentativelyAcceptItem"))
        #expect(answer.children.map(\.name) == ["Body", "ReferenceItemId"])
        #expect(CalendarSOAP.answer(.accept, to: "ev-1", changeKey: "ck", note: " ").contains("<t:Body") == false)
    }

    @Test func endBeforeStartIsRefused() {
        let d = draft { $0.end = $0.start.addingTimeInterval(-60) }
        #expect(d.problem != nil)
        #expect(draft { $0.attendees = "not an address" }.problem != nil)
    }
}

@MainActor
@Suite(.serialized) struct EventWriteTests {
    private func makeStore() async throws -> CalendarStore {
        UserDefaults.standard.removeObject(forKey: Keys.calendarMode)
        Keys.registerDefaults()
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let mail = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0)))
        await mail.refresh()
        let store = CalendarStore(mail: mail)
        store.mode = .week
        await store.refresh()
        for _ in 0..<50 where store.phase != .loaded { try await Task.sleep(nanoseconds: 100_000_000) }
        return store
    }

    @Test func aNewEventAppearsInTheWeek() async throws {
        let store = try await makeStore()
        store.startNewEvent(at: Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date()))
        store.editor?.subject = "Focus time"
        await store.saveEditor()
        #expect(store.editor == nil)
        #expect(store.notice == "Saved.")
        let created = store.events.contains { $0.subject == "Focus time" }
        #expect(created)
    }

    @Test func editingAndDeletingAnOwnEvent() async throws {
        let store = try await makeStore()
        let own = try #require(store.events.first { $0.subject == "ds demo alignment" })
        await store.select(own)
        #expect(store.canEditSelected)
        store.startEditing()
        #expect(store.editor?.attendees.contains("omid@example.org") == true)
        store.editor?.subject = "ds demo alignment (moved)"
        await store.saveEditor()
        let renamed = store.events.contains { $0.subject == "ds demo alignment (moved)" }
        #expect(renamed)

        let moved = try #require(store.events.first { $0.subject == "ds demo alignment (moved)" })
        await store.select(moved)
        await store.deleteSelected()
        let gone = !store.events.contains { $0.id == moved.id }
        #expect(gone)
        #expect(store.notice?.hasPrefix("Cancelled") == true)
    }

    @Test func anInvitationIsAnsweredNotEdited() async throws {
        let store = try await makeStore()
        let invite = try #require(store.events.first { $0.subject == "Design System Workflow Demo" })
        await store.select(invite)
        #expect(!store.canEditSelected)
        #expect(store.canAnswerSelected)
        await store.answerSelected(.accept, note: "See you there")
        let answered = store.events.first { $0.id == invite.id }
        #expect(answered?.myResponse == "Accept")
    }

    @Test func theInvitationEmailIsAMeetingRequestAndCanBeAnswered() async throws {
        let store = try await makeStore()
        let work = MockMode.accounts[0].id
        let email = try #require(store.mail.state(for: work).messages.first { $0.isMeetingRequest })
        try await store.mail.answerInvitation(.tentative, message: email.id, in: work, note: "")
        await store.refresh()
        let planning = store.events.first { $0.subject == "Quarterly planning" }
        #expect(planning?.myResponse == "Tentative")
    }

    @Test func peopleSuggestionsComeFromTheDirectoryToo() async throws {
        let store = try await makeStore()
        let found = await store.peopleSuggestions(for: "amir", excluding: "")
        let addresses = found.map(\.address)
        #expect(addresses.contains("amir.karimi@example.com"))
        #expect(addresses.contains("amirhossein.nadiri@example.com"))
        await store.loadRooms()
        #expect(store.rooms?.map(\.name) == ["Room Blue", "Room Green"])
    }
}
