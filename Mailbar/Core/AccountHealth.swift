import Foundation
import Observation

/// Per-account health the popover warns about and Settings shows (2026-11-16, after Outlook):
/// automatic replies left on, a password about to expire, a mailbox near its quota.
///
/// In memory only, like everything else read from the mailbox. Checked when the popover opens,
/// automatic replies at most every 10 minutes, the password and the size less often. An account
/// that is failing is skipped, and one whose password a check had rejected is left alone until
/// its settings change: every retry would be a failed logon against the domain's lockout counter.
@MainActor
@Observable
final class AccountHealth {
    static let shared = AccountHealth()

    /// Set once at launch (`StatusItemController`), for the accounts, the client and whether an
    /// account is healthy enough to ask.
    @ObservationIgnored weak var store: MailStore?

    private(set) var autoReplies: [UUID: AutoReplySettings] = [:]
    /// Absent: unknown, no expiry, or the server could not say. All three show nothing.
    private(set) var passwordExpiry: [UUID: Date] = [:]
    private(set) var quotas: [UUID: MailboxQuota] = [:]
    /// Accounts whose automatic replies are being turned off from the banner.
    private(set) var turningOff: Set<UUID> = []
    /// Banners the user dismissed this run, by `BannerKind` and account.
    private(set) var dismissed: Set<String> = []
    var bannerError: String?

    enum Check: CaseIterable {
        case autoReplies, password, quota

        var interval: TimeInterval {
            switch self {
            case .autoReplies: return 10 * 60
            case .password: return 24 * 60 * 60
            case .quota: return 60 * 60
            }
        }
    }

    static let warningDays = 14

    @ObservationIgnored private var lastChecked: [Check: [UUID: Date]] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Rejected by a check: the endpoint and user name it was rejected with.
    @ObservationIgnored private var parked: [UUID: String] = [:]

    func attach(_ store: MailStore) {
        self.store = store
    }

    // MARK: - Checking

