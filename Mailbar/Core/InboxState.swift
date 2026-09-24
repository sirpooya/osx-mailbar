import Foundation

/// What one account's inbox is showing. The failures are separate cases with separate views and
/// separate actions, and there is no path from any of them to `.empty`.
///
/// This enum is how the rule in AGENTS.md is enforced: an error can never be rendered as an
/// empty inbox. A new failure gets a case here, not a silent fallthrough.
enum InboxState: Equatable, Sendable {
    /// First load, nothing to show yet. Later polls keep the rows on screen while they run.
    case loading
    /// At least one message. Never used for zero.
    case messages([MailMessage])
    /// The inbox genuinely holds nothing. The only case that shows the empty view.
    case empty
    /// The account is configured but its Keychain item is missing.
    case needsPassword
    /// 401 or a refused challenge. Offers Settings.
    case passwordRejected
    /// Cannot reach the server. Offers a retry, and says the VPN out loud.
    case unreachable(String)
    /// Anything else, in the server's own words.
    case failed(String)

    var messages: [MailMessage] {
        if case .messages(let list) = self { return list }
        return []
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Whether the unread count from this account can be trusted and shown.
    var isHealthy: Bool {
        switch self {
        case .messages, .empty, .loading: return true
        case .needsPassword, .passwordRejected, .unreachable, .failed: return false
        }
    }

    static func from(_ messages: [MailMessage]) -> InboxState {
        messages.isEmpty ? .empty : .messages(messages)
    }

    static func from(_ error: EWSError, host: String) -> InboxState {
        switch error {
        case .passwordRejected:
            return .passwordRejected
        case .unreachable(let reason):
            return .unreachable(reason)
        case .tlsFailure, .notEWS, .server, .invalidResponse, .unexpected:
            return .failed(error.message(host: host))
        }
    }
}
