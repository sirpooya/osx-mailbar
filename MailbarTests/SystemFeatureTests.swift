import Foundation
import Testing
@testable import Mailbar

/// M26: the widgets' file, the menu bar count, sounds and banner actions.
@Suite struct SystemFeatureTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tehran")!
        return calendar
    }

    /// 10:00 in Tehran on a fixed day.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10))!
    }

    private func event(_ id: String, from start: TimeInterval, to end: TimeInterval, response: String = "Accept",
                       cancelled: Bool = false, location: String = "") -> CalendarEvent {
        CalendarEvent(id: id, changeKey: "secret-change-key", subject: id, start: now.addingTimeInterval(start),
                      end: now.addingTimeInterval(end), isAllDay: false, location: location, organizer: "boss@example.com",
                      isRecurring: false, isMeeting: true, isCancelled: cancelled, myResponse: response,
                      showAs: "Busy", isPrivate: false)
    }

    // MARK: Widgets

    @Test func widgetFileKeepsTodaysRemainingEventsOnly() {
        let events = [
            event("over", from: -7200, to: -3600),
            event("now", from: -600, to: 1200, location: "Room Blue"),
            event("declined", from: 1800, to: 3600, response: "Decline"),
            event("cancelled", from: 1800, to: 3600, cancelled: true),
            event("tomorrow", from: 86_400, to: 90_000),
            event("later", from: 3600, to: 5400),
        ]
        let link = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!
        let agenda = WidgetFeed.agenda(from: events, links: ["now": link], now: now, calendar: calendar)
        #expect(agenda.events.map(\.title) == ["now", "later"])
        #expect(agenda.events.first?.location == "Room Blue")
        #expect(agenda.events.first?.joinURL == link)
        #expect(agenda.events.last?.joinURL == nil)
        #expect(agenda.day == calendar.startOfDay(for: now))
        #expect(agenda.timeZone == "Asia/Tehran")
    }

    /// Only start, end, title, location and the join link reach the disk: no ids, change keys,
    /// organizers or notes.
    @Test func widgetFileCarriesNoOtherFields() throws {
        let agenda = WidgetFeed.agenda(from: [event("Design review", from: 600, to: 3600, location: "Room Blue")],
                                       links: [:], now: now, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = try #require(String(data: encoder.encode(agenda), encoding: .utf8))
        #expect(!json.contains("secret-change-key"))
        #expect(!json.contains("boss@example.com"))
        let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(agenda)) as? [String: Any])
        let first = try #require((object["events"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["start", "end", "title", "location"])
        #expect(Set(object.keys) == ["day", "timeZone", "events"])
    }

    @Test func widgetUpNextSkipsAllDayAndStaleDays() {
        let day = calendar.startOfDay(for: now)
        let agenda = WidgetAgenda(day: day, timeZone: "Asia/Tehran", events: [
            .init(start: day, end: day.addingTimeInterval(86_400), title: "Holiday", location: "", joinURL: nil),
            .init(start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600), title: "Standup", location: "", joinURL: nil),
            .init(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-60), title: "Over", location: "", joinURL: nil),
        ])
        #expect(agenda.upNext(at: now).map(\.title) == ["Standup"])
        #expect(agenda.remaining(at: now).map(\.title) == ["Holiday", "Standup"])
        #expect(agenda.span(agenda.events[1]) == "10:30 to 11:00")
        #expect(agenda.relative(agenda.events[1], now: now) == "in 30 min")
        // Yesterday's file shows nothing rather than yesterday's meetings.
        #expect(agenda.remaining(at: now.addingTimeInterval(86_400)).isEmpty)
        // It redraws before Standup (Join), at its start and end, and at midnight.
        #expect(agenda.refreshDates(after: now) == [now.addingTimeInterval(900), now.addingTimeInterval(1800),
                                                     now.addingTimeInterval(3600), day.addingTimeInterval(86_400)])
    }

    // MARK: Menu bar count

    @Test func menuBarCountFollowsTheSetting() {
        let a = UUID(), b = UUID()
        let unread = [a: 3, b: 4]
        #expect(MenuBarCount.allAccounts.count(unread: unread, selected: a) == 7)
        #expect(MenuBarCount.selectedAccount.count(unread: unread, selected: b) == 4)
        #expect(MenuBarCount.selectedAccount.count(unread: unread, selected: nil) == 0)
        #expect(MenuBarCount.off.count(unread: unread, selected: a) == 0)
    }

    @Test func newSettingsHaveTheirDefaults() {
        let defaults = UserDefaults(suiteName: "SystemFeatureTests.\(UUID().uuidString)")!
        Keys.registerDefaults(defaults)
        #expect(defaults.string(forKey: Keys.newMailSound) == "default")
        #expect(defaults.string(forKey: Keys.sentSound) == "none")
        #expect(defaults.string(forKey: Keys.menuBarCount) == "all")
        #expect(defaults.bool(forKey: Keys.widgetEvents))
    }

    // MARK: Sounds and banner actions

    @Test func soundsComeFromTheSystem() {
        #expect(MailSounds.systemNames.contains("Glass"))
        #expect(MailSounds.notificationSound(for: MailSounds.none) == nil)
        #expect(MailSounds.notificationSound(for: MailSounds.systemDefault) != nil)
        #expect(MailSounds.notificationSound(for: "Glass") != nil)
    }

    @Test func bannerActionsAreTheThreeMailActions() {
        #expect(NotificationService.MailAction.allCases.map(\.title) == ["Mark as Read", "Archive", "Delete"])
        #expect(NotificationService.MailAction(rawValue: "mailbar.archive") == .archive)
        #expect(NotificationService.MailAction(rawValue: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
    }
}
