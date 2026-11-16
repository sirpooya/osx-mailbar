import Foundation

// Account health (2026-11-16, after Outlook): automatic replies, password expiry and the
// mailbox's size and quota. Each is read with one request against the account's own mailbox.
//
// Unlike every other request in `SOAP`, the automatic-reply and password requests name the
// mailbox by its address: the operations take no distinguished id. The address is the account's
// own, from Settings, escaped.

/// The mailbox's automatic replies (Outlook's "Automatic Replies", EWS `OofSettings`).
///
/// The two messages are kept as the server sent them (HTML) so that turning replies off, or
/// saving without touching a message, writes back exactly what was there.
struct AutoReplySettings: Equatable, Sendable {
    enum State: String, Sendable, CaseIterable {
        case disabled = "Disabled"
        case enabled = "Enabled"
        case scheduled = "Scheduled"
    }

    /// Who outside the organization gets the external reply.
    enum Audience: String, Sendable, CaseIterable {
        case none = "None"
        case known = "Known"
        case all = "All"

        var title: String {
            switch self {
            case .none: return "None"
            case .known: return "My contacts only"
            case .all: return "Everyone"
            }
        }
    }

    var state: State = .disabled
    var audience: Audience = .all
    var start = Date()
    var end = Date().addingTimeInterval(24 * 60 * 60)
    var internalHTML = ""
    var externalHTML = ""

    /// On right now: turned on, or scheduled for a period that has begun and not ended.
    func isActive(at now: Date = Date()) -> Bool {
        switch state {
        case .disabled: return false
        case .enabled: return true
        case .scheduled: return start <= now && now < end
        }
    }
}

/// The mailbox's size, and its limit when the server says.
struct MailboxQuota: Equatable, Sendable {
    /// Bytes.
    var used: Int64
    /// Bytes: the send quota, else the storage warning limit, else the receive quota. Nil when
    /// none could be read.
    var limit: Int64?

    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return Double(used) / Double(limit)
    }

    /// Above 90 percent, the popover warns.
    var isAlmostFull: Bool { (fraction ?? 0) > 0.9 }

    /// "1.2 GB of 2 GB", or "1.2 GB" when the limit is unknown.
    var summary: String {
        let used = Self.bytes(self.used)
        guard let limit else { return used }
        return "\(used) of \(Self.bytes(limit))"
    }

    /// Binary units, as Exchange sets quotas: 2 GB is 2,097,152 KB.
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }
}

extension SOAP {

    // MARK: - Automatic replies

    static func getAutoReplies(address: String) -> String {
        """
            <m:GetUserOofSettingsRequest>
              <t:Mailbox><t:Address>\(escape(address))</t:Address></t:Mailbox>
            </m:GetUserOofSettingsRequest>
        """
    }

    /// The whole settings, every time: EWS replaces them as one. The duration goes too, since a
    /// scheduled state without one is refused.
    static func setAutoReplies(_ settings: AutoReplySettings, address: String) -> String {
        """
            <m:SetUserOofSettingsRequest>
              <t:Mailbox><t:Address>\(escape(address))</t:Address></t:Mailbox>
              <t:UserOofSettings>
                <t:OofState>\(settings.state.rawValue)</t:OofState>
                <t:ExternalAudience>\(settings.audience.rawValue)</t:ExternalAudience>
                <t:Duration><t:StartTime>\(isoDate(settings.start))</t:StartTime><t:EndTime>\(isoDate(settings.end))</t:EndTime></t:Duration>
                <t:InternalReply><t:Message>\(escape(settings.internalHTML))</t:Message></t:InternalReply>
                <t:ExternalReply><t:Message>\(escape(settings.externalHTML))</t:Message></t:ExternalReply>
              </t:UserOofSettings>
            </m:SetUserOofSettingsRequest>
        """
    }

    // MARK: - Password expiry (Exchange 2010 SP2 and later)

    static func getPasswordExpiration(address: String) -> String {
        """
            <m:GetPasswordExpirationDate>
              <m:MailboxSmtpAddress>\(escape(address))</m:MailboxSmtpAddress>
            </m:GetPasswordExpirationDate>
        """
    }

    // MARK: - Mailbox size and quota

    /// The main folders whose sizes add up to the used size when the root does not report one.
    static let quotaFolders = ["inbox", "sentitems", "deleteditems", "drafts", "junkemail",
                               "outbox", "calendar", "contacts", "tasks"]

    /// The root with its size (PR_MESSAGE_SIZE_EXTENDED, 0x0E08) and the three quotas Outlook
    /// reads from the store (PR_PROHIBIT_SEND_QUOTA 0x666E, PR_STORAGE_QUOTA_LIMIT 0x3FF5,
    /// PR_PROHIBIT_RECEIVE_QUOTA 0x666A, in KB), plus the main folders' sizes. Unproven on a
    /// real server: Exchange may return none of the quotas on a folder.
    static let getMailboxSize: String = {
        let ids = (["msgfolderroot"] + quotaFolders)
            .map { #"<t:DistinguishedFolderId Id="\#($0)"/>"# }.joined()
        return """
            <m:GetFolder>
              <m:FolderShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
                  <t:ExtendedFieldURI PropertyTag="0x0E08" PropertyType="Long"/>
                  <t:ExtendedFieldURI PropertyTag="0x666E" PropertyType="Integer"/>
                  <t:ExtendedFieldURI PropertyTag="0x3FF5" PropertyType="Integer"/>
                  <t:ExtendedFieldURI PropertyTag="0x666A" PropertyType="Integer"/>
                </t:AdditionalProperties>
              </m:FolderShape>
              <m:FolderIds>\(ids)</m:FolderIds>
            </m:GetFolder>
        """
    }()
}

extension EWSResponse {

