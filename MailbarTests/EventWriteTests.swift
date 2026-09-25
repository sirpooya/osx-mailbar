import AppKit
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
                                              "ReminderMinutesBeforeStart", "ExtendedProperty", "Start", "End",
                                              "IsAllDayEvent", "LegacyFreeBusyStatus", "Location", "IsResponseRequested"])
    }

    @Test func peopleAndRoomsMakeItAMeetingThatSendsInvitations() throws {
        let body = CalendarSOAP.createEvent(draft {
            $0.people = [.init(name: "", address: "a@example.com"), .init(name: "", address: "b@example.com")]
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
        let body = CalendarSOAP.createEvent(draft { $0.repeatPattern = RepeatPattern(kind: .weekly) })
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        #expect(root.first("WeeklyRecurrence")?.child("DaysOfWeek") != nil)
        #expect(root.first("NoEndRecurrence")?.child("StartDate") != nil)
    }

    @Test func repeatChoicesAreWordedFromTheStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Wednesday 23 September 2026: the fourth Wednesday of the month.
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 13))!
        let workDays: Set<Int> = [7, 1, 2, 3, 4]
        let labels = RepeatPattern.presets(workDays: workDays).map { $0.label(start: start, workDays: workDays, calendar: calendar) }
        #expect(labels == ["Every day", "Every Wednesday", "Day 23 of every month"])
        #expect(RepeatPattern(kind: .yearly).label(start: start, workDays: workDays, calendar: calendar) == "Every September 23")
        #expect(RepeatPattern(kind: .weekly, weekdays: workDays).label(start: start, workDays: workDays, calendar: calendar) == "Every workday")
        #expect(RepeatPattern(kind: .monthlyWeek).label(start: start, workDays: workDays, calendar: calendar) == "Every fourth Wednesday")
        let custom = RepeatPattern(kind: .weekly, interval: 2, weekdays: [2, 4])
        #expect(custom.label(start: start, workDays: workDays, calendar: calendar) == "Every 2 weeks on Monday and Wednesday")
        #expect(RepeatPattern(kind: .monthlyWeek).xml(start: start, calendar: calendar)
            .contains("<t:DaysOfWeek>Wednesday</t:DaysOfWeek><t:DayOfWeekIndex>Fourth</t:DayOfWeekIndex>"))
    }

    @Test func aSeriesEndsOnADateOrAfterSomeTimesOrNever() throws {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        func range(_ end: RepeatEnd) throws -> XMLTreeNode? {
            let body = CalendarSOAP.createEvent(draft { $0.repeatPattern = RepeatPattern(kind: .daily); $0.repeatEnd = end })
            return try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body)).first("Recurrence")
        }
        #expect(try range(.never)?.child("NoEndRecurrence") != nil)
        #expect(try range(.on(until))?.first("EndDate") != nil)
        #expect(try range(.after(5))?.first("NumberOfOccurrences")?.trimmedText == "5")
        #expect(draft { $0.repeatPattern = RepeatPattern(kind: .daily); $0.repeatEnd = .on($0.start.addingTimeInterval(-86_400 * 3)) }.problem != nil)
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

    @Test func categoriesAndCharmGoInTheSchemasPlaces() throws {
        let body = CalendarSOAP.createEvent(draft { $0.categories = ["Storybook", "Red category"]; $0.charm = EventCharm.cake.rawValue })
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let item = try #require(root.first("CalendarItem"))
        #expect(item.children.map(\.name).prefix(7) == ["Subject", "Sensitivity", "Body", "Categories", "ReminderIsSet",
                                                          "ReminderMinutesBeforeStart", "ExtendedProperty"])
        #expect(item.child("Categories")?.children.map(\.trimmedText) == ["Storybook", "Red category"])
        #expect(EWSResponse.charm(in: item) == EventCharm.cake.rawValue)
    }

    @Test func anUpdateSetsOrClearsCategoriesAndCharm() {
        let set = CalendarSOAP.updateEvent(draft { $0.categories = ["Storybook"]; $0.charm = 3 }, id: "ev-1")
        #expect(set.contains(#"FieldURI="item:Categories"/><t:CalendarItem><t:Categories><t:String>Storybook"#))
        #expect(set.contains("<t:Value>3</t:Value>"))
        let cleared = CalendarSOAP.updateEvent(draft(), id: "ev-1")
        #expect(cleared.contains(#"<t:DeleteItemField><t:FieldURI FieldURI="item:Categories"/></t:DeleteItemField>"#))
        #expect(cleared.contains("<t:DeleteItemField>\(EventCharm.fieldURI)</t:DeleteItemField>"))
    }

    @Test func responseOptionsAreSentOnCreateAndUpdate() throws {
        let off = draft { $0.requestResponses = false; $0.allowForwarding = false }
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: CalendarSOAP.createEvent(off)))
        #expect(root.first("IsResponseRequested")?.trimmedText == "false")
        let forward = root.all("ExtendedProperty").first { $0.child("ExtendedFieldURI")?.attributes["PropertyName"] == "DoNotForward" }
        #expect(forward?.child("Value")?.trimmedText == "true")
        let update = CalendarSOAP.updateEvent(draft(), id: "ev-1")
        #expect(update.contains(#"FieldURI="calendar:IsResponseRequested"/><t:CalendarItem><t:IsResponseRequested>true"#))
        #expect(update.contains(#"PropertyName="DoNotForward" PropertyType="Boolean"/><t:Value>false</t:Value>"#))
    }

    @Test func startAndDurationMoveTogether() {
        var d = draft()
        d.duration = 90 * 60
        #expect(d.end == d.start.addingTimeInterval(5400))
        let later = d.start.addingTimeInterval(7200)
        d.startKeepingDuration = later
        #expect(d.start == later && d.duration == 5400)
        d.isAllDay = true
        d.days = 3
        #expect(d.days == 3)
        #expect(EventDraft.durationLabel(minutes: 90) == "1h 30m")
        #expect(EventDraft.durationLabel(minutes: 60) == "1h")
        #expect(EventDraft.durationLabel(minutes: 45) == "45m")
        #expect(EventDraft.reminderLabel(15) == "15m")
        #expect(EventDraft.reminderLabel(120) == "2h")
        #expect(EventDraft.reminderLabel(1440) == "1d")
    }

    @Test func availabilityTakesTheBusiestBlockInTheEvent() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000), end = start.addingTimeInterval(3600)
        let events = [MockCalendar.Event(id: "a", subject: "", start: start.addingTimeInterval(-1800), end: start.addingTimeInterval(600),
                                         showAs: "Tentative"),
                      MockCalendar.Event(id: "b", subject: "", start: start.addingTimeInterval(1800), end: end, showAs: "Busy"),
                      MockCalendar.Event(id: "c", subject: "", start: end, end: end.addingTimeInterval(3600), showAs: "OOF")]
        let xml = MockCalendar.availabilityResponse(["sara.rahimi@example.com", "omid@example.org", "someone@elsewhere.net"], events: events)
        let states = try EWSResponse.availability(from: Data(xml.utf8),
                                                  addresses: ["sara.rahimi@example.com", "omid@example.org", "someone@elsewhere.net"],
                                                  start: start, end: end)
        #expect(states == ["sara.rahimi@example.com": "Busy", "omid@example.org": "Free", "someone@elsewhere.net": "NoData"])
    }

    @Test func endBeforeStartIsRefused() {
        let d = draft { $0.end = $0.start.addingTimeInterval(-60) }
        #expect(d.problem != nil)
        #expect(draft { $0.people = [.init(name: "", address: "not an address")] }.problem != nil)
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

    @Test func aDraggedRangeBecomesTheNewEventsTimes() {
        let start = Calendar.current.date(bySettingHour: 10, minute: 15, second: 0, of: Date())!
        let end = start.addingTimeInterval(90 * 60)
        let draft = EventDraft.new(accountID: UUID(), at: start, until: end)
        #expect(draft.start == start)
        #expect(draft.end == end)
        // Without a range, or with one that runs backwards, it is an hour, as a double-click gives.
        #expect(EventDraft.new(accountID: UUID(), at: start).end == start.addingTimeInterval(3600))
        #expect(EventDraft.new(accountID: UUID(), at: start, until: start).end == start.addingTimeInterval(3600))
    }

    @Test func roomSearchMatchesEveryWordInAnyOrderAndEitherSpelling() {
        let rooms = [Room(name: "ساختمان نمونه | طبقه هفت | اتاق کوچک", address: "room.f7.small@example.com"),
                     Room(name: "ساختمان نمونه | طبقه سه | اتاق آبی", address: "room.f3.blue@example.com"),
                     Room(name: "Room Green", address: "room.green@example.com")]
        #expect(RoomSearch.filter(rooms, by: "").count == 3)
        #expect(RoomSearch.filter(rooms, by: "هفت نمونه").map(\.address) == ["room.f7.small@example.com"])
        #expect(RoomSearch.filter(rooms, by: "GREEN").map(\.name) == ["Room Green"])
        #expect(RoomSearch.filter(rooms, by: "f3").count == 1)
        // Typed with an Arabic kaf, stored with the Persian one.
        #expect(RoomSearch.filter(rooms, by: "\u{0643}وچ").count == 1)
        #expect(RoomSearch.filter(rooms, by: "هشت").isEmpty)
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
        #expect(store.editor?.attendeeList.contains("omid@example.org") == true)
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

    @Test func anEventWithFilesIsCreatedThenGivenThemThenSent() async throws {
        let store = try await makeStore()
        store.startNewEvent(at: Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date()))
        store.editor?.subject = "Files review"
        store.editor?.people = [.init(name: "Sara Rahimi", address: "sara.rahimi@example.com")]
        store.editor?.categories = ["Storybook"]
        store.editor?.charm = EventCharm.books.rawValue
        store.editor?.newFiles = [.init(name: "Plan.pdf", data: Data(repeating: 7, count: 1200))]
        await store.saveEditor()
        #expect(store.editor == nil)
        let created = try #require(store.events.first { $0.subject == "Files review" })
        #expect(created.categories == ["Storybook"])
        #expect(created.charm == EventCharm.books.rawValue)
        await store.select(created)
        guard case .loaded(let detail) = store.detail else { Issue.record("no detail"); return }
        #expect(detail.files.map(\.name) == ["Plan.pdf"])
        #expect(detail.files.first?.size == 1200)
    }

    @Test func responseOptionsSurviveASaveAndComeBackForEditing() async throws {
        let store = try await makeStore()
        store.startNewEvent(at: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        store.editor?.subject = "Private sync"
        store.editor?.people = [.init(name: "Sara Rahimi", address: "sara.rahimi@example.com")]
        store.editor?.requestResponses = false
        store.editor?.allowForwarding = false
        await store.saveEditor()
        let created = try #require(store.events.first { $0.subject == "Private sync" })
        await store.select(created)
        store.startEditing()
        #expect(store.editor?.requestResponses == false)
        #expect(store.editor?.allowForwarding == false)
    }

    @Test func aCancelledFormSendsNothing() async throws {
        let store = try await makeStore()
        let transport = try #require(store.mail.client.transport as? MockTransport)
        let before = transport.sentRequests.count
        store.startNewEvent(at: Date(), until: Date().addingTimeInterval(1800))
        store.editor?.subject = "Never saved"
        store.editor = nil
        #expect(transport.sentRequests.count == before)
        #expect(!store.events.contains { $0.subject == "Never saved" })
    }

    @Test func photosComeFromTheServerAndThoseWithoutOneGetNone() async throws {
        let store = try await makeStore()
        let sara = await store.photo(for: "sara.rahimi@example.com")
        #expect(sara?.size.width ?? 0 > 0)
        #expect(await store.photo(for: "omid@example.org") == nil)
        #expect(CalendarSOAP.getUserPhoto("a&b@example.com").contains("<m:Email>a&amp;b@example.com</m:Email>"))
    }

    @Test func peopleSuggestionsComeFromTheDirectoryToo() async throws {
        let store = try await makeStore()
        let found = await store.peopleSuggestions(for: "amir", excluding: "")
        let addresses = found.map(\.address)
        #expect(addresses.contains("amir.karimi@example.com"))
        #expect(addresses.contains("amirhossein.nadiri@example.com"))
        await store.loadRooms()
        #expect(store.rooms?.prefix(2).map(\.name) == ["Room Blue", "Room Green"])
    }
}

@MainActor
@Suite struct TimeFieldTests {
    private func key(_ code: UInt16, shift: Bool) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }

    @Test func shiftWithAnArrowMovesTheTimeByTenMinutes() {
        let picker = SteppingDatePicker()
        picker.shiftStep = 600
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        picker.dateValue = start
        picker.keyDown(with: key(126, shift: true))
        #expect(picker.dateValue == start.addingTimeInterval(600))
        picker.keyDown(with: key(125, shift: true))
        picker.keyDown(with: key(125, shift: true))
        #expect(picker.dateValue == start.addingTimeInterval(-600))
    }
}

