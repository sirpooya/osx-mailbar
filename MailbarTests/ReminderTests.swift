import Foundation
import Testing
@testable import Mailbar

/// M18: which events get a reminder, and what it says.
@Suite struct ReminderPlanTests {
    private let account = MockMode.accounts[0]
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, inMinutes: Int, reminder: Int?, response: String = "Accept",
                       cancelled: Bool = false) -> CalendarEvent {
        let start = now.addingTimeInterval(TimeInterval(inMinutes * 60))
        return CalendarEvent(id: id, changeKey: "", subject: "Standup \(id)", start: start,
                             end: start.addingTimeInterval(1800), isAllDay: false, location: "Room Blue",
                             organizer: "", isRecurring: false, isMeeting: true, isCancelled: cancelled,
                             myResponse: response, showAs: "Busy", isPrivate: false, reminderMinutes: reminder)
    }

    @Test func oneReminderPerEventAtItsTime() {
        let planned = EventReminders.plan([event("a", inMinutes: 60, reminder: 15)], account: account, now: now, showDetails: true)
        #expect(planned.count == 1)
        #expect(planned[0].fireDate == now.addingTimeInterval(45 * 60))
        #expect(planned[0].title == "Standup a")
        #expect(planned[0].body.contains("Room Blue"))
    }

    @Test func noReminderForNoReminderCancelledDeclinedOrAlreadyPast() {
        let events = [
            event("none", inMinutes: 60, reminder: nil),
            event("cancelled", inMinutes: 60, reminder: 15, cancelled: true),
            event("declined", inMinutes: 60, reminder: 15, response: "Decline"),
            event("past", inMinutes: 10, reminder: 15),
        ]
        #expect(EventReminders.plan(events, account: account, now: now, showDetails: true).isEmpty)
    }

    @Test func withDetailsOffItSaysOnlyEvent() {
        let planned = EventReminders.plan([event("a", inMinutes: 60, reminder: 15)], account: account, now: now, showDetails: false)
        #expect(planned.first?.title == "Event")
        #expect(planned.first?.body.contains("Room Blue") == false)
    }

    @Test func identifiersAreStableAcrossCalls() {
        let e = event("a", inMinutes: 60, reminder: 15)
        #expect(EventReminders.plan([e], account: account, now: now, showDetails: true).first?.identifier
                == EventReminders.plan([e], account: account, now: now, showDetails: true).first?.identifier)
    }

    @Test func theCalendarReadsEachEventsReminder() throws {
        let events = try EWSResponse.calendarEvents(from: Data(MockCalendar.findResponse(
            start: .distantPast, end: .distantFuture, events: MockCalendar.events()).utf8))
        let timed = try #require(events.first { !$0.isAllDay })
        #expect(timed.reminderMinutes == 15)
        let allDay = try #require(events.first { $0.isAllDay })
        #expect(allDay.reminderMinutes == nil)
    }
}
