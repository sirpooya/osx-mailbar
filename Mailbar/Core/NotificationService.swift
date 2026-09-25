import Foundation
import UserNotifications

/// New-mail notifications (M7). Adapted from osx-jirabar's service.
///
/// - Permission is asked for once an account exists, never at a bare first launch.
/// - The first poll after launch only records what is already there, so starting the app never
///   produces a wall of notifications for mail that was sitting in the inbox (see `NewMailTracker`).
/// - Past `individualLimit` at once, the rest collapse into one summary.
/// - A notification is withdrawn as soon as its message is read, archived or deleted, here or
///   anywhere else, so Notification Center does not keep mail that has already been dealt with.
///
/// Privacy: macOS itself keeps delivered notifications in Notification Center, which is on disk
/// and outside this app's control. That is the reason for the details switch in Settings: off, a
/// notification says only which account has new mail, and carries no sender or subject at all.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the account and message when the user clicks a notification.
    var onOpenMessage: ((UUID, String) -> Void)?
    /// Called with the account and event when the user clicks an event reminder (M18).
    var onOpenEvent: ((UUID, String) -> Void)?

    private static let individualLimit = 4

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let accountKey = "accountID"
    private nonisolated static let messageKey = "messageID"

    /// Identifiers delivered this session, by message id, so they can be withdrawn.
    private var delivered: [String: String] = [:]

    func configure() {
        center.delegate = self
    }

    /// Asks once. macOS remembers a denial, so re-asking does nothing and shows nothing.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func notify(_ messages: [MailMessage], account: Account, showDetails: Bool) {
        guard !messages.isEmpty else { return }

        for message in messages.prefix(Self.individualLimit) {
            let content = UNMutableNotificationContent()
            if showDetails {
                content.title = message.senderName
                content.subtitle = message.subject
                content.body = message.preview
            } else {
                content.title = "New mail"
                content.body = "A new message in \(account.displayName)."
            }
            content.sound = .default
            content.threadIdentifier = account.id.uuidString
            content.userInfo = [Self.accountKey: account.id.uuidString, Self.messageKey: message.id]
            let identifier = "mail-\(UUID().uuidString)"
            delivered[message.id] = identifier
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }

        let overflow = messages.count - Self.individualLimit
        guard overflow > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = overflow == 1 ? "1 more new message" : "\(overflow) more new messages"
        content.body = "In \(account.displayName). Open Mailbar to see them."
        content.sound = .default
        content.threadIdentifier = account.id.uuidString
        center.add(UNNotificationRequest(identifier: "mail-more-\(UUID().uuidString)",
                                         content: content, trigger: nil))
    }

    /// Withdraws the notification of every message not in `stillUnread`: read, archived or
    /// deleted, in this app or in any other client.
    func withdraw(except stillUnread: Set<String>) {
        let gone = delivered.filter { !stillUnread.contains($0.key) }
        guard !gone.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: Array(gone.values))
        for id in gone.keys { delivered[id] = nil }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// An accessory app is rarely frontmost, but when it is the banner should still show.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let event = info[EventReminders.eventKey] as? String,
           let account = (info[EventReminders.accountKey] as? String).flatMap(UUID.init(uuidString:)) {
            await MainActor.run { self.onOpenEvent?(account, event) }
            return
        }
        let account = (info[Self.accountKey] as? String).flatMap(UUID.init(uuidString:))
        let message = info[Self.messageKey] as? String
        await MainActor.run {
            guard let account, let message else { return }
            self.onOpenMessage?(account, message)
        }
    }
}

/// Decides which messages in a poll are new, in memory only.
///
/// The first successful poll per account is a baseline: everything in it is marked seen and
/// nothing is announced. After that, a message is new when its id has not been seen this session
/// and it is unread. Ids are never persisted, so after a relaunch the first poll is again a
/// baseline rather than a replay of the whole inbox.
struct NewMailTracker {
    private var seen: [UUID: Set<String>] = [:]

    mutating func newMessages(in messages: [MailMessage], account: UUID) -> [MailMessage] {
        let ids = Set(messages.map(\.id))
        guard let known = seen[account] else {
            seen[account] = ids
            return []
        }
        seen[account] = known.union(ids)
        return messages.filter { !$0.isRead && !known.contains($0.id) }
    }

    mutating func forget(_ account: UUID) {
        seen[account] = nil
    }
}
