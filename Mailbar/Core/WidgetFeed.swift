import Foundation
import Observation
import WidgetKit

/// Writes the widgets' file (M26, `WidgetAgenda`) from what the Today refresh already fetched
/// (`MailStore.dayEvents`, filled by `EventReminders.update`), and nothing else: no request of
/// its own. Only start, end, title, location and the join link of today's remaining events.
///
/// The one sanctioned exception to "nothing from the mailbox on disk" besides attachments: the
/// file is overwritten on each change and deleted when the last account goes or "Show events in
/// widgets" is turned off.
@MainActor
final class WidgetFeed {
    private let store: MailStore
    private var lastWritten: WidgetAgenda?
    private var defaultsObserver: NSObjectProtocol?

    init(store: MailStore) {
        self.store = store
    }

    func start() {
        observe()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    /// Re-armed after each change, as `withObservationTracking` fires once.
    private func observe() {
        withObservationTracking {
            _ = store.dayEvents
            _ = store.joinLinks
            _ = store.accounts.accounts
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
    }

    func sync(now: Date = Date()) {
        let accounts = store.accounts.accounts.map(\.id)
        guard UserDefaults.standard.bool(forKey: Keys.widgetEvents), !accounts.isEmpty else {
            remove()
            return
        }
        // Nothing fetched yet: keep what is there rather than blanking the widget at launch.
        let loaded = accounts.filter { store.dayEvents[$0] != nil }
        guard !loaded.isEmpty else { return }
        let agenda = Self.agenda(from: loaded.flatMap { store.dayEvents[$0] ?? [] },
                                 links: store.joinLinks, now: now)
        guard agenda != lastWritten else { return }
        write(agenda)
    }

    /// Today's events not yet over, minus cancelled and declined ones, reduced to the five fields
    /// the widgets may know. Pure, for the tests.
    nonisolated static func agenda(from events: [CalendarEvent], links: [String: URL], now: Date,
                                   calendar: Calendar = .current) -> WidgetAgenda {
        let day = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? now
        let kept = events
            .filter { $0.end > now && $0.start < end && !$0.isCancelled && $0.myResponse != "Decline" }
            .sorted { $0.start < $1.start }
            .map { WidgetAgenda.Event(start: $0.start, end: $0.end, title: $0.subject,
                                      location: $0.location, joinURL: links[$0.id]) }
        return WidgetAgenda(day: day, timeZone: calendar.timeZone.identifier, events: kept)
    }

    private func write(_ agenda: WidgetAgenda) {
        guard let url = WidgetAgenda.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(agenda) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastWritten = agenda
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Deletes the file, once; the widgets then say to open Mailbar.
    private func remove() {
        guard let url = WidgetAgenda.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            lastWritten = nil
            return
        }
        try? FileManager.default.removeItem(at: url)
        lastWritten = nil
        WidgetCenter.shared.reloadAllTimelines()
    }
}
