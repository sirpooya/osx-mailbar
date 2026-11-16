import Foundation
import Testing
@testable import Mailbar

/// The calendar extras of 2026-11-16: series, proposals, counts, shortening, time zones,
/// warnings, saving without sending, invitee delete, .ics in and out, free time.
@Suite struct CalendarFeatureTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func draft(_ configure: (inout EventDraft) -> Void = { _ in }) -> EventDraft {
        let start = date(2026, 11, 18, 10)
        var draft = EventDraft(accountID: UUID(), start: start, end: start.addingTimeInterval(3600))
        draft.subject = "Review"
        configure(&draft)
        return draft
    }

    private func event(_ id: String, _ start: Date, _ end: Date, showAs: String = "Busy", response: String = "Accept",
                       allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, changeKey: "", subject: id, start: start, end: end, isAllDay: allDay, location: "",
                      organizer: "", isRecurring: false, isMeeting: false, isCancelled: false, myResponse: response,
                      showAs: showAs, isPrivate: false)
    }

    // MARK: - 84 Series

    @Test func aMasterIsReadWithItsRule() throws {
        let occurrence = MockCalendar.events().first { $0.id == "ev-tue-room" }!
        let master = try EWSResponse.seriesMaster(from: Data(MockCalendar.masterResponse(for: occurrence).utf8))
        #expect(master.detail.event.id == "ev-master-ev-tue-room")
        #expect(master.pattern?.kind == .weekly)
        #expect(master.pattern?.weekdays.count == 1)
        #expect(master.end == .never)
        #expect(!master.startDateText.isEmpty)
    }

    @Test func theMasterIsAskedForByItsOccurrence() {
        let body = CalendarSOAP.getMaster(occurrenceID: "occ-1")
        #expect(body.contains(#"<t:RecurringMasterItemId OccurrenceId="occ-1"/>"#))
        #expect(body.contains("calendar:Recurrence"))
        let delete = CalendarSOAP.deleteSeries(occurrenceID: "occ-1", cancelMeeting: true)
        #expect(delete.contains(#"RecurringMasterItemId OccurrenceId="occ-1""#))
        #expect(delete.contains(#"SendMeetingCancellations="SendToAllAndSaveCopy""#))
        #expect(delete.contains(#"DeleteType="MoveToDeletedItems""#))
    }

    @Test func editingAllEventsRewritesTheRule() throws {
        let body = CalendarSOAP.updateEvent(draft {
            $0.id = "master"
            $0.editsSeries = true
            $0.repeatPattern = RepeatPattern(kind: .daily, interval: 2)
            $0.repeatEnd = .after(5)
        }, id: "master")
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        #expect(root.first("DailyRecurrence")?.child("Interval")?.trimmedText == "2")
        #expect(root.first("NumberedRecurrence")?.child("NumberOfOccurrences")?.trimmedText == "5")
        // An occurrence's edit never touches the rule.
        #expect(!CalendarSOAP.updateEvent(draft { $0.id = "occ"; $0.repeatPattern = RepeatPattern(kind: .daily) }, id: "occ")
            .contains("calendar:Recurrence"))
    }

    @Test func thisAndFollowingEndsTheOldSeriesAndStartsANewOne() throws {
        let first = date(2026, 10, 6, 17)
        var masterDetail = EventDetail(event: event("master", first, first.addingTimeInterval(3600)), organizerAddress: "",
                                       attendees: [], rooms: [], html: "")
        masterDetail.reminderMinutes = 15
        let master = SeriesMaster(detail: masterDetail, pattern: RepeatPattern(kind: .weekly), end: .after(10),
                                  startDateText: "2026-10-06")
        let occurrenceStart = date(2026, 10, 27, 17)
        let occurrence = EventDetail(event: event("occ", occurrenceStart, occurrenceStart.addingTimeInterval(3600)),
                                     organizerAddress: "", attendees: [], rooms: [], html: "")
        let draft = try #require(CalendarStore.followingDraft(occurrence: occurrence, master: master, accountID: UUID(),
                                                              calendar: calendar))
        #expect(draft.isNew)
        #expect(draft.repeatPattern?.kind == .weekly)
        // Three met before the 27th (6th, 13th, 20th): seven left.
        #expect(draft.repeatEnd == .after(7))
        let split = try #require(draft.splitFrom)
        #expect(calendar.isDate(split.lastDay, inSameDayAs: date(2026, 10, 26)))
        let end = CalendarSOAP.endSeries(split, calendar: calendar)
        #expect(end.contains("<t:EndDate>2026-10-26</t:EndDate>"))
        #expect(end.contains("<t:StartDate>2026-10-06</t:StartDate>"))
        #expect(end.contains(#"SendMeetingInvitationsOrCancellations="SendToNone""#))
        // The first occurrence: This and Following is the whole series.
        let firstOccurrence = EventDetail(event: event("occ0", first, first.addingTimeInterval(3600)),
                                          organizerAddress: "", attendees: [], rooms: [], html: "")
        #expect(CalendarStore.followingDraft(occurrence: firstOccurrence, master: master, accountID: UUID(), calendar: calendar) == nil)
    }

    @Test func occurrencesAreCountedPerKind() {
        let start = date(2026, 1, 5)
        #expect(RepeatPattern(kind: .daily, interval: 2).occurrences(from: start, before: date(2026, 1, 11), calendar: calendar) == 3)
        #expect(RepeatPattern(kind: .monthlyDay).occurrences(from: start, before: date(2026, 4, 5), calendar: calendar) == 3)
        #expect(RepeatPattern.weekdays("Weekday") == [2, 3, 4, 5, 6])
    }

    // MARK: - 85, 86 Forward and Email Attendees

    @MainActor @Test func forwardAndEmailAttendeesFillTheDraft() {
        let store = MailStore(accounts: AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords), client: EWSClient(transport: MockTransport(mode: .inbox)))
        let account = UUID()
        store.startEventForward(eventID: "ev-1", subject: "Design Weekly", accountID: account)
        #expect(store.draft?.kind == .forward)
        #expect(store.draft?.originalID == "ev-1")
        #expect(store.isComposing)
        store.discardDraft()
        store.startEventEmail(to: ["a@example.com", "b@example.com"], subject: "Design Weekly", accountID: account)
        #expect(store.draft?.kind == .new)
        #expect(store.draft?.subject == "Design Weekly")
        #expect(Recipients.parse(store.draft?.to ?? "") == ["a@example.com", "b@example.com"])
    }

    @Test func emailAttendeesLeavesOutTheUser() {
        let detail = EventDetail(event: event("m", Date(), Date()), organizerAddress: "boss@example.com",
                                 attendees: [.init(name: "", address: "me@example.com", response: "Accept", isOptional: false),
                                             .init(name: "", address: "Boss@example.com", response: "Organizer", isOptional: false),
                                             .init(name: "", address: "sara@example.com", response: "Accept", isOptional: true)],
                                 rooms: [], html: "")
        #expect(CalendarStore.attendeeAddresses(detail, me: "ME@example.com") == ["boss@example.com", "sara@example.com"])
    }

    // MARK: - 87 Proposals

    @Test func proposalsAreReadFromTheAnswers() throws {
        let events = MockCalendar.events()
        let find = try #require(MockCalendar.extraResponse(to: CalendarSOAP.findMeetingResponses, events: events))
        let ids = try EWSResponse.meetingResponseIDs(from: Data(find.utf8), title: "ds demo alignment")
        #expect(ids == ["resp-omid", "resp-sara"])
        let get = try #require(MockCalendar.extraResponse(to: CalendarSOAP.getProposals(ids: ids), events: events))
        let proposals = try EWSResponse.proposals(from: Data(get.utf8), eventID: "ev-sun-demo", title: "ds demo alignment")
        #expect(proposals.map(\.address) == ["omid@example.org", "sara.rahimi@example.com"])
        #expect(proposals.allSatisfy { $0.end > $0.start })
    }

    @Test func acceptingAProposalMovesTheMeetingAndTellsEveryone() throws {
        let start = date(2026, 11, 20, 14)
        let body = CalendarSOAP.moveEvent(id: "ev", start: start, end: start.addingTimeInterval(3600), notify: true)
        #expect(body.contains(#"SendMeetingInvitationsOrCancellations="SendToAllAndSaveCopy""#))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        #expect(root.first("Start").flatMap { EWSResponse.parseDate($0.trimmedText) } == start)
    }

    // MARK: - 88 Counts

    @Test func responsesAreCountedWithoutTheOrganizer() {
        func person(_ address: String, _ response: String) -> EventDetail.Attendee {
            .init(name: "", address: address, response: response, isOptional: false)
        }
        let counts = ResponseCounts(attendees: [person("a@x", "Accept"), person("b@x", "Accept"), person("c@x", "Tentative"),
                                                person("d@x", "Decline"), person("e@x", "NoResponseReceived"),
                                                person("f@x", "Unknown"), person("me@x", "Accept")], organizer: "ME@x")
        #expect(counts.text == "2 accepted, 1 tentative, 1 declined, 2 not responded")
        #expect(ResponseCounts(attendees: [], organizer: "").text == nil)
        #expect(ResponseCounts(attendees: [person("a@x", "Accept")], organizer: "").text == "1 accepted")
    }

    // MARK: - 89 Shorten

    @Test func shortenedEventsEndEarly() {
        let slot = date(2026, 11, 18, 10)
        #expect(EventDraft.new(accountID: UUID(), at: slot, shorten: 5).end == slot.addingTimeInterval(55 * 60))
        #expect(EventDraft.new(accountID: UUID(), at: slot, until: slot.addingTimeInterval(5400), shorten: 10).end
                == slot.addingTimeInterval(80 * 60))
        // A 15-minute drag keeps its length.
        #expect(EventDraft.new(accountID: UUID(), at: slot, until: slot.addingTimeInterval(900), shorten: 10).end
                == slot.addingTimeInterval(900))
        #expect(EventDraft.new(accountID: UUID(), at: slot, shorten: 0).end == slot.addingTimeInterval(3600))
        let defaults = UserDefaults(suiteName: "shorten-\(UUID())")!
        defaults.set(7, forKey: Keys.calendarShortenMinutes)
        #expect(Keys.shortenEventMinutes(defaults) == 0)
        defaults.set(10, forKey: Keys.calendarShortenMinutes)
        #expect(Keys.shortenEventMinutes(defaults) == 10)
    }

    // MARK: - 90 Time zones

    @Test func startAndEndZonesFollowRecurrence() throws {
        let body = CalendarSOAP.createEvent(draft {
            $0.startTimeZone = "Iran Standard Time"
            $0.endTimeZone = "Turkey Standard Time"
        })
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let item = try #require(root.first("CalendarItem"))
        #expect(item.child("StartTimeZone")?.attributes["Id"] == "Iran Standard Time")
        #expect(item.child("EndTimeZone")?.attributes["Id"] == "Turkey Standard Time")
        #expect(item.children.last?.name == "EndTimeZone")
        // Never on an all-day event, and an update sets them too.
        #expect(!CalendarSOAP.createEvent(draft { $0.isAllDay = true; $0.startTimeZone = "UTC" }).contains("StartTimeZone"))
        #expect(CalendarSOAP.updateEvent(draft { $0.endTimeZone = "UTC" }, id: "e").contains(#"FieldURI="calendar:EndTimeZone""#))
    }

    @Test func aZoneChangeKeepsTheClock() throws {
        let tehran = try #require(TimeZone(identifier: "Asia/Tehran"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        var source = Calendar(identifier: .gregorian)
        source.timeZone = tehran
        let nine = source.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let moved = EventZones.sameClock(nine, from: tehran, to: utc)
        var target = Calendar(identifier: .gregorian)
        target.timeZone = utc
        #expect(target.component(.hour, from: moved) == 9)
        #expect(WindowsTimeZone.zone(for: "Iran Standard Time")?.identifier == "Asia/Tehran")
        #expect(WindowsTimeZone.label(for: "Iran Standard Time") == "Tehran +03:30")
    }

    // MARK: - 91 Warnings

    @Test func missingTitleThenLocationIsAskedAbout() {
        #expect(draft { $0.subject = " " }.missingWarning == .title)
        let meeting = draft { $0.people = [.init(name: "", address: "a@example.com")] }
        #expect(meeting.missingWarning == .location)
        #expect(draft { $0.people = meeting.people; $0.rooms = [Room(name: "Blue", address: "blue@example.com")] }.missingWarning == nil)
        #expect(draft().missingWarning == nil)
    }

    // MARK: - 92 Save without sending

    @Test func savingWithoutSendingTellsNobody() {
        let meeting = draft { $0.people = [.init(name: "", address: "a@example.com")]; $0.saveWithoutSending = true }
        #expect(CalendarSOAP.createEvent(meeting).contains(#"SendMeetingInvitations="SendToNone""#))
        #expect(CalendarSOAP.updateEvent(meeting, id: "e").contains(#"SendMeetingInvitationsOrCancellations="SendToNone""#))
        // Saved so before, sent now: everyone is invited.
        var later = meeting
        later.saveWithoutSending = false
        later.invitationsUnsent = true
        later.originalInvitees = later.invitees
        #expect(CalendarSOAP.updateEvent(later, id: "e").contains(#"SendMeetingInvitationsOrCancellations="SendToAllAndSaveCopy""#))
    }

    @Test func anUnsentMeetingReadsBackAsUnsent() throws {
        var event = MockCalendar.events().first { $0.id == "ev-sun-demo" }!
        event.requestSent = false
        let detail = try EWSResponse.eventDetail(from: Data(MockCalendar.getResponse(event).utf8))
        #expect(!detail.meetingRequestWasSent)
        #expect(EventDraft.editing(detail, accountID: UUID()).invitationsUnsent)
    }

    // MARK: - 93 Delete quietly

    @Test func deletingQuietlySendsNoCancellation() {
        #expect(CalendarSOAP.deleteEvent(id: "e", cancelMeeting: false).contains(#"SendMeetingCancellations="SendToNone""#))
    }

    // MARK: - 94 .ics in

    @Test func anICSFileIsRead() throws {
        let events = ICalendar.events(in: Data(MockCalendar.sampleICS.utf8), calendar: calendar)
        #expect(events.count == 2)
        let workshop = events[0]
        #expect(workshop.summary == "Accessibility workshop")
        #expect(workshop.location == "Example Hall, Room 2")
        #expect(workshop.notes == "Bring a laptop.\nSlides are shared after.")
        var tehran = Calendar(identifier: .gregorian)
        tehran.timeZone = TimeZone(identifier: "Asia/Tehran")!
        #expect(tehran.component(.hour, from: workshop.start) == 10)
        #expect(workshop.end.timeIntervalSince(workshop.start) == 7200)
        let offsite = events[1]
        #expect(offsite.isAllDay)
        #expect(offsite.repeatPattern?.kind == .monthlyDay)
        #expect(offsite.repeatEnd == .after(3))
        let draft = ICalendar.draft(offsite, accountID: UUID())
        #expect(calendar.isDate(draft.end, inSameDayAs: draft.start))
        #expect(CalendarSOAP.createEvent(draft).contains(#"SendMeetingInvitations="SendToNone""#))
    }

    @Test func icsDetailsAreHandled() {
        #expect(ICalendar.unfolded("SUMMARY:Long\r\n  title\r\nEND:VEVENT") == ["SUMMARY:Long title", "END:VEVENT"])
        let utc = ICalendar.date("20261120T100000Z", params: [:], calendar: calendar)
        #expect(utc?.0 == ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z"))
        let windows = ICalendar.date("20261120T100000", params: ["TZID": "Iran Standard Time"], calendar: calendar)
        #expect(windows?.0 == ISO8601DateFormatter().date(from: "2026-11-20T06:30:00Z"))
        #expect(ICalendar.seconds(inDuration: "PT1H30M") == 5400)
        let weekly = ICalendar.repeatRule("FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261231", start: Date(), calendar: calendar)
        #expect(weekly.0?.weekdays == [2, 4])
        #expect(ICalendar.repeatRule("FREQ=MONTHLY;BYDAY=2TU", start: Date(), calendar: calendar).0?.kind == .monthlyWeek)
        #expect(ICalendar.isCalendarFile(name: "Invite.ICS"))
        #expect(ICalendar.isCalendarFile(name: "old.vcs"))
        #expect(!ICalendar.isCalendarFile(name: "notes.pdf"))
    }

    // MARK: - 95 .ics out

    @Test func anEventIsExportedFromItsMimeContent() throws {
        let events = MockCalendar.events()
        let request = CalendarSOAP.exportEvent(id: "ev-sun-demo")
        #expect(request.contains("<t:IncludeMimeContent>true</t:IncludeMimeContent>"))
        let reply = try #require(MockCalendar.extraResponse(to: request, events: events))
        let bytes = try EWSResponse.mimeContent(from: Data(reply.utf8))
        #expect(String(decoding: bytes, as: UTF8.self).contains("SUMMARY:ds demo alignment"))
        #expect(ICalendar.events(in: bytes).first?.summary == "ds demo alignment")
    }

    // MARK: - 96 Free time

    @Test func freeTimeIsTheWorkDaysGaps() {
        let day = date(2026, 11, 18)
        let weekday = calendar.component(.weekday, from: day)
        let events = [
            event("a", date(2026, 11, 18, 10), date(2026, 11, 18, 11)),
            event("b", date(2026, 11, 18, 11, 15), date(2026, 11, 18, 12)),
            event("free", date(2026, 11, 18, 13), date(2026, 11, 18, 14), showAs: "Free"),
            event("declined", date(2026, 11, 18, 15), date(2026, 11, 18, 16), response: "Decline"),
            event("c", date(2026, 11, 18, 16), date(2026, 11, 18, 18)),
            event("allday", day, date(2026, 11, 19), allDay: true),
        ]
        let gaps = FreeSlots.gaps(in: events, on: day, workHours: 9...17, workDays: [weekday], calendar: calendar)
        #expect(gaps.map { calendar.component(.hour, from: $0.start) } == [9, 12])
        #expect(gaps.map { calendar.component(.hour, from: $0.end) } == [10, 16])
        #expect(FreeSlots.label(gaps[1]) == "Free 12:00 to 16:00")
        #expect(FreeSlots.gaps(in: [], on: day, workHours: 9...17, workDays: [], calendar: calendar).isEmpty)
    }
}
