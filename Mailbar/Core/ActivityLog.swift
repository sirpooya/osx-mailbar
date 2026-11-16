import Foundation
import Observation

/// One failed request: when, which EWS operation, which host, and the line the user was shown.
/// Never a request or reply body, a password, a header or an address.
struct ActivityEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let time: Date
    let operation: String
    let host: String
    let message: String
    /// Which account, as `ActivityLog.key`: a hash of the endpoint and user name, in memory.
    let accountKey: Int
}

/// The sync error log (2026-11-16): the last 100 failed requests per account, in memory only,
/// so it is gone at quit. Fed from `EWSClient`, where every request's errors pass, so nothing
/// that fails goes unlisted; shown from Settings, Accounts, "Activity Log...".
@MainActor
@Observable
final class ActivityLog {
    static let shared = ActivityLog()

    static let limit = 100

    /// Newest first, every account together.
    private(set) var entries: [ActivityEntry] = []

    init() {
        #if DEBUG
        if MockMode.current == .inbox { entries = Self.mockEntries() }
        #endif
    }

    func record(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        // At most `limit` per account: the oldest of that account's go first.
        var counts: [Int: Int] = [:]
        entries = entries.filter { item in
            counts[item.accountKey, default: 0] += 1
            return counts[item.accountKey]! <= Self.limit
        }
    }

    func entries(for account: Account) -> [ActivityEntry] {
        let key = Self.key(for: account)
        return entries.filter { $0.accountKey == key }
    }

    func clear(_ account: Account) {
        let key = Self.key(for: account)
        entries.removeAll { $0.accountKey == key }
    }

    // MARK: - Feeding it

    /// Called from `EWSClient` off the main actor. A cancelled request is not a failure.
    nonisolated static func report(_ error: Error, operation: String? = nil, body: Data? = nil,
                                   url: URL, username: String, at time: Date = Date()) {
        guard let entry = entry(for: error, operation: operation, body: body, url: url,
                                username: username, at: time) else { return }
        Task { @MainActor in ActivityLog.shared.record(entry) }
    }

    nonisolated static func entry(for error: Error, operation: String?, body: Data?,
                                  url: URL, username: String, at time: Date) -> ActivityEntry? {
        if error is CancellationError { return nil }
        if let error = error as? URLError, error.code == .cancelled { return nil }
        let host = url.host ?? "the server"
        let text = (error as? EWSError)?.message(host: host) ?? error.localizedDescription
        return ActivityEntry(time: time,
                             operation: operation ?? body.map(Self.operation(in:)) ?? "Request",
                             host: host,
                             message: scrub(text),
                             accountKey: key(url: url, username: username))
    }

    /// The account a request belongs to, without keeping its address: the hash of its endpoint
    /// and user name. Hashing is seeded per process, which suits a log that dies with it.
    nonisolated static func key(url: URL, username: String) -> Int {
        var hasher = Hasher()
        hasher.combine(url.absoluteString.lowercased())
        hasher.combine(username.lowercased())
        return hasher.finalize()
    }

    nonisolated static func key(for account: Account) -> Int {
        guard let url = account.endpoint else { return 0 }
        return key(url: url, username: account.username)
    }

    /// The operation's element name, the first one in the SOAP body: "FindItem", "GetFolder".
    nonisolated static func operation(in body: Data) -> String {
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        guard let open = text.range(of: "Body>") else { return "Request" }
        let rest = text[open.upperBound...]
        guard let tag = rest.range(of: #"<([A-Za-z]+:)?([A-Za-z]+)"#, options: .regularExpression) else { return "Request" }
        var name = String(rest[tag].dropFirst())
        if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        return name.hasSuffix("Request") && name != "Request" ? String(name.dropLast("Request".count)) : name
    }

    /// The error of a reply in which nothing succeeded, or nil. A reply where some items failed
    /// and others did not (a folder the mailbox lacks) is not a failed request.
    nonisolated static func responseError(in data: Data) -> Error? {
        let marker = Data(#"ResponseClass="Error""#.utf8)
        guard data.range(of: marker) != nil,
              data.range(of: Data(#"ResponseClass="Success""#.utf8)) == nil,
              data.range(of: Data(#"ResponseClass="Warning""#.utf8)) == nil,
              let root = try? XMLTree.parse(data) else { return nil }
        do {
            try EWSResponse.checkSingle(root)
            return nil
        } catch {
            return error
        }
    }

    /// The server's own words can name a mailbox; addresses never reach the log.
    nonisolated static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: #"[^\s<>"'()]+@[^\s<>"'()]+"#, with: "(address)", options: .regularExpression)
    }

    // MARK: - Copy

    /// What Copy puts on the clipboard: one line per entry, oldest last.
    static func text(of entries: [ActivityEntry]) -> String {
        let format = Date.FormatStyle(date: .numeric, time: .standard)
        return entries.map { "\($0.time.formatted(format))  \($0.operation)  \($0.host)  \($0.message)" }
            .joined(separator: "\n")
    }

    #if DEBUG
    private static func mockEntries() -> [ActivityEntry] {
        let work = key(for: MockMode.accounts[0])
        let team = key(for: MockMode.accounts[1])
        let now = Date()
        return [
            ActivityEntry(time: now.addingTimeInterval(-4 * 60), operation: "GetStreamingEvents",
                          host: "mail.example.com",
                          message: "The server did not answer. If mail.example.com is internal, check the VPN.",
                          accountKey: work),
            ActivityEntry(time: now.addingTimeInterval(-38 * 60), operation: "FindItem", host: "mail.example.com",
                          message: "The server name does not resolve. If mail.example.com is internal, check the VPN.",
                          accountKey: work),
            ActivityEntry(time: now.addingTimeInterval(-41 * 60), operation: "GetFolder", host: "mail.example.com",
                          message: "The server name does not resolve. If mail.example.com is internal, check the VPN.",
                          accountKey: work),
            ActivityEntry(time: now.addingTimeInterval(-3 * 3600), operation: "GetUserAvailability",
                          host: "mail.example.com", message: "Exchange had an internal error (500).",
                          accountKey: work),
            ActivityEntry(time: now.addingTimeInterval(-26 * 60), operation: "Subscribe", host: "exchange.example.org",
                          message: "The mailbox is busy. Try again later. (ErrorServerBusy)",
                          accountKey: team),
        ]
    }
    #endif
}
