import Foundation
import Observation

/// What the calendar window shows (M15): which account, which days, and the events on them.
///
/// Only the visible range is fetched, into memory, and replaced on every refresh. Nothing is
/// written to disk, the same rule as mail.
@MainActor
@Observable
final class CalendarStore {
    enum Mode: String, CaseIterable, Identifiable {
        case day, workWeek, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: return "Day"
            case .workWeek: return "Work week"
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

    /// A newer refresh supersedes an older one still in flight.
    @ObservationIgnored private var generation = 0

    init(mail: MailStore) {
        self.mail = mail
        self.mode = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.calendarMode) ?? "") ?? .week
        self.anchor = Date()
        self.accountID = mail.selectedAccount?.id
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
    var visibleDays: [Date] {
        let calendar = self.calendar
        let day = calendar.startOfDay(for: anchor)
        switch mode {
        case .day:
            return [day]
        case .week, .workWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            return mode == .week ? week : week.filter { workDays.contains(calendar.component(.weekday, from: $0)) }
        case .month:
            return monthGridDays
        }
    }

    /// Always exactly 42 days, six weeks from the week the anchor's month starts in. The month
    /// grid reads these, never `visibleDays`: switching from Month to Week renders the month grid
    /// one last time after `mode` has changed, and indexing a 7-day list as 42 crashed the app
    /// (2026-09-25).
    var monthGridDays: [Date] {
        let calendar = self.calendar
        let day = calendar.startOfDay(for: anchor)
        let monthStart = calendar.dateInterval(of: .month, for: day)?.start ?? day
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let days = (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
        return days.count == 42 ? days : (0..<42).map { gridStart.addingTimeInterval(TimeInterval($0) * 86_400) }
    }

    var visibleRange: (start: Date, end: Date) {
        let days = visibleDays
        let start = days.first ?? calendar.startOfDay(for: anchor)
        let end = days.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? start
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
        case .week, .workWeek:
            let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
            let year = last.formatted(style().year())
            if sameMonth {
                return "\(first.formatted(style().month(.wide))) \(first.formatted(style().day()))\u{2013}\(last.formatted(style().day())), \(year)"
            }
            return "\(first.formatted(style().month(.wide).day())) to \(last.formatted(style().month(.wide).day())), \(year)"
        }
    }

    func goToday() {
        anchor = Date()
    }

    func step(forward: Bool) {
        let sign = forward ? 1 : -1
        let calendar = self.calendar
        switch mode {
        case .day: anchor = calendar.date(byAdding: .day, value: sign, to: anchor) ?? anchor
        case .week, .workWeek: anchor = calendar.date(byAdding: .weekOfYear, value: sign, to: anchor) ?? anchor
        case .month: anchor = calendar.date(byAdding: .month, value: sign, to: anchor) ?? anchor
        }
    }

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
        let range = visibleRange
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
