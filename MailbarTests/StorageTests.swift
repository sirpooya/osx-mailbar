import Foundation
import Testing
@testable import Mailbar

/// Every test gets a throwaway Keychain service and defaults suite, so nothing here can touch the
/// app's real accounts.
@MainActor
@Suite(.serialized) struct StorageTests {
    private func throwawayDefaults() -> UserDefaults {
        let name = "in.pooya.mailbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func throwawayKeychain() -> KeychainPasswordStore {
        KeychainPasswordStore(service: "in.pooya.mailbar.tests.\(UUID().uuidString)")
    }

    @Test func keychainRoundTrip() throws {
        let store = throwawayKeychain()
        defer { try? store.deleteAll() }
        let id = UUID()

        #expect(store.password(for: id) == nil)
        #expect(!store.hasPassword(for: id))
        try store.setPassword("first", for: id, label: "Test")
        #expect(store.password(for: id) == "first")
        #expect(store.hasPassword(for: id))
        try store.setPassword("second", for: id, label: "Test")
        #expect(store.password(for: id) == "second")
        try store.deletePassword(for: id)
        #expect(store.password(for: id) == nil)
    }

    @Test func accountsPersistWithoutTheirPasswords() throws {
        let defaults = throwawayDefaults()
        let passwords = MemoryPasswordStore()
        let store = AccountStore(defaults: defaults, passwords: passwords)
        let account = Account(label: "Work", email: "someone@example.com",
                              serverURL: "https://mail.example.com/EWS/Exchange.asmx", username: "someone")

        try store.save(account, password: "secret-value")

        let reloaded = AccountStore(defaults: defaults, passwords: passwords)
        #expect(reloaded.accounts == [account])
        #expect(reloaded.hasPassword(account.id))
        let raw = try #require(defaults.data(forKey: Keys.accounts))
        #expect(!String(decoding: raw, as: UTF8.self).contains("secret-value"))
    }

    @Test func editingWithoutAPasswordKeepsTheSavedOne() throws {
        let passwords = MemoryPasswordStore()
        let store = AccountStore(defaults: throwawayDefaults(), passwords: passwords)
        var account = Account(label: "Work", serverURL: "mail.example.com", username: "someone")
        try store.save(account, password: "kept")

        account.label = "Renamed"
        try store.save(account, password: nil)

        #expect(store.accounts.map(\.label) == ["Renamed"])
        #expect(passwords.password(for: account.id) == "kept")
    }

    @Test func deletingAnAccountRemovesItsPassword() throws {
        let passwords = MemoryPasswordStore()
        let store = AccountStore(defaults: throwawayDefaults(), passwords: passwords)
        let account = Account(label: "Work", serverURL: "mail.example.com", username: "someone")
        try store.save(account, password: "gone")

        store.delete(account.id)

        #expect(store.accounts.isEmpty)
        #expect(passwords.password(for: account.id) == nil)
    }
}

@Suite struct LoginKeychainTests {
    private typealias Item = LoginKeychain.Item

    @Test func onlyLoginsOnTheEmailDomainAreOffered() {
        #expect(LoginKeychain.isOnDomain("mail.example.com", "example.com"))
        #expect(LoginKeychain.isOnDomain("Example.com", "example.com"))
        #expect(!LoginKeychain.isOnDomain("example.com.evil.test", "example.com"))
        #expect(!LoginKeychain.isOnDomain("notexample.com", "example.com"))
    }

    @Test func newestFirstOneRowPerLogin() {
        let mail = Item(server: "mail.example.com", account: "some.one")
        let owa = Item(server: "owa.example.com", account: "some.one@example.com")
        let elsewhere = Item(server: "shop.example.net", account: "some.one")
        let ranked = LoginKeychain.rank([(mail, .distantPast),
                                         (elsewhere, .now),
                                         (owa, Date(timeIntervalSince1970: 100)),
                                         (mail, Date(timeIntervalSince1970: 50))],
                                        domain: "example.com")
        #expect(ranked == [owa, mail])
    }

    @Test func mockModeOffersOneLoginForTheSampleAccount() {
        #expect(MockSavedLogins().items(forEmail: MockMode.accounts[0].email).count == 1)
        #expect(MockSavedLogins().items(forEmail: "someone@example.org").isEmpty)
    }
}