@MainActor
@Suite struct SchedulingAssistantTests {
    @Test func busyBlocksComeBackForTheDay() async throws {
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let mail = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0)))
        await mail.refresh()
        let store = CalendarStore(mail: mail)
        let found = try #require(await store.busyBlocks(for: ["sara.rahimi@example.com", "omid@example.org"], on: Date()))
        let sara = try #require(found["sara.rahimi@example.com"] ?? nil)
        #expect(!sara.isEmpty)
        #expect((found["omid@example.org"] ?? nil)?.isEmpty == true)
    }

    @Test func theDetailedViewNamesWhoBookedARoom() throws {
        let xml = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:GetUserAvailabilityResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">\
        <m:FreeBusyResponseArray><m:FreeBusyResponse><m:ResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode></m:ResponseMessage>\
        <m:FreeBusyView><t:CalendarEventArray>\
        <t:CalendarEvent><t:StartTime>2026-09-26T10:00:00</t:StartTime><t:EndTime>2026-09-26T11:00:00</t:EndTime><t:BusyType>Busy</t:BusyType>\
        <t:CalendarEventDetails><t:Subject>Sara Rahimi</t:Subject><t:Location>Room Blue</t:Location><t:IsRecurring>true</t:IsRecurring><t:IsPrivate>false</t:IsPrivate></t:CalendarEventDetails></t:CalendarEvent>\
        <t:CalendarEvent><t:StartTime>2026-09-26T12:00:00</t:StartTime><t:EndTime>2026-09-26T13:00:00</t:EndTime><t:BusyType>Busy</t:BusyType></t:CalendarEvent>\
        </t:CalendarEventArray></m:FreeBusyView></m:FreeBusyResponse></m:FreeBusyResponseArray></m:GetUserAvailabilityResponse></s:Body></s:Envelope>
        """
        let found = try EWSResponse.busyBlocks(from: Data(xml.utf8), addresses: ["room.blue@example.com"])
        let blocks = try #require(found["room.blue@example.com"] ?? nil)
        #expect(blocks.count == 2)
        #expect(blocks[0].subject == "Sara Rahimi")
        #expect(blocks[0].location == "Room Blue")
        #expect(blocks[0].isRecurring)
        #expect(blocks[1].subject == nil)
        #expect(CalendarSOAP.availability(["a@example.com"], start: Date(), end: Date(), detailed: true)
            .contains("<t:RequestedView>Detailed</t:RequestedView>"))
        #expect(CalendarSOAP.availability(["a@example.com"], start: Date(), end: Date())
            .contains("<t:RequestedView>FreeBusy</t:RequestedView>"))
    }

    @Test func theBandsEdgesResizeAndItsMiddleMoves() {
        #expect(SchedulingAssistant.part(at: 2, width: 48) == .start)
        #expect(SchedulingAssistant.part(at: 24, width: 48) == .move)
        #expect(SchedulingAssistant.part(at: 46, width: 48) == .end)
        // A 15-minute band keeps a middle to take hold of.
        #expect(SchedulingAssistant.part(at: 6, width: 12) == .move)
    }
}

@Suite struct ScheduleTimelineTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Double) -> Date {
        // September 2026: the 26th is a Saturday.
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
        return base.addingTimeInterval(hour * 3600)
    }

    /// Saturday to Wednesday, 9 to 17, a meeting on Monday at 10.
    private func strip(meeting: (Date, Date)? = nil) -> ScheduleTimeline {
        ScheduleTimeline(first: date(26, 0), days: 7, workDays: [7, 1, 2, 3, 4], workHours: 9...17,
                         meeting: meeting ?? (date(28, 10), date(28, 11)), hourWidth: 48, calendar: calendar)
    }

    @Test func onlyWorkDaysAndWorkHoursShow() {
        let strip = strip()
        #expect(strip.segments.count == 5)
        #expect(strip.segments.allSatisfy { $0.hours == 9..<17 })
        #expect(strip.width == CGFloat(5 * 8 * 48))
        // Sunday's 09:00 sits right after Saturday's 17:00: nothing empty between.
        #expect(strip.x(for: date(27, 9)) == CGFloat(8 * 48))
        #expect(strip.x(for: date(26, 20)) == nil)
    }

    @Test func theMeetingsDayStretchesToTakeItInEvenOnADayOff() {
        // "September 31" is Thursday October 1, a day off in this work week.
        let strip = strip(meeting: (date(31, 18), date(31, 19)))
        let thursday = strip.segments.first { calendar.component(.weekday, from: $0.dayStart) == 5 }
        #expect(thursday?.hours == 9..<19)
    }

    @Test func pointsAndMomentsMapBothWays() {
        let strip = strip()
        let x = strip.x(for: date(28, 10))!
        #expect(strip.date(atX: x) == date(28, 10))
        #expect(strip.date(atX: -5) == date(26, 9))
        // At the seam, an end belongs to the earlier day.
        #expect(strip.date(atX: 8 * 48, preferEnd: true) == date(26, 17))
        #expect(strip.date(atX: 8 * 48) == date(27, 9))
        #expect(strip.x(for: date(26, 17), preferEnd: true) == CGFloat(8 * 48))
    }

    @Test func aRangeOverNightShowsAsOnePiecePerDay() {
        let strip = strip()
        let pieces = strip.spans(date(26, 16), date(27, 10))
        #expect(pieces.count == 2)
        #expect(pieces[0].width == 48)
        #expect(pieces[1].width == 48)
    }

    @Test func nextFreeTimeRunsOnIntoTheNextWorkDay() {
        let strip = strip()
        let busy = [BusyBlock(start: date(28, 9), end: date(28, 17), type: "Busy")]
        #expect(strip.nextFree(from: date(28, 10), length: 3600, busy: busy) == date(29, 9))
        #expect(strip.nextFree(from: date(28, 16.75), length: 3600, busy: []) == date(29, 9))
    }
}