    /// The availability-style replies (automatic replies, password) carry one `ResponseMessage`
    /// or a response element with `ResponseClass` of their own, not a `ResponseMessages` list.
    static func checkSingle(_ root: XMLTreeNode) throws {
        if let fault = root.first("Fault") {
            throw EWSError.server(fault.child("faultstring")?.trimmedText ?? "Exchange returned a SOAP fault.")
        }
        var stack = [root]
        while let node = stack.popLast() {
            if node.attributes["ResponseClass"] == "Error" {
                let code = node.child("ResponseCode")?.trimmedText ?? "Error"
                let text = node.child("MessageText")?.trimmedText ?? code
                throw EWSError.server(code == text ? text : "\(text) (\(code))")
            }
            stack.append(contentsOf: node.children)
        }
    }

    static func autoReplies(from data: Data) throws -> AutoReplySettings {
        let root = try parse(data)
        try checkSingle(root)
        guard let oof = root.first("OofSettings") else {
            throw EWSError.invalidResponse("Exchange did not return the automatic replies.")
        }
        var settings = AutoReplySettings()
        settings.state = oof.child("OofState").flatMap { AutoReplySettings.State(rawValue: $0.trimmedText) } ?? .disabled
        settings.audience = oof.child("ExternalAudience").flatMap { AutoReplySettings.Audience(rawValue: $0.trimmedText) } ?? .none
        if let start = oof.path("Duration", "StartTime").flatMap({ looseDate($0.trimmedText) }) { settings.start = start }
        if let end = oof.path("Duration", "EndTime").flatMap({ looseDate($0.trimmedText) }) { settings.end = end }
        settings.internalHTML = oof.path("InternalReply", "Message")?.text ?? ""
        settings.externalHTML = oof.path("ExternalReply", "Message")?.text ?? ""
        return settings
    }

    /// Nil when the server names no date: the password does not expire.
    static func passwordExpiration(from data: Data) throws -> Date? {
        let root = try parse(data)
        try checkSingle(root)
        guard let text = root.first("PasswordExpirationDate")?.trimmedText, !text.isEmpty else { return nil }
        return looseDate(text)
    }

    /// Nil when the server reported no size at all.
    static func mailboxQuota(from data: Data) throws -> MailboxQuota? {
        let root = try parse(data)
        if let fault = root.first("Fault") {
            throw EWSError.server(fault.child("faultstring")?.trimmedText ?? "Exchange returned a SOAP fault.")
        }
        guard let container = root.first("ResponseMessages") else {
            throw EWSError.invalidResponse("The reply had no response messages.")
        }
        // One message per folder asked for, in order; a folder the mailbox lacks is an error of
        // its own and is skipped.
        var rootSize: Int64?
        var folderSum: Int64 = 0
        var anyFolder = false
        var quotas: [String: Int64] = [:]
        for (index, message) in container.children.enumerated() where message.attributes["ResponseClass"] != "Error" {
            guard let folder = message.first("Folders")?.children.first else { continue }
            let values = longProperties(folder)
            if index == 0 {
                rootSize = values["0x0e08"]
                for tag in ["0x666e", "0x3ff5", "0x666a"] { quotas[tag] = values[tag] }
            } else if let size = values["0x0e08"] {
                folderSum += size
                anyFolder = true
            }
        }
        // The root's own figure can be its own items only, so the larger of the two is the
        // better guess at the whole mailbox.
        guard rootSize != nil || anyFolder else { return nil }
        let used = max(rootSize ?? 0, folderSum)
        let limitKB = [quotas["0x666e"], quotas["0x3ff5"], quotas["0x666a"]]
            .compactMap { $0 }.first { $0 > 0 }
        return MailboxQuota(used: used, limit: limitKB.map { $0 * 1024 })
    }

    private static func longProperties(_ node: XMLTreeNode) -> [String: Int64] {
        var values: [String: Int64] = [:]
        for property in node.children where property.name == "ExtendedProperty" {
            guard let tag = property.child("ExtendedFieldURI")?.attributes["PropertyTag"]?.lowercased(),
                  let value = property.child("Value").flatMap({ Int64($0.trimmedText) }) else { continue }
            // Exchange writes "0xe08", "0x0E08" or "3592"; one spelling for the lookup.
            let number = tag.hasPrefix("0x") ? Int(tag.dropFirst(2), radix: 16) : Int(tag)
            values[number.map { String(format: "0x%04x", $0) } ?? tag] = value
        }
        return values
    }

    /// EWS writes these dates with a zone ("Z") or, for the password, sometimes without one;
    /// a bare one is UTC.
    static func looseDate(_ text: String) -> Date? {
        parseDate(text) ?? parseDate(text + "Z")
    }
}

extension EWSClient {

    func autoReplies(address: String, at url: URL, credential: EWSCredential) async throws -> AutoReplySettings {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.getAutoReplies(address: address)),
                                     to: url, credential: credential)
        return try EWSResponse.autoReplies(from: data)
    }

    func setAutoReplies(_ settings: AutoReplySettings, address: String, at url: URL, credential: EWSCredential) async throws {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.setAutoReplies(settings, address: address)),
                                     to: url, credential: credential)
        try EWSResponse.checkSingle(try EWSResponse.parse(data))
    }

    func passwordExpiration(address: String, at url: URL, credential: EWSCredential) async throws -> Date? {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.getPasswordExpiration(address: address)),
                                     to: url, credential: credential)
        return try EWSResponse.passwordExpiration(from: data)
    }

    func mailboxQuota(at url: URL, credential: EWSCredential) async throws -> MailboxQuota? {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.getMailboxSize),
                                     to: url, credential: credential)
        return try EWSResponse.mailboxQuota(from: data)
    }
}
