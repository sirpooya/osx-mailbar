import Foundation

/// Every UserDefaults key the app owns, in one place, with the defaults registered at launch.
///
/// `UserDefaults.integer` answers `0` for an absent key, so any default that is not `0` or `false`
/// has to be registered or the first launch reads the wrong thing.
///
/// The `mailbar.` prefix is a storage address, not a label. Renaming it strands every setting.
/// Nothing from the mailbox is ever stored here: only configuration.
enum Keys {
    /// The account list, JSON. No passwords: those are in the Keychain.
    static let accounts = "mailbar.accounts"
    static let pollMinutes = "mailbar.pollMinutes"
    /// The account whose inbox the popover shows, when there is more than one.
    static let selectedAccount = "mailbar.selectedAccount"

    static let pollMinuteChoices = [1, 2, 3, 5, 10]

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            pollMinutes: 2,
        ])
    }

    /// Clamped so a hand-edited plist cannot make the app poll every second.
    static func pollInterval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = min(max(defaults.integer(forKey: pollMinutes), 1), 10)
        return TimeInterval(minutes * 60)
    }
}
