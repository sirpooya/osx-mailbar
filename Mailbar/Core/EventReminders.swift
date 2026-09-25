import Foundation
import UserNotifications

/// Event reminders (M18): one plain notification at each event's reminder time, and nothing
/// else. No snooze, no buttons (the user's call, 2026-09-25). Clicking it opens the calendar on
/// the event; once the event is over, the notification is taken out of Notification Center.
///
/// The next day of events is read after polls (at most every five minutes, or at once when the
/// stream reports a calendar change) and handed to macOS as scheduled notifications, so a
/// reminder still arrives on time while the app sits idle. macOS keeps scheduled and delivered
/// notifications itself; with notification details off, a reminder says only "Event".
@MainActor
final class EventReminders {
    private let mail: MailStore
    private let center = UNUserNotificationCenter.current()
    private var lastUpdate: Date?

    nonisolated static let prefix = "reminder-"
    static let lookAhead: TimeInterval = 26 * 3600
    nonisolated static let accountKey = "reminderAccount"
    nonisolated static let eventKey = "reminderEvent"

    init(mail: MailStore) {
        self.mail = mail
    }

    struct Planned: Equatable, Sendable {
        let identifier: String
        let fireDate: Date
        let title: String
        let body: String
        let eventID: String
        let accountID: UUID
        let eventEnd: Date
    }

    /// Which reminders to schedule: events with a reminder, still to come, not cancelled, not
    /// declined, and whose reminder time has not already passed. Pure, so it can be tested.
    nonisolated static func plan(_ events: [CalendarEvent], account: Account, now: Date, showDetails: Bool) -> [Planned] {
        events.compactMap { event in
            guard let minutes = event.reminderMinutes, !event.isCancelled, event.myResponse != "Decline" else { return nil }
            let fire = event.start.addingTimeInterval(-TimeInterval(minutes * 60))
            guard fire > now else { return nil }
            let time = event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)
            let body = [time, event.location].filter { !$0.isEmpty }.joined(separator: ", ")
            // The event's own id and start: stable across launches, so a reschedule replaces the
            // same request rather than adding a second one.
            return Planned(identifier: "\(prefix)\(event.id)-\(Int(event.start.timeIntervalSince1970))",
                           fireDate: fire,
                           title: showDetails ? event.subject : "Event",
                           body: showDetails ? body : "In \(account.displayName)",
                           eventID: event.id, accountID: account.id, eventEnd: event.end)
        }
    }

    /// Reads the next day of events once and uses it twice: the popover's Today strip (M19) and
    /// the scheduled reminders (M18). `force` skips the five-minute throttle, for when the stream
    /// has just reported a calendar change. `schedule` is false in sample mode, which must never
    /// put real notifications on the Mac.
    func update(force: Bool = false, schedule: Bool = true) async {
        let defaults = UserDefaults.standard
        if !force, let lastUpdate, Date().timeIntervalSince(lastUpdate) < 300 { return }
        lastUpdate = Date()

        let now = Date()
        var planned: [Planned] = []
        for account in mail.accounts.accounts {
            guard let (url, credential) = mail.connection(for: account.id),
                  let events = try? await mail.client.calendarEvents(from: now.addingTimeInterval(-12 * 3600),
                                                                    to: now.addingTimeInterval(Self.lookAhead),
                                                                    at: url, credential: credential) else { continue }
            await mail.setToday(TodayAgenda.rest(of: events, now: now), for: account.id)
            planned += Self.plan(events, account: account, now: now,
                                 showDetails: defaults.bool(forKey: Keys.notificationDetails))
        }

        guard schedule else { return }
        guard defaults.bool(forKey: Keys.eventReminders) else {
            await clearAll()
            return
        }

        // Replace the pending set: moved, deleted or declined events lose their reminder.
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for reminder in planned {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.userInfo = [Self.accountKey: reminder.accountID.uuidString, Self.eventKey: reminder.eventID,
                                "end": reminder.eventEnd.timeIntervalSince1970]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireDate.timeIntervalSinceNow),
                                                            repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
        }

        // Reminders for events that are over leave Notification Center.
        let delivered = await center.deliveredNotifications()
        let over = delivered.filter { notification in
            guard notification.request.identifier.hasPrefix(Self.prefix),
                  let end = notification.request.content.userInfo["end"] as? TimeInterval else { return false }
            return end < now.timeIntervalSince1970
        }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: over)
    }

    private func clearAll() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }
}
