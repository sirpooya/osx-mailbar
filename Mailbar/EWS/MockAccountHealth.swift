import Foundation

/// The mock server's account health (DEBUG `MAILBAR_MOCK`): the work account has automatic
/// replies on, a password expiring in 5 days and a mailbox 92 percent full; the team account
/// has replies off, no expiry, and a size with no readable quota. Automatic replies saved in a
/// run stick for that run.
final class MockAccountHealth: @unchecked Sendable {
    static let shared = MockAccountHealth()

    private let lock = NSLock()
    private var oof: [String: String] = [:]

    /// The reply to a health request, or nil for any other.
    func answer(_ request: String, isTeam: Bool, now: Date = Date()) -> String? {
        let prefix = isTeam ? "team" : "work"
        if request.contains("<m:GetUserOofSettingsRequest>") {
            return lock.withLock { oof[prefix] } ?? Self.oofResponse(isTeam ? Self.teamOof(now: now) : Self.workOof(now: now))
        }
        if request.contains("<m:SetUserOofSettingsRequest>") {
            let settings = Self.oofSettings(from: request)
            lock.withLock { oof[prefix] = Self.oofResponse(settings) }
            return Self.envelope("""
                <SetUserOofSettingsResponse xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
                  <ResponseMessage ResponseClass="Success"><ResponseCode>NoError</ResponseCode></ResponseMessage>
                </SetUserOofSettingsResponse>
                """)
        }
        if request.contains("<m:GetPasswordExpirationDate>") {
            let date = isTeam ? "" : "<PasswordExpirationDate>\(Self.plain(now.addingTimeInterval(5 * 86_400 + 3600)))</PasswordExpirationDate>"
            return Self.envelope("""
                <GetPasswordExpirationDateResponse ResponseClass="Success" xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
                  <ResponseCode>NoError</ResponseCode>\(date)
                </GetPasswordExpirationDateResponse>
                """)
        }
        if request.contains("<m:GetFolder>"), request.contains(#"DistinguishedFolderId Id="msgfolderroot""#),
           request.contains(#"PropertyTag="0x0E08""#) {
            return Self.quotaResponse(isTeam: isTeam)
        }
        return nil
    }

    // MARK: - Fixtures

    private static func workOof(now: Date) -> AutoReplySettings {
        var settings = AutoReplySettings()
        settings.state = .enabled
        settings.audience = .known
        settings.start = now.addingTimeInterval(-86_400)
        settings.end = now.addingTimeInterval(6 * 86_400)
        settings.internalHTML = """
            <html><body><div style="font-family:Calibri">I am away until Monday with limited access to e-mail.</div>\
            <div><br></div><div>For anything urgent, write to sample.lead@example.com.</div>\
            <div dir="rtl">تا دوشنبه در دسترس نیستم.</div></body></html>
            """
        settings.externalHTML = "<html><body><div>Thank you for your message. I will reply when I am back on Monday.</div></body></html>"
        return settings
    }

    private static func teamOof(now: Date) -> AutoReplySettings {
        var settings = AutoReplySettings()
        settings.state = .disabled
        settings.audience = .none
        settings.start = now.addingTimeInterval(-30 * 86_400)
        settings.end = now.addingTimeInterval(-29 * 86_400)
        return settings
    }

    private static func oofResponse(_ settings: AutoReplySettings) -> String {
        envelope("""
            <GetUserOofSettingsResponse xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
              <ResponseMessage ResponseClass="Success"><ResponseCode>NoError</ResponseCode></ResponseMessage>
              <OofSettings xmlns="http://schemas.microsoft.com/exchange/services/2006/types">
                <OofState>\(settings.state.rawValue)</OofState>
                <ExternalAudience>\(settings.audience.rawValue)</ExternalAudience>
                <Duration><StartTime>\(SOAP.isoDate(settings.start))</StartTime><EndTime>\(SOAP.isoDate(settings.end))</EndTime></Duration>
                <InternalReply><Message>\(SOAP.escape(settings.internalHTML))</Message></InternalReply>
                <ExternalReply><Message>\(SOAP.escape(settings.externalHTML))</Message></ExternalReply>
              </OofSettings>
              <AllowExternalOof>All</AllowExternalOof>
            </GetUserOofSettingsResponse>
            """)
    }

    /// Reads back what the app sent, through the parser the app uses on the real reply.
    private static func oofSettings(from request: String) -> AutoReplySettings {
        let xml = request.replacingOccurrences(of: "SetUserOofSettingsRequest", with: "GetUserOofSettingsResponse")
            .replacingOccurrences(of: "UserOofSettings>", with: "OofSettings>")
        return (try? EWSResponse.autoReplies(from: Data(xml.utf8))) ?? AutoReplySettings()
    }

    /// Work: 1.84 GB of a 2 GB send quota (92 percent). Team: folder sizes only.
    private static func quotaResponse(isTeam: Bool) -> String {
        func folder(_ properties: [(String, String, Int64)]) -> String {
            let values = properties.map { tag, type, value in
                #"<t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="\#(tag)" PropertyType="\#(type)"/><t:Value>\#(value)</t:Value></t:ExtendedProperty>"#
            }.joined()
            return #"<m:GetFolderResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Folders><t:Folder><t:FolderId Id="f"/>\#(values)</t:Folder></m:Folders></m:GetFolderResponseMessage>"#
        }
        let gib: Int64 = 1 << 30
        var messages: [String]
        if isTeam {
            messages = [folder([])] + SOAP.quotaFolders.enumerated().map { index, _ in
                folder([("0xe08", "Long", Int64(index + 1) * 21 * (1 << 20))])
            }
        } else {
            messages = [folder([("0xe08", "Long", gib * 92 / 50), ("0x666e", "Integer", 2 * 1_048_576),
                                ("0x3ff5", "Integer", 1_900_000), ("0x666a", "Integer", 2_300_000)])]
                + SOAP.quotaFolders.map { _ in folder([("0xe08", "Long", 40 * (1 << 20))]) }
        }
        // A mailbox without a Tasks folder answers that one with an error; the rest still count.
        messages[messages.count - 1] = #"<m:GetFolderResponseMessage ResponseClass="Error"><m:MessageText>The specified folder could not be found in the store.</m:MessageText><m:ResponseCode>ErrorFolderNotFound</m:ResponseCode></m:GetFolderResponseMessage>"#
        return envelope("""
            <m:GetFolderResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>\(messages.joined())</m:ResponseMessages>
            </m:GetFolderResponse>
            """)
    }

    /// The password date as Exchange writes it: no zone.
    private static func plain(_ date: Date) -> String {
        String(SOAP.isoDate(date).dropLast())
    }

    private static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Header><h:ServerVersionInfo xmlns:h="http://schemas.microsoft.com/exchange/services/2006/types" MajorVersion="15" MinorVersion="1"/></s:Header>
          <s:Body>
        \(body)
          </s:Body>
        </s:Envelope>
        """
    }
}
