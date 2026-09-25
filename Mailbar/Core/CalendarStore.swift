import Foundation
import Observation
import SwiftUI

/// What the calendar window shows (M15): which account, which days, and the events on them.
///
/// Only the visible range is fetched, into memory, and replaced on every refresh. Nothing is
/// written to disk, the same rule as mail.
@MainActor
@Observable
final class CalendarStore {
    enum Mode: String, CaseIterable, Identifiable {
        // No work week: the user took it out of the toolbar (2026-09-25). A saved "workWeek" from
        // before no longer decodes, so the window opens in Week.
        case day, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: return "Day"
            case .week: return "Week"
            case .month: return "Month"
            }
        }
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum DetailPhase: Equatable {
        case idle
        case loading
        case loaded(EventDetail)
        case failed(String)
    }

    let mail: MailStore

    var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.calendarMode)
            Task { await refresh() }
        }
    }
    /// The day in focus. The visible range is built around it.
    var anchor: Date {
        didSet { Task { await refresh() } }
    }
    var accountID: UUID? {
        didSet { Task { await refresh() } }
    }

    private(set) var phase: Phase = .loading
    private(set) var events: [CalendarEvent] = []
    private(set) var lastRefresh: Date?
    var selectedEventID: String?
    private(set) var detail: DetailPhase = .idle

    /// Category name to Outlook colour index, read once per account from its master list.
    private(set) var categoryColors: [String: Int] = [:]
    @ObservationIgnored private var categoriesLoadedFor: UUID?

    /// The colour an event is drawn in, as OWA draws it: its first category's colour from the
    /// server's master list, exactly; grey for a category the list says has no colour. Only when
    /// the list could not be read at all is a default name's colour guessed. No category at all:
    /// the accent.
    func tint(for event: CalendarEvent) -> Color {
        if event.isCancelled { return .gray }
        guard let first = event.categories.first else { return .accentColor }
        if !categoryColors.isEmpty {
            if let index = categoryColors[first] {
                return CategoryColors.color(index: index) ?? CategoryColors.neutral
            }
            // A category the list does not know: Outlook shows it uncoloured, so do we.
            return CategoryColors.neutral
        }
        if let index = CategoryColors.guessedIndex(forName: first), let color = CategoryColors.color(index: index) {
            return color
        }
        return CategoryColors.neutral
    }

    /// A newer refresh supersedes an older one still in flight.
    @ObservationIgnored private var generation = 0

    init(mail: MailStore) {
        self.mail = mail
        self.mode = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.calendarMode) ?? "") ?? .week
        self.anchor = Date()
        self.accountID = mail.selectedAccount?.id
        pager.onCommit = { [weak self] forward in self?.step(forward: forward) }
    }

    // MARK: - The calendar and its days

    /// The user's calendar with the week starting where Settings says (Saturday by default, as
    /// in their OWA).
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = Keys.calendarWeekStart()
        return calendar
    }

    var workDays: Set<Int> { Keys.calendarWorkDays() }
    var workHours: ClosedRange<Int> { Keys.calendarWorkHours() }

    var account: Account? {
        accountID.flatMap(mail.accounts.account) ?? mail.accounts.accounts.first
    }

    /// The columns the grid draws, or for Month every day of the six weeks shown.
    var visibleDays: [Date] { days(page: 0) }

    /// Always exactly 42 days, six weeks from the week the anchor's month starts in. The month
    /// grid reads these, never `visibleDays`: switching from Month to Week renders the month grid
    /// one last time after `mode` has changed, and indexing a 7-day list as 42 crashed the app
    /// (2026-09-25).
    var monthGridDays: [Date] { monthGridDays(page: 0) }

    /// The anchor moved by `page` of the current view's own unit: days, weeks or months.
    func anchor(page: Int) -> Date {
        guard page != 0 else { return anchor }
        let calendar = self.calendar
        switch mode {
        case .day: return calendar.date(byAdding: .day, value: page, to: anchor) ?? anchor
        case .week: return calendar.date(byAdding: .weekOfYear, value: page, to: anchor) ?? anchor
        case .month: return calendar.date(byAdding: .month, value: page, to: anchor) ?? anchor
        }
    }

    /// The days of a page: 0 is what is on screen, -1 and 1 the neighbours the swipe slides in.
    func days(page: Int) -> [Date] {
        let calendar = self.calendar
        let day = calendar.startOfDay(for: anchor(page: page))
        switch mode {
        case .day:
            return [day]
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .month:
            return monthGridDays(page: page)
        }
    }

    func monthGridDays(page: Int) -> [Date] {
        let calendar = self.calendar
        let day = calendar.startOfDay(for: anchor(page: page))
        let monthStart = calendar.dateInterval(of: .month, for: day)?.start ?? day
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let days = (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
        return days.count == 42 ? days : (0..<42).map { gridStart.addingTimeInterval(TimeInterval($0) * 86_400) }
    }

    /// The month a month page belongs to, for dimming the days of the months around it.
    func month(page: Int) -> Int {
        calendar.component(.month, from: anchor(page: page))
    }

    var visibleRange: (start: Date, end: Date) {
        let days = visibleDays
        let start = days.first ?? calendar.startOfDay(for: anchor)
        let end = days.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? start
        return (start, end)
    }

    /// What is fetched: the page on screen and both neighbours, so a swipe slides in a week that
    /// already has its events, as Calendar does, instead of an empty one that fills in after.
    var fetchRange: (start: Date, end: Date) {
        let before = days(page: -1)
        let after = days(page: 1)
        let start = before.first ?? visibleRange.start
        let end = after.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? visibleRange.end
        return (start, end)
    }

    /// "September 19–25, 2026", "Monday, September 21, 2026", "September 2026". An unspaced dash
    /// for a range inside one month, the words "to" across months (no spaced dashes, AGENTS.md).
    var title: String {
        let calendar = self.calendar
        let days = visibleDays
        guard let first = days.first, let last = days.last else { return "" }
        func style() -> Date.FormatStyle {
            Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone)
        }
        switch mode {
        case .day:
            return first.formatted(style().weekday(.wide).month(.wide).day().year())
        case .month:
            return anchor.formatted(style().month(.wide).year())
        case .week:
            let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
            let year = last.formatted(style().year())
            if sameMonth {
                return "\(first.formatted(style().month(.wide))) \(first.formatted(style().day()))\u{2013}\(last.formatted(style().day())), \(year)"
            }
            return "\(first.formatted(style().month(.wide).day())) to \(last.formatted(style().month(.wide).day())), \(year)"
        }
    }

    /// The title when the toolbar is short of room: "Sep 19–25", "Fri, Sep 25", "Sep 2026".
    var shortTitle: String {
        let calendar = self.calendar
        let days = visibleDays
        guard let first = days.first, let last = days.last else { return "" }
        let style = Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone)
        switch mode {
        case .day:
            return first.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
        case .month:
            return anchor.formatted(style.month(.abbreviated).year())
        case .week:
            if calendar.isDate(first, equalTo: last, toGranularity: .month) {
                return "\(first.formatted(style.month(.abbreviated))) \(first.formatted(style.day()))\u{2013}\(last.formatted(style.day()))"
            }
            return "\(first.formatted(style.month(.abbreviated).day())) to \(last.formatted(style.month(.abbreviated).day()))"
        }
    }

    /// The narrowest title: just the month (or months) on screen.
    var tinyTitle: String {
        let calendar = self.calendar
        let style = Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone)
        return (visibleDays.first ?? anchor).formatted(style.month(.wide))
    }

    func goToday() {
        anchor = Date()
    }

    /// Moves one page, at once. The swipe and the arrows call `slide(forward:)` instead, which
    /// animates the pager and then calls this.
    func step(forward: Bool) {
        anchor = anchor(page: forward ? 1 : -1)
    }

    /// The arrow buttons and Cmd+arrow: the same slide the swipe ends with.
    func slide(forward: Bool) {
        pager.settle(forward: forward)
    }

    /// The horizontal position of the three pages (M15, swipe). Read only by the page strips, so
    /// following the fingers moves pixels without rebuilding the grid.
    let pager = CalendarPager()

    /// Month view: clicking a day opens that day.
    func open(day: Date) {
        mode = .day
        anchor = day
    }

    // MARK: - Events per day

    func timedEvents(on day: Date) -> [CalendarEvent] {
        let calendar = self.calendar
        return events.filter { !$0.isAllDay && $0.days(in: calendar).contains(calendar.startOfDay(for: day)) }
    }

    func allDayEvents(on day: Date) -> [CalendarEvent] {
        let calendar = self.calendar
        return events.filter { $0.isAllDay && $0.days(in: calendar).contains(calendar.startOfDay(for: day)) }
    }

    func events(on day: Date) -> [CalendarEvent] {
        allDayEvents(on: day) + timedEvents(on: day).sorted { $0.start < $1.start }
    }

    var selectedEvent: CalendarEvent? {
        selectedEventID.flatMap { id in events.first { $0.id == id } }
    }

    // MARK: - Loading

    func refresh() async {
        guard let account else {
            phase = .failed("Add an account in Settings to see its calendar.")
            events = []
            return
        }
        guard let (url, credential) = mail.connection(for: account.id) else {
            phase = .failed("The password for \(account.displayName) is missing. Enter it in Settings.")
            return
        }
        generation += 1
        let mine = generation
        if events.isEmpty { phase = .loading }
        let range = fetchRange
        if categoriesLoadedFor != account.id {
            categoriesLoadedFor = account.id
            // Colours are a nicety: a mailbox without a list, or a server that refuses, keeps the
            // name-based guess and the accent colour.
            categoryColors = (try? await mail.client.categoryColors(at: url, credential: credential)) ?? [:]
        }
        do {
            let found = try await mail.client.calendarEvents(from: range.start, to: range.end,
                                                             at: url, credential: credential)
            guard mine == generation else { return }
            events = found.sorted { $0.start < $1.start }
            phase = .loaded
            lastRefresh = Date()
            if let selected = selectedEventID, !events.contains(where: { $0.id == selected }) {
                selectedEventID = nil
                detail = .idle
            }
        } catch is CancellationError {
            return
        } catch let error as EWSError {
            guard mine == generation else { return }
            phase = .failed(error.message(host: account.host))
        } catch {
            guard mine == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Creating, editing, deleting (M16)

    /// The event form, when open. In memory only.
    var editor: EventDraft?
    /// A short confirmation under the toolbar ("Invitations sent.").
    var notice: String?
    /// Rooms the organization publishes, loaded the first time the room menu opens.
    private(set) var rooms: [Room]?

    func startNewEvent(at slot: Date? = nil) {
        guard let account else { return }
        editor = EventDraft.new(accountID: account.id, at: slot)
    }

    /// Opens the form on the selected event, once its details have loaded.
    func startEditing() {
        guard let account, case .loaded(let detail) = detail else { return }
        editor = EventDraft.editing(detail, accountID: account.id)
    }

    /// Whether the selected event is this user's to change: their own appointment or a meeting
    /// they organized. An invitation is answered instead (M17), not edited.
    var canEditSelected: Bool {
        guard let event = selectedEvent else { return false }
        return !event.isCancelled && (!event.isMeeting || event.isOrganizer)
    }

    func saveEditor() async {
        guard var draft = editor, draft.problem == nil, !draft.isSaving,
              let (url, credential) = mail.connection(for: draft.accountID) else { return }
        draft.isSaving = true
        draft.error = nil
        editor = draft
        do {
            if let id = draft.id {
                try await mail.client.updateEvent(draft, id: id, at: url, credential: credential)
            } else {
                try await mail.client.createEvent(draft, at: url, credential: credential)
            }
            editor = nil
            show(notice: draft.sendsInvitations ? (draft.isNew ? "Invitations sent." : "Updates sent.") : "Saved.")
            await refresh()
            if let id = draft.id, let event = events.first(where: { $0.id == id }) { await select(event) }
        } catch {
            editor?.isSaving = false
            editor?.error = describe(error)
        }
    }

    /// Deletes the selected event. A meeting the user organized sends the cancellation.
    func deleteSelected() async {
        guard let event = selectedEvent, canEditSelected, let account,
              let (url, credential) = mail.connection(for: account.id) else { return }
        do {
            try await mail.client.deleteEvent(id: event.id, cancelMeeting: event.isMeeting && event.isOrganizer,
                                              at: url, credential: credential)
            events.removeAll { $0.id == event.id }
            await select(nil)
            show(notice: event.isMeeting && event.isOrganizer ? "Cancelled; everyone invited was told." : "Deleted.")
            await refresh()
        } catch {
            show(notice: describe(error))
        }
    }

    // MARK: - Answering invitations (M17)

    /// Whether the selected event is an invitation this user can answer.
    var canAnswerSelected: Bool {
        guard let event = selectedEvent else { return false }
        return event.isMeeting && !event.isOrganizer && !event.isCancelled
    }

    func answerSelected(_ answer: CalendarSOAP.Answer, note: String) async {
        guard let event = selectedEvent, let account,
              let (url, credential) = mail.connection(for: account.id) else { return }
        do {
            try await mail.client.answer(answer, to: event.id, note: note, at: url, credential: credential)
            show(notice: "\(answer.done). \(event.organizer.isEmpty ? "The organizer" : event.organizer) was told.")
            await refresh()
            if let fresh = events.first(where: { $0.id == event.id }) { await select(fresh) } else { await select(nil) }
        } catch {
            show(notice: describe(error))
        }
    }

    // MARK: - People and rooms

    /// Directory matches for the name being typed (the server searches it), plus inbox senders.
    func peopleSuggestions(for token: String, excluding typed: String) async -> [(name: String, address: String)] {
        let local = mail.recipientSuggestions(for: token, excluding: typed)
        guard token.count >= 2, let account, let (url, credential) = mail.connection(for: account.id) else { return local }
        let already = Set(Recipients.parse(typed).map { $0.lowercased() })
        let directory = ((try? await mail.client.resolveNames(token, at: url, credential: credential)) ?? [])
            .filter { !already.contains($0.address.lowercased()) }
        var seen = Set<String>()
        return (directory + local).filter { seen.insert($0.address.lowercased()).inserted }.prefix(6).map { $0 }
    }

    func loadRooms() async {
        guard rooms == nil, let account, let (url, credential) = mail.connection(for: account.id) else { return }
        rooms = (try? await mail.client.rooms(at: url, credential: credential)) ?? []
    }

    private func show(notice text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.notice == text { self?.notice = nil }
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? EWSError { return error.message(host: account?.host ?? "The server") }
        return error.localizedDescription
    }

    func select(_ event: CalendarEvent?) async {
        selectedEventID = event?.id
        guard let event, let account, let (url, credential) = mail.connection(for: account.id) else {
            detail = .idle
            return
        }
        detail = .loading
        do {
            let loaded = try await mail.client.eventDetail(id: event.id, at: url, credential: credential)
            guard selectedEventID == event.id else { return }
            detail = .loaded(loaded)
        } catch let error as EWSError {
            guard selectedEventID == event.id else { return }
            detail = .failed(error.message(host: account.host))
        } catch {
            guard selectedEventID == event.id else { return }
            detail = .failed(error.localizedDescription)
        }
    }
}
