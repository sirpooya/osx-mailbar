import Foundation
import Security

/// Generic-password Keychain items under one service name, one item per account.
///
/// Copied unchanged from osx-jirabar/Jirabar/Core/KeychainStore.swift, which is the minimal
/// generic form of osx-autoconnect's tested store. Mailbar files one item per mail account under
/// the service `in.pooya.mailbar.account`, keyed by the account's UUID.
///
/// Rules carried over:
/// - Secrets live only here, `kSecAttrAccessibleWhenUnlocked`. Never plist or UserDefaults.
/// - The service name is a storage address, not a label. Renaming it strands every item.
/// - Callers use a secret immediately and do not retain it.
/// - Tests use a throwaway service, `"<bundle id>.tests.\(UUID().uuidString)"`, and call
///   `deleteAll()` in `tearDown`, so they never touch the shipping app's items.
/// - Keep one signing identity. A Keychain ACL trusts one exact code signature, and every ad-hoc
///   rebuild produces a new one, which re-prompts on every launch.
public struct KeychainStore: Sendable {

    public enum StoreError: Error, CustomStringConvertible {
        case notFound
        case unexpected(OSStatus)

        public var description: String {
            switch self {
            case .notFound:
                return "That item is no longer in the Keychain."
            case .unexpected(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status): \(message ?? "unknown")."
            }
        }
    }

    /// The service every item is filed under, for example "in.pooya.mailbar.account".
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - Reading

    /// Every account name under this service. Attributes only: no secret is read.
    public func accounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Fetches one secret. Use it immediately and do not retain it.
    public func secret(for account: String) throws -> Data {
        var query = itemQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw StoreError.notFound }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
        guard let data = result as? Data else { throw StoreError.notFound }
        return data
    }

    // MARK: - Writing

    /// Adds the item, or replaces the secret of an existing one.
    /// `label` is the human-readable name shown in Keychain Access. Never put the secret in it.
    public func set(_ secret: Data, for account: String, label: String? = nil) throws {
        var attributes = itemQuery(account: account)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        if let label { attributes[kSecAttrLabel as String] = label }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                itemQuery(account: account) as CFDictionary,
                [kSecValueData as String: secret] as CFDictionary
            )
            guard update == errSecSuccess else { throw StoreError.unexpected(update) }
            return
        }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
    }

    /// Deletes one item. Deleting something already gone is not an error.
    public func delete(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw StoreError.unexpected(status)
    }

    /// Removes every item this store owns. For tests and a "reset" action.
    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw StoreError.unexpected(status)
    }
}
