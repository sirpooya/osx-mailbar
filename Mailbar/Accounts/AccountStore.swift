import Foundation
import Observation

/// The configured accounts. The list is configuration, so it lives in UserDefaults; each password
/// lives in the `PasswordStore` under the account's id, and the two are added and removed together.
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account]

    let passwords: any PasswordStore
    /// Nil in mock mode, so a QC run never writes to the real account list.
    private let defaults: UserDefaults?

    init(defaults: UserDefaults = .standard, passwords: any PasswordStore = KeychainPasswordStore()) {
        self.defaults = defaults
        self.passwords = passwords
        self.accounts = Self.load(from: defaults)
    }

    /// In memory only, for `MAILBAR_MOCK` and tests.
    init(inMemory accounts: [Account], passwords: any PasswordStore) {
        self.defaults = nil
        self.passwords = passwords
        self.accounts = accounts
    }

    /// False in mock mode and tests: nothing about the session is written to UserDefaults.
    var persists: Bool { defaults != nil }

    func account(_ id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    func hasPassword(_ id: UUID) -> Bool {
        passwords.hasPassword(for: id)
    }

    /// Adds or replaces the account. A nil or empty password keeps whatever is already saved,
    /// which is how editing an account without retyping its password works.
    func save(_ account: Account, password: String?) throws {
        if let password, !password.isEmpty {
            try passwords.setPassword(password, for: account.id, label: account.displayName)
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    /// Removes the account and its Keychain item together, so no password is left orphaned.
    func delete(_ id: UUID) {
        try? passwords.deletePassword(for: id)
        accounts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Keys.accounts)
        }
    }

    private static func load(from defaults: UserDefaults) -> [Account] {
        guard let data = defaults.data(forKey: Keys.accounts),
              let list = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
        return list
    }
}
