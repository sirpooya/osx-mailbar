import Foundation
import Security

/// Passwords for this account that some other app already saved in the login Keychain, so adding
/// the account does not mean typing the domain password again.
///
/// Adapted from osx-autoconnect/Sources/AutoConnectCore/Storage/LoginKeychain.swift. Outlook for
/// Mac and Safari file logins as `kSecClassInternetPassword` items keyed by server and account,
/// so a lookup by the user names Autodiscover would try finds them.
///
/// Two calls, on purpose:
/// - `items` reads attributes only. No password leaves the Keychain and macOS shows nothing, so
///   the sheet can say what it found before anyone decides to use it.
/// - `password` reads the one item the user picked. That is the call macOS guards with its own
///   "wants to use your confidential information" prompt, which the user answers, not this app.
///
/// Only items on the email's own domain are offered (`mail.example.com` for
/// `someone@example.com`): the short name alone matches logins on unrelated sites, and a
/// password for those is never the Exchange one. Chrome and Firefox keep their own stores and
/// are not found; that is a limitation, not something to work around.
protocol SavedLogins: Sendable {
    func items(forEmail email: String) -> [LoginKeychain.Item]
    func password(for item: LoginKeychain.Item) throws -> String
}

struct LoginKeychain: SavedLogins {
    /// One saved login. Carries no password.
    struct Item: Equatable, Hashable, Identifiable, Sendable {
        let server: String
        let account: String
        var id: String { "\(server)\u{1}\(account)" }
    }

    enum LookupError: Error, Equatable {
        case denied
        case notFound
        case status(OSStatus)

        var message: String {
            switch self {
            case .denied: return "Keychain Access did not allow Mailbar to read that password."
            case .notFound: return "That password is no longer in Keychain Access."
            case .status(let code): return "Keychain Access returned error \(code)."
            }
        }
    }

    func items(forEmail email: String) -> [Item] {
        guard let domain = Autodiscover.domain(of: email) else { return [] }
        var found: [(item: Item, modified: Date)] = []
        for account in Autodiscover.usernames(for: email) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let entries = result as? [[String: Any]] else { continue }
            for entry in entries {
                guard let server = entry[kSecAttrServer as String] as? String else { continue }
                let modified = entry[kSecAttrModificationDate as String] as? Date ?? .distantPast
                found.append((Item(server: server, account: account), modified))
            }
        }
        return Self.rank(found, domain: domain)
    }

    /// On the email's domain only, newest first, one row per server and account.
    static func rank(_ found: [(item: Item, modified: Date)], domain: String) -> [Item] {
        found
            .filter { isOnDomain($0.item.server, domain) }
            .sorted { $0.modified > $1.modified }
            .map(\.item)
            .reduce(into: [Item]()) { unique, item in
                if !unique.contains(item) { unique.append(item) }
            }
    }

    static func isOnDomain(_ server: String, _ domain: String) -> Bool {
        let server = server.lowercased(), domain = domain.lowercased()
        return server == domain || server.hasSuffix("." + domain)
    }

    /// Blocks while macOS asks permission, so call it off the main thread. "Always Allow" in that
    /// prompt is remembered for this exact build only; it hardly matters, since the password is
    /// copied into Mailbar's own item on Save and this is asked once per account.
    func password(for item: Item) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: item.server,
            kSecAttrAccount as String: item.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw LookupError.notFound
            }
            return password
        case errSecItemNotFound:
            throw LookupError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw LookupError.denied
        default:
            throw LookupError.status(status)
        }
    }
}

/// Mock mode: the sample account has one saved login, and nothing touches the real Keychain.
struct MockSavedLogins: SavedLogins {
    func items(forEmail email: String) -> [LoginKeychain.Item] {
        guard email.trimmingCharacters(in: .whitespaces).lowercased() == MockMode.accounts[0].email else { return [] }
        return [LoginKeychain.Item(server: "mail.example.com", account: MockMode.accounts[0].username)]
    }

    func password(for item: LoginKeychain.Item) throws -> String { "mock" }
}
