import Foundation
import Testing
@testable import Mailbar

private func event(_ id: String, _ start: Date, minutes: Int, allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, changeKey: "", subject: id, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                  isAllDay: allDay, location: "", organizer: "", isRecurring: false, isMeeting: false,
                  isCancelled: false, myResponse: "Organizer", showAs: "Busy", isPrivate: false)
}

@Suite struct EventLayoutTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tehran")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: hour, minute: minute))!
    }

    @Test func overlappingEventsShareTheWidth() {
        let placed = EventLayout.place([event("a", at(15), minutes: 60), event("b", at(15), minutes: 90),
                                        event("c", at(17), minutes: 30)],
                                       on: at(0), calendar: calendar)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.event.id, $0) })
        #expect(byID["a"]?.columns == 2)
        #expect(byID["b"]?.columns == 2)
        #expect(Set([byID["a"]!.column, byID["b"]!.column]) == [0, 1])
        // Not overlapping the other two: the full width again.
        #expect(byID["c"]?.columns == 1)
        #expect(byID["c"]?.startHour == 17)
    }

    @Test func aFreedColumnIsReused() {
        let placed = EventLayout.place([event("long", at(9), minutes: 180), event("x", at(9), minutes: 30),
                                        event("y", at(10), minutes: 30)],
                                       on: at(0), calendar: calendar)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.event.id, $0) })
        #expect(byID["x"]?.column == byID["y"]?.column)
        #expect(byID["long"]?.columns == 2)
    }

    @Test func anEventFromTheDayBeforeIsClippedToMidnight() {
        let placed = EventLayout.place([event("late", at(0).addingTimeInterval(-3600), minutes: 120)],
                                       on: at(0), calendar: calendar)
        #expect(placed.first?.startHour == 0)
        #expect(placed.first?.endHour == 1)
    }

    @Test func anAllDayEventCoversItsDaysAndNotTheMidnightAfter() {
        let oneDay = event("holiday", at(0), minutes: 24 * 60, allDay: true)
        #expect(oneDay.days(in: calendar).count == 1)
        let twoDays = event("trip", at(0), minutes: 48 * 60, allDay: true)
        #expect(twoDays.days(in: calendar).count == 2)
    }
}

