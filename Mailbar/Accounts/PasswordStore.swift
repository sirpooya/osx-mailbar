import Foundation

/// Where account passwords live. The Keychain in the shipping app; memory in mock mode and tests.
///
/// A caller reads a password, uses it for one request and lets it go. Nothing holds one.
protocol PasswordStore: Sendable {
    func password(for account: UUID) -> String?
    /// Whether one is saved, without reading it. Views ask this; only requests read the secret.
    func hasPassword(for account: UUID) -> Bool
    func setPassword(_ password: String, for account: UUID, label: String) throws
    func deletePassword(for account: UUID) throws
}

struct KeychainPasswordStore: PasswordStore {
    /// A storage address, not a label. Renaming it strands every saved password.
    static let service = "in.pooya.mailbar.account"

    private let keychain: KeychainStore

    init(service: String = KeychainPasswordStore.service) {
        keychain = KeychainStore(service: service)
    }

    func password(for account: UUID) -> String? {
        guard let data = try? keychain.secret(for: account.uuidString) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword(for account: UUID) -> Bool {
        (try? keychain.accounts())?.contains(account.uuidString) ?? false
    }

    func setPassword(_ password: String, for account: UUID, label: String) throws {
        try keychain.set(Data(password.utf8), for: account.uuidString, label: "Mailbar: \(label)")
    }

    func deletePassword(for account: UUID) throws {
        try keychain.delete(account: account.uuidString)
    }

    func deleteAll() throws {
        try keychain.deleteAll()
    }
}

/// Mock mode and tests. Nothing here outlives the process.
final class MemoryPasswordStore: PasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String]

    init(_ passwords: [UUID: String] = [:]) {
        self.passwords = passwords
    }

    func password(for account: UUID) -> String? {
        lock.withLock { passwords[account] }
    }

    func hasPassword(for account: UUID) -> Bool {
        password(for: account) != nil
    }

    func setPassword(_ password: String, for account: UUID, label: String) throws {
        lock.withLock { passwords[account] = password }
    }

    func deletePassword(for account: UUID) throws {
        _ = lock.withLock { passwords.removeValue(forKey: account) }
    }
}
