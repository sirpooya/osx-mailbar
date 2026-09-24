import Foundation

/// One Exchange mailbox, as the user typed it into Settings. Mirrors Outlook for Mac's Exchange
/// account sheet, minus the directory server, which only matters for composing.
///
/// No secret lives here. The password is in the Keychain under `id`, so this value can be
/// encoded into UserDefaults as it is.
struct Account: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// "Account description" in Outlook. Free text, shown in the account menu.
    var label: String
    var fullName: String
    var email: String
    /// The full EWS endpoint, `https://host/EWS/Exchange.asmx`.
    var serverURL: String
    /// Whatever the server accepts: a short name, `DOMAIN\name`, or `name@domain`.
    var username: String

    init(id: UUID = UUID(),
         label: String = "",
         fullName: String = "",
         email: String = "",
         serverURL: String = "",
         username: String = "") {
        self.id = id
        self.label = label
        self.fullName = fullName
        self.email = email
        self.serverURL = serverURL
        self.username = username
    }

    /// What the account is called on screen: the description, else the address.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return email.isEmpty ? "Exchange account" : email
    }

    var endpoint: URL? { Account.normalizedEndpoint(serverURL) }

    var host: String { endpoint?.host ?? "the server" }

    /// Accepts what people actually paste: a bare host, a host with `/ews`, or the full URL
    /// Outlook shows. A missing path gets the standard EWS path, which is the same on every
    /// Exchange server. Only HTTPS is accepted: this carries a password on every request.
    static func normalizedEndpoint(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path.lowercased() == "ews" {
            components.path = "/EWS/Exchange.asmx"
        }
        return components.url
    }
}
