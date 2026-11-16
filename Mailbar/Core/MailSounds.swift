import AppKit
import UserNotifications

/// The new-mail and mail-sent sounds (M26), chosen in Settings, General: None, the Mac's alert
/// sound (new mail only, what notifications always played), or one of macOS's own sounds in
/// /System/Library/Sounds. Nothing is bundled or copied.
enum MailSounds {
    static let none = "none"
    /// The Mac's alert sound: `UNNotificationSound.default` on a banner, `NSSound.beep` alone.
    static let systemDefault = "default"

    /// "Basso", "Blow", ... "Tink": whatever this Mac ships, sorted.
    static let systemNames: [String] = {
        let folder = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["aiff", "aif", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }()

    static var newMail: String {
        UserDefaults.standard.string(forKey: Keys.newMailSound) ?? systemDefault
    }

    static var sent: String {
        UserDefaults.standard.string(forKey: Keys.sentSound) ?? none
    }

    /// The sound a new-mail banner carries, or nil for silence.
    static func notificationSound(for choice: String) -> UNNotificationSound? {
        switch choice {
        case none: return nil
        case systemDefault: return .default
        default: return UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(choice).aiff"))
        }
    }

    /// Plays a choice directly: the sent sound, the new-mail sound while banners are off, and
    /// the preview when a sound is picked in Settings.
    @MainActor
    static func play(_ choice: String) {
        switch choice {
        case none: return
        case systemDefault: NSSound.beep()
        default: NSSound(named: NSSound.Name(choice))?.play()
        }
    }
}

/// What the menu bar number counts (M26, Settings, General): every account's unread Inbox mail
/// (the default and what it always showed), only the account the popover shows, or nothing.
enum MenuBarCount: String, CaseIterable, Identifiable {
    case allAccounts = "all"
    case selectedAccount = "selected"
    case off = "off"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allAccounts: return "All accounts"
        case .selectedAccount: return "Selected account"
        case .off: return "Off"
        }
    }

    static var current: MenuBarCount {
        MenuBarCount(rawValue: UserDefaults.standard.string(forKey: Keys.menuBarCount) ?? "") ?? .allAccounts
    }

    /// The number beside the icon. Pure over the per-account counts, for the tests.
    func count(unread: [UUID: Int], selected: UUID?) -> Int {
        switch self {
        case .allAccounts: return unread.values.reduce(0, +)
        case .selectedAccount: return selected.flatMap { unread[$0] } ?? 0
        case .off: return 0
        }
    }
}
