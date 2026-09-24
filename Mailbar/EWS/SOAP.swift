import Foundation

/// The SOAP requests this app sends, as string templates. There are few and they are small, so a
/// template is easier to check against Microsoft's documentation than a builder would be.
///
/// Every request targets the signed-in user's own mailbox through distinguished folder ids, so no
/// address or name is ever interpolated into one. The one interpolated value is an item id, and it
/// is escaped.
enum SOAP {

    /// The version requested in the header. `Exchange2010_SP2` is accepted by every server from
    /// 2010 SP2 on, which is why the probe uses it: asking an older server for a newer version is
    /// itself an error. `Exchange2013` unlocks `item:Preview` and `item:Flag`.
    enum Version: String, Sendable {
        case exchange2010SP2 = "Exchange2010_SP2"
        case exchange2013 = "Exchange2013"
    }

    static func envelope(_ version: Version, body: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header><t:RequestServerVersion Version="\(version.rawValue)"/></soap:Header>
          <soap:Body>
        \(body)
          </soap:Body>
        </soap:Envelope>
        """
        return Data(xml.utf8)
    }

    /// The inbox folder itself: its unread count, and in the response header the server version.
    static let getInbox = """
        <m:GetFolder>
          <m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape>
          <m:FolderIds><t:DistinguishedFolderId Id="inbox"/></m:FolderIds>
        </m:GetFolder>
    """

    /// The newest `limit` inbox items with exactly the fields a row shows.
    ///
    /// `modern` is Exchange 2013 or later. Older servers have neither `item:Preview` nor
    /// `item:Flag`, so the flag is read from its MAPI property instead (PidTagFlagStatus, 0x1090)
    /// and the preview is filled in separately by `textBodies`.
    static func findInbox(limit: Int, modern: Bool) -> String {
        let versionFields = modern
            ? """
                  <t:FieldURI FieldURI="item:Preview"/>
                  <t:FieldURI FieldURI="item:Flag"/>
              """
            : """
                  <t:ExtendedFieldURI PropertyTag="0x1090" PropertyType="Integer"/>
              """
        return """
            <m:FindItem Traversal="Shallow">
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
                  <t:FieldURI FieldURI="item:Subject"/>
                  <t:FieldURI FieldURI="message:From"/>
                  <t:FieldURI FieldURI="item:DateTimeReceived"/>
                  <t:FieldURI FieldURI="message:IsRead"/>
                  <t:FieldURI FieldURI="item:HasAttachments"/>
        \(versionFields)
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:IndexedPageItemView MaxEntriesReturned="\(max(1, limit))" Offset="0" BasePoint="Beginning"/>
              <m:SortOrder>
                <t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder>
              </m:SortOrder>
              <m:ParentFolderIds><t:DistinguishedFolderId Id="inbox"/></m:ParentFolderIds>
            </m:FindItem>
        """
    }

    /// Plain-text bodies, for building a preview on a pre-2013 server. Only ever asked for the
    /// items whose preview is not already known, so a poll does not refetch fifty bodies.
    static func textBodies(ids: [String]) -> String {
        let idElements = ids.map { "      <t:ItemId Id=\"\(escape($0))\"/>" }.joined(separator: "\n")
        return """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:BodyType>Text</t:BodyType>
                <t:AdditionalProperties><t:FieldURI FieldURI="item:Body"/></t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds>
        \(idElements)
              </m:ItemIds>
            </m:GetItem>
        """
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}
