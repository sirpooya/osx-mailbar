import AppIntents
import Foundation
import Observation

/// Profiles linked to Focus (2026-11-16, after Outlook): a "Mailbar" Focus filter in System
/// Settings, Focus, Focus Filters, with the accounts to keep. While that Focus is on, the other
/// accounts' new-mail notifications are silenced and their unread count leaves the menu bar.
/// Their mail is still fetched and shown in the popover.
///
/// The active filter is held in memory only. macOS keeps the filter's own configuration and
/// calls `perform()` whenever the Focus turns on or off; at launch the current one is read back.
@MainActor
@Observable
final class FocusFilterState {
    static let shared = FocusFilterState()

    /// Nil when no Mailbar filter is active: every account counts.
    var keptAccounts: Set<UUID>?

    func allows(_ id: UUID) -> Bool {
        keptAccounts?.contains(id) ?? true
    }

    /// The per-account unread counts with the silenced accounts left out.
    func filter(_ unread: [UUID: Int]) -> [UUID: Int] {
        guard let keptAccounts else { return unread }
        return unread.filter { keptAccounts.contains($0.key) }
    }

    /// An empty or missing list is no filter: a Focus that kept nothing would hide all mail,
    /// which no one sets up on purpose, and it is also what macOS sends when the Focus ends.
    nonisolated static func kept(from accounts: [MailbarAccountEntity]?) -> Set<UUID>? {
        guard let accounts, !accounts.isEmpty else { return nil }
        return Set(accounts.map(\.id))
    }

    /// The filter of the Focus that is on now, if any, for a launch in the middle of one.
    func loadCurrent() {
        #if DEBUG
        if let kept = Self.qcKept { keptAccounts = kept; return }
        #endif
        Task {
            guard let current = try? await MailbarFocusFilter.current else { return }
            keptAccounts = Self.kept(from: current.accounts)
        }
    }

    #if DEBUG
    /// `--focus-keep=0` (DEBUG): the filter as if a Focus kept only the account at that index.
    private static var qcKept: Set<UUID>? {
        guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--focus-keep=") }),
              let index = Int(raw.dropFirst("--focus-keep=".count)) else { return nil }
        let accounts = MockMode.current != nil ? MockMode.accounts : FocusAccounts.all()
        return accounts.indices.contains(index) ? [accounts[index].id] : nil
    }
    #endif
}

/// The account list as the filter's picker reads it: straight from UserDefaults (or the mock
/// accounts), since the system may ask before the app's stores exist.
enum FocusAccounts {
    static func all() -> [Account] {
        if MockMode.current != nil { return MockMode.accounts }
        guard let data = UserDefaults.standard.data(forKey: Keys.accounts),
              let list = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
        return list
    }
}

struct MailbarAccountEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mail Account")
    static let defaultQuery = MailbarAccountQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ account: Account) {
        id = account.id
        name = account.displayName
    }
}

struct MailbarAccountQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [MailbarAccountEntity] {
        FocusAccounts.all().filter { identifiers.contains($0.id) }.map(MailbarAccountEntity.init)
    }

    func suggestedEntities() async throws -> [MailbarAccountEntity] {
        FocusAccounts.all().map(MailbarAccountEntity.init)
    }
}

struct MailbarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Mailbar"
    static let description: IntentDescription? = IntentDescription(
        "Choose the mail accounts to keep. The others stay quiet and leave the menu bar count while this Focus is on.")

    @Parameter(title: "Accounts to keep")
    var accounts: [MailbarAccountEntity]?

    var displayRepresentation: DisplayRepresentation {
        let names = (accounts ?? []).map(\.name)
        return DisplayRepresentation(title: "Mailbar",
                                     subtitle: names.isEmpty ? "All accounts" : "Only \(names.joined(separator: ", "))")
    }

    func perform() async throws -> some IntentResult {
        let kept = FocusFilterState.kept(from: accounts)
        await MainActor.run { FocusFilterState.shared.keptAccounts = kept }
        return .result()
    }
}
