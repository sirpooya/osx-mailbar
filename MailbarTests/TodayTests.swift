import Foundation
import Testing
@testable import Mailbar

/// M19: the Today strip.
@Suite struct TodayAgendaTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, from start: TimeInterval, to end: TimeInterval, response: String = "Accept",
                       cancelled: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, changeKey: "", subject: id, start: now.addingTimeInterval(start),
                      end: now.addingTimeInterval(end), isAllDay: false, location: "", organizer: "",
                      isRecurring: false, isMeeting: true, isCancelled: cancelled, myResponse: response,
                      showAs: "Busy", isPrivate: false)
    }

    @Test func theRestOfTodayUnderWayFirstThenSoonest() {
        let calendar = Calendar.current
        let tonight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!.timeIntervalSince(now)
        let events = [
            event("later", from: 3600, to: 5400),
            event("over", from: -7200, to: -3600),
            event("now", from: -600, to: 1200),
            event("declined", from: 1800, to: 3600, response: "Decline"),
            event("cancelled", from: 1800, to: 3600, cancelled: true),
            event("tomorrow", from: tonight + 3600, to: tonight + 7200),
        ]
        #expect(TodayAgenda.rest(of: events, now: now).map(\.id) == ["now", "later"])
    }

    @Test func howSoonReadsNaturally() {
        #expect(TodayAgenda.relative(event("a", from: -60, to: 600), now: now) == "Now")
        #expect(TodayAgenda.relative(event("a", from: 25 * 60, to: 3600), now: now) == "in 25 min")
        #expect(TodayAgenda.relative(event("a", from: 120 * 60, to: 9000), now: now) == "in 2 h")
    }

    @Test func meetingLinksAreFoundAndOthersIgnored() {
        let teams = #"<a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d&amp;x=1">Join</a>"#
        #expect(TodayAgenda.joinLink(inHTML: teams)?.host == "teams.microsoft.com")
        #expect(TodayAgenda.joinLink(inHTML: "Zoom: https://example.zoom.us/j/123456?pwd=abc")?.host == "example.zoom.us")
        #expect(TodayAgenda.joinLink(inHTML: "https://meet.google.com/abc-defg-hij")?.host == "meet.google.com")
        #expect(TodayAgenda.joinLink(inHTML: "<a href=\"https://example.com/agenda\">Agenda</a>") == nil)
    }

    @MainActor
    @Test func theStripIsFilledFromTheCalendarWithTheJoinLink() async throws {
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let mail = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0)))
        let reminders = EventReminders(mail: mail)
        await reminders.update(force: true, schedule: false)
        let today = mail.todayEvents(for: MockMode.accounts[0].id)
        let subjects = today.map(\.subject)
        #expect(subjects.contains("Focus block"))
        #expect(subjects.contains("Design sync"))
        let focus = try #require(today.first { $0.subject == "Focus block" })
        let sync = try #require(today.first { $0.subject == "Design sync" })
        // The one under way has no link; the next one's Teams link is found in its notes.
        #expect(mail.joinLinks[focus.id] == nil)
        #expect(mail.joinLinks[sync.id]?.host == "teams.microsoft.com")
    }
}