@MainActor
@Suite(.serialized) struct CalendarStoreTests {
    private func makeStore() -> CalendarStore {
        UserDefaults.standard.removeObject(forKey: Keys.calendarMode)
        Keys.registerDefaults()
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let mail = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0)))
        return CalendarStore(mail: mail)
    }

    @Test func theWeekRunsSaturdayToFriday() {
        let store = makeStore()
        store.mode = .week
        let calendar = store.calendar
        #expect(store.visibleDays.count == 7)
        #expect(calendar.component(.weekday, from: store.visibleDays[0]) == 7)
        #expect(calendar.component(.weekday, from: store.visibleDays[6]) == 6)

    }

    /// The crash of 2026-09-25: the month grid indexed six weeks while the mode was already Week.
    @Test func theMonthGridHasSixWeeksWhateverTheMode() {
        let store = makeStore()
        for mode in CalendarStore.Mode.allCases {
            store.mode = mode
            #expect(store.monthGridDays.count == 42)
        }
    }

    @Test func titlesUseNoSpacedDashes() {
        let store = makeStore()
        store.mode = .week
        store.anchor = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 21))!
        #expect(store.title.contains("\u{2013}") || store.title.contains(" to "))
        #expect(!store.title.contains(" \u{2013} ") && !store.title.contains("\u{2014}"))
    }

    @Test func refreshFetchesTheVisibleWeekAndTheDetailOfAnEvent() async throws {
        let store = makeStore()
        store.mode = .week
        store.anchor = Date()
        // Setting the mode and the anchor each start a refresh of their own, and the newest one
        // wins by design, so wait for the store to settle rather than on one particular call.
        await store.refresh()
        for _ in 0..<50 where store.phase != .loaded {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(store.phase == .loaded)
        let workflow = try #require(store.events.first { $0.subject == "Design System Workflow Demo" })
        #expect(workflow.isTentative)
        let hasHoliday = store.events.contains { $0.isAllDay && $0.subject == "Company holiday" }
        let hasCancelled = store.events.contains { $0.isCancelled }
        let dailies = store.events.filter { $0.subject == "Shopping Design Daily" }
        let dailiesRecur = dailies.allSatisfy { $0.isRecurring }
        #expect(hasHoliday)
        #expect(hasCancelled)
        #expect(!dailies.isEmpty && dailiesRecur)

        await store.select(workflow)
        guard case .loaded(let detail) = store.detail else {
            Issue.record("detail did not load: \(store.detail)")
            return
        }
        let responses = detail.attendees.map(\.response)
        #expect(responses.contains("NoResponseReceived"))
        #expect(detail.html.contains("token pipeline"))
    }

    @Test func requestAsksForTheRangeWithRecurrencesExpanded() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let body = SOAP.findCalendar(start: start, end: start.addingTimeInterval(7 * 86_400))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: body))
        let view = try #require(root.first("CalendarView"))
        #expect(view.attributes["StartDate"] == SOAP.isoDate(start))
        #expect(root.first("DistinguishedFolderId")?.attributes["Id"] == "calendar")
    }

    /// What a swipe pages between: the neighbours on either side, a view's own unit apart.
    @Test func swipeStepsMoveByTheViewsOwnUnit() {
        let store = makeStore()
        let calendar = store.calendar
        store.mode = .week
        let week = store.visibleRange.start
        #expect(store.days(page: 1).first == store.calendar.date(byAdding: .day, value: 7, to: week))
        #expect(store.days(page: -1).first == store.calendar.date(byAdding: .day, value: -7, to: week))
        // What is fetched covers both neighbours, so a swipe never slides in an empty week.
        #expect(store.fetchRange.start == store.days(page: -1).first)
        store.step(forward: true)
        #expect(calendar.dateComponents([.day], from: week, to: store.visibleRange.start).day == 7)
        store.step(forward: false)
        #expect(store.visibleRange.start == week)

        store.mode = .day
        let day = store.visibleRange.start
        store.step(forward: true)
        #expect(calendar.dateComponents([.day], from: day, to: store.visibleRange.start).day == 1)
    }

    /// The spring's decision on release: far enough or fast enough commits, otherwise back.
    @Test func thePagerCommitsOnDistanceOrFlickAndOtherwiseSpringsBack() async throws {
        let pager = CalendarPager()
        pager.width = 900
        var committed: [Bool] = []
        pager.onCommit = { committed.append($0) }

        pager.began()
        for step in 0..<10 {                    // slow and short, then a rest: back to rest
            pager.moved(by: -10, at: Double(step) * 0.1)
        }
        pager.ended(at: 1.0)
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(committed.isEmpty)
        #expect(pager.offset == 0)

        pager.began()
        pager.moved(by: -400, at: 1.0)          // past a third of the page: next
        pager.ended(at: 1.5)
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(committed == [true])

        pager.began()
        pager.moved(by: 30, at: 2.0)
        pager.moved(by: 40, at: 2.02)           // short but fast to the right: previous
        pager.ended(at: 2.03)
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(committed == [true, false])
        #expect(pager.offset == 0)
    }

    /// Category colours: from the master list for a custom name, from the name for a default one,
    /// and the accent for an event with none.
    @Test func eventsTakeTheirCategoryColour() async throws {
        let store = makeStore()
        store.mode = .week
        await store.refresh()
        for _ in 0..<50 where store.phase != .loaded { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(store.categoryColors["Storybook"] == 9)
        let demo = try #require(store.events.first { $0.subject == "ds demo alignment" })
        #expect(demo.categories == ["Storybook"])
        #expect(store.tint(for: demo) == CategoryColors.color(index: 9))
        let daily = try #require(store.events.first { $0.subject == "Shopping Design Daily" })
        #expect(store.tint(for: daily) == .accentColor)
        #expect(CategoryColors.guessedIndex(forName: "Green category") == 4)
        #expect(CategoryColors.parseMasterList(Data(MockCalendar.categoryListXML.utf8))["Red category"] == 0)
    }

    @Test func theStreamAlsoWatchesTheCalendar() {
        #expect(SOAP.subscribeToInbox.contains(#"<t:DistinguishedFolderId Id="calendar"/>"#))
    }
}