    /// Runs whichever checks are due for every account that can be asked.
    func checkIfDue(now: Date = Date()) async {
        guard let store else { return }
        let accounts = store.accounts.accounts
        let live = Set(accounts.map(\.id))
        autoReplies = autoReplies.filter { live.contains($0.key) }
        passwordExpiry = passwordExpiry.filter { live.contains($0.key) }
        quotas = quotas.filter { live.contains($0.key) }

        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                if let fingerprint = parked[account.id] {
                    guard fingerprint != Self.fingerprint(account) else { continue }
                    parked[account.id] = nil
                }
                guard store.state(for: account.id).isHealthy, !inFlight.contains(account.id) else { continue }
                let due = Check.allCases.filter { check in
                    guard let last = lastChecked[check]?[account.id] else { return true }
                    return now.timeIntervalSince(last) >= check.interval
                }
                guard !due.isEmpty else { continue }
                inFlight.insert(account.id)
                group.addTask { await self.run(due, for: account, now: now) }
            }
        }
    }

    private func run(_ checks: [Check], for account: Account, now: Date) async {
        defer { inFlight.remove(account.id) }
        guard let store, let (url, credential) = store.connection(for: account.id) else { return }
        let client = store.client
        let address = account.email.trimmingCharacters(in: .whitespaces)
        for check in checks {
            do {
                switch check {
                case .autoReplies:
                    guard !address.isEmpty else { break }
                    autoReplies[account.id] = try await client.autoReplies(address: address, at: url, credential: credential)
                case .password:
                    guard !address.isEmpty else { break }
                    passwordExpiry[account.id] = try await client.passwordExpiration(address: address, at: url, credential: credential)
                case .quota:
                    quotas[account.id] = try await client.mailboxQuota(at: url, credential: credential)
                }
                lastChecked[check, default: [:]][account.id] = now
            } catch is CancellationError {
                return
            } catch EWSError.passwordRejected {
                parked[account.id] = Self.fingerprint(account)
                return
            } catch {
                // Not readable on this server (too old, or refused): show nothing, and do not
                // ask again before the check is next due. The activity log has the reason.
                lastChecked[check, default: [:]][account.id] = now
                switch check {
                case .autoReplies: autoReplies[account.id] = nil
                case .password: passwordExpiry[account.id] = nil
                case .quota: quotas[account.id] = nil
                }
            }
        }
    }

    private static func fingerprint(_ account: Account) -> String {
        "\(account.serverURL)|\(account.username)|\(account.email)"
    }

    // MARK: - Automatic replies

    /// Reads them fresh, for the sheet.
    func loadAutoReplies(for account: Account) async throws -> AutoReplySettings {
        let (client, url, credential, address) = try connection(account)
        let settings = try await client.autoReplies(address: address, at: url, credential: credential)
        autoReplies[account.id] = settings
        return settings
    }

    func saveAutoReplies(_ settings: AutoReplySettings, for account: Account) async throws {
        let (client, url, credential, address) = try connection(account)
        try await client.setAutoReplies(settings, address: address, at: url, credential: credential)
        autoReplies[account.id] = settings
        lastChecked[.autoReplies, default: [:]][account.id] = Date()
    }

    /// The banner's Turn Off: the settings as the server has them now, state Disabled, messages
    /// untouched.
    func turnOffAutoReplies(for account: Account) async {
        guard !turningOff.contains(account.id) else { return }
        turningOff.insert(account.id)
        defer { turningOff.remove(account.id) }
        do {
            var settings = try await loadAutoReplies(for: account)
            settings.state = .disabled
            try await saveAutoReplies(settings, for: account)
            bannerError = nil
        } catch is CancellationError {
        } catch {
            bannerError = store?.describe(error, accountID: account.id) ?? error.localizedDescription
        }
    }

    private func connection(_ account: Account) throws -> (EWSClient, URL, EWSCredential, String) {
        let address = account.email.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            throw EWSError.invalidResponse("This account has no e-mail address in Settings.")
        }
        guard let store, let (url, credential) = store.connection(for: account.id) else {
            throw EWSError.invalidResponse("This account has no saved password or server address.")
        }
        return (store.client, url, credential, address)
    }

    // MARK: - What to show

    enum BannerKind: String { case autoReplies, password, quota }

    struct Banner: Identifiable, Equatable {
        let kind: BannerKind
        let accountID: UUID
        let text: String
        var id: String { "\(kind.rawValue)-\(accountID)" }
    }

    func dismiss(_ banner: Banner) { dismissed.insert(banner.id) }

    /// The popover's banners, in account order. The account is named only when there are
    /// several, except where the sentence needs it.
    func banners(for accounts: [Account], now: Date = Date()) -> [Banner] {
        let named = accounts.count > 1
        var result: [Banner] = []
        for account in accounts {
            if autoReplies[account.id]?.isActive(at: now) == true {
                result.append(Banner(kind: .autoReplies, accountID: account.id,
                                     text: named ? "Automatic replies are on for \(account.displayName)."
                                                 : "Automatic replies are on."))
            }
            if let expiry = passwordExpiry[account.id],
               let text = Self.expiryText(expiry, account: account.displayName, now: now) {
                result.append(Banner(kind: .password, accountID: account.id, text: text))
            }
            if let quota = quotas[account.id], quota.isAlmostFull {
                result.append(Banner(kind: .quota, accountID: account.id,
                                     text: named ? "Mailbox almost full: \(account.displayName) uses \(quota.summary)."
                                                 : "Mailbox almost full: \(quota.summary) used."))
            }
        }
        return result.filter { !dismissed.contains($0.id) }
    }

    /// Whole days left, counted on the calendar: an expiry tomorrow morning is 1 day away.
    static func daysLeft(until date: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Nil outside the 14-day window, or once it has passed (the server will say so itself).
    static func expiryText(_ date: Date, account: String, now: Date = Date()) -> String? {
        guard date > now else { return nil }
        let days = daysLeft(until: date, now: now)
        guard days <= warningDays else { return nil }
        switch days {
        case ...0: return "Your password for \(account) expires today."
        case 1: return "Your password for \(account) expires tomorrow."
        default: return "Your password for \(account) expires in \(days) days."
        }
    }

    /// The account's Settings row, short: "1.8 GB of 2 GB. Password expires 21 Nov."
    func settingsSummary(for id: UUID) -> String? {
        var parts: [String] = []
        if let quota = quotas[id] { parts.append(quota.limit == nil ? "\(quota.summary) used." : "\(quota.summary).") }
        if let expiry = passwordExpiry[id], expiry > Date() {
            parts.append("Password expires \(expiry.formatted(.dateTime.day().month(.abbreviated))).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The automatic replies' messages as the sheet edits them: HTML on the server, plain text here.
enum AutoReplyText {
    /// Block ends and line breaks become new lines, tags go, entities are read. No WebKit, so
    /// nothing in the message can load anything.
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: "\r\n", with: "\n")
        // Set by a client that writes plain text: its line breaks are the paragraphs.
        guard text.contains("<") else { return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines) }
        // Source line breaks mean nothing in HTML.
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: #"(?is)<(head|style|script)\b.*?</\1>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|li|h[1-6]|tr|blockquote)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        // `<div><br></div>` is an empty paragraph: two breaks in a row. Keep one blank line.
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    /// One `<div>` per paragraph, `dir="rtl"` on the Persian ones, as the composer writes.
    static func html(fromPlainText text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "<html><body>" + ComposeHTML.html(from: text) + "</body></html>"
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"]
        for (entity, value) in named { out = out.replacingOccurrences(of: entity, with: value) }
        // Numeric ones, decimal and hex.
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let ns = out as NSString
            var rebuilt = ""
            var cursor = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                rebuilt += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    rebuilt.append(Character(scalar))
                } else {
                    rebuilt += ns.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            rebuilt += ns.substring(from: cursor)
            out = rebuilt
        }
        // Last, so "&amp;lt;" reads as the text "&lt;".
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
