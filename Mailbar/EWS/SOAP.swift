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

    /// Search (M8). Exchange 2013 and later: `QueryString`, the server's own search index, the
    /// same one Outlook's search box uses, matching sender, subject and body. Older servers have
    /// no query string, so a restriction matches the subject or the body as a substring.
    static func searchInbox(_ text: String, limit: Int, modern: Bool) -> String {
        let find = findInbox(limit: limit, modern: modern)
        let query = escape(text)
        if modern {
            return find.replacingOccurrences(of: "</m:ParentFolderIds>",
                                             with: "</m:ParentFolderIds>\n      <m:QueryString>\(query)</m:QueryString>")
        }
        let contains = { (field: String) in
            """
            <t:Contains ContainmentMode="Substring" ContainmentComparison="IgnoreCase">\
            <t:FieldURI FieldURI="\(field)"/><t:Constant Value="\(query)"/></t:Contains>
            """
        }
        let restriction = """
              <m:Restriction><t:Or>\(contains("item:Subject"))\(contains("item:Body"))</t:Or></m:Restriction>
        """
        return find.replacingOccurrences(of: "      <m:SortOrder>", with: restriction + "\n      <m:SortOrder>")
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

    // MARK: - Reading one message (M4)

    /// Everything the reader shows. The body as HTML: Exchange converts plain text and RTF mail
    /// to HTML itself, so the reader has one path.
    static func getMessage(id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:BodyType>HTML</t:BodyType>
                <t:AdditionalProperties>
                  <t:FieldURI FieldURI="item:Subject"/>
                  <t:FieldURI FieldURI="message:From"/>
                  <t:FieldURI FieldURI="message:ToRecipients"/>
                  <t:FieldURI FieldURI="message:CcRecipients"/>
                  <t:FieldURI FieldURI="item:DateTimeReceived"/>
                  <t:FieldURI FieldURI="item:Body"/>
                  <t:FieldURI FieldURI="item:Attachments"/>
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    /// The bytes of the inline images a body refers to by `cid:`. Held in memory for the life of
    /// the reader and never written anywhere.
    static func getAttachments(ids: [String]) -> String {
        let idElements = ids.map { "      <t:AttachmentId Id=\"\(escape($0))\"/>" }.joined(separator: "\n")
        return """
            <m:GetAttachment>
              <m:AttachmentIds>
        \(idElements)
              </m:AttachmentIds>
            </m:GetAttachment>
        """
    }

    // MARK: - Acting on a message (M5)

    /// Read state. No `ChangeKey` and `AlwaysOverwrite`: setting one boolean is idempotent, so
    /// there is nothing to conflict with, and leaving the change key out removes the refetch and
    /// retry dance entirely. `SuppressReadReceipts` needs Exchange 2013; on an older server a
    /// read receipt request is answered however the server's own policy says.
    static func setRead(id: String, read: Bool, modern: Bool) -> String {
        let suppress = modern ? #" SuppressReadReceipts="true""# : ""
        return updateItem(id: id, suppress: suppress, change: """
                      <t:SetItemField>
                        <t:FieldURI FieldURI="message:IsRead"/>
                        <t:Message><t:IsRead>\(read)</t:IsRead></t:Message>
                      </t:SetItemField>
        """)
    }

    /// `item:Flag` on 2013 and later; the MAPI flag status (2 is flagged) on older servers.
    static func setFlag(id: String, flagged: Bool, modern: Bool) -> String {
        let change: String
        if modern {
            change = """
                          <t:SetItemField>
                            <t:FieldURI FieldURI="item:Flag"/>
                            <t:Message><t:Flag><t:FlagStatus>\(flagged ? "Flagged" : "NotFlagged")</t:FlagStatus></t:Flag></t:Message>
                          </t:SetItemField>
            """
        } else if flagged {
            change = """
                          <t:SetItemField>
                            <t:ExtendedFieldURI PropertyTag="0x1090" PropertyType="Integer"/>
                            <t:Message><t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x1090" PropertyType="Integer"/><t:Value>2</t:Value></t:ExtendedProperty></t:Message>
                          </t:SetItemField>
            """
        } else {
            change = """
                          <t:DeleteItemField><t:ExtendedFieldURI PropertyTag="0x1090" PropertyType="Integer"/></t:DeleteItemField>
            """
        }
        return updateItem(id: id, suppress: "", change: change)
    }

    private static func updateItem(id: String, suppress: String, change: String) -> String {
        """
            <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite"\(suppress)>
              <m:ItemChanges>
                <t:ItemChange>
                  <t:ItemId Id="\(escape(id))"/>
                  <t:Updates>
        \(change)
                  </t:Updates>
                </t:ItemChange>
              </m:ItemChanges>
            </m:UpdateItem>
        """
    }

    /// To Deleted Items, where Outlook's own Delete puts it and where it can be recovered.
    /// Never `HardDelete` or `SoftDelete`.
    static func moveToDeletedItems(id: String) -> String {
        """
            <m:DeleteItem DeleteType="MoveToDeletedItems">
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:DeleteItem>
        """
    }

    /// The top-level folder Outlook for Mac's Archive button moves mail into.
    static let archiveFolderName = "Archive"

    static let findArchiveFolder = """
        <m:FindFolder Traversal="Shallow">
          <m:FolderShape>
            <t:BaseShape>IdOnly</t:BaseShape>
            <t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/></t:AdditionalProperties>
          </m:FolderShape>
          <m:Restriction>
            <t:IsEqualTo>
              <t:FieldURI FieldURI="folder:DisplayName"/>
              <t:FieldURIOrConstant><t:Constant Value="\(archiveFolderName)"/></t:FieldURIOrConstant>
            </t:IsEqualTo>
          </m:Restriction>
          <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds>
        </m:FindFolder>
    """

    /// Only ever sent after the user confirms, in the popover, that the folder should be made.
    static let createArchiveFolder = """
        <m:CreateFolder>
          <m:ParentFolderId><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderId>
          <m:Folders><t:Folder><t:DisplayName>\(archiveFolderName)</t:DisplayName></t:Folder></m:Folders>
        </m:CreateFolder>
    """

    static func move(id: String, toFolder folderID: String) -> String {
        """
            <m:MoveItem>
              <m:ToFolderId><t:FolderId Id="\(escape(folderID))"/></m:ToFolderId>
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:MoveItem>
        """
    }

    // MARK: - Streaming notifications (M11)

    /// A streaming subscription to the inbox. Every change that can alter the list or the count.
    /// Needs Exchange 2010 SP1 or later.
    static let subscribeToInbox = """
        <m:Subscribe>
          <m:StreamingSubscriptionRequest>
            <t:FolderIds><t:DistinguishedFolderId Id="inbox"/></t:FolderIds>
            <t:EventTypes>
              <t:EventType>NewMailEvent</t:EventType>
              <t:EventType>CreatedEvent</t:EventType>
              <t:EventType>DeletedEvent</t:EventType>
              <t:EventType>ModifiedEvent</t:EventType>
              <t:EventType>MovedEvent</t:EventType>
              <t:EventType>CopiedEvent</t:EventType>
            </t:EventTypes>
          </m:StreamingSubscriptionRequest>
        </m:Subscribe>
    """

    /// Holds the connection open for up to `minutes` (EWS allows 1 to 30), writing an envelope
    /// whenever events arrive, and a last one with `ConnectionStatus` Closed when time is up.
    static func getStreamingEvents(subscription: String, minutes: Int) -> String {
        """
            <m:GetStreamingEvents>
              <m:SubscriptionIds><t:SubscriptionId>\(escape(subscription))</t:SubscriptionId></m:SubscriptionIds>
              <m:ConnectionTimeout>\(min(max(minutes, 1), 30))</m:ConnectionTimeout>
            </m:GetStreamingEvents>
        """
    }

    // MARK: - Sending (M12 to M14)

    /// The item's id with its current change key. A reply has to name the exact version of the
    /// message it answers, and that changes whenever the message does (opening it marks it read).
    static func getItemIdentity(id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    enum Response: String {
        case reply = "ReplyToItem"
        case replyAll = "ReplyAllToItem"
        case forward = "ForwardItem"
    }

    /// Reply, reply all or forward. The server adds the quoted original, the RE: or FW: subject,
    /// and for a forward the original's attachments; `SendAndSaveCopy` files the sent message in
    /// Sent Items, as Outlook does.
    static func respond(_ response: Response, to itemID: String, changeKey: String,
                        to: [String], cc: [String], html: String) -> String {
        """
            <m:CreateItem MessageDisposition="SendAndSaveCopy">
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems"/></m:SavedItemFolderId>
              <m:Items>
                <t:\(response.rawValue)>
        \(recipients("ToRecipients", to))\(recipients("CcRecipients", cc))\
                  <t:ReferenceItemId Id="\(escape(itemID))" ChangeKey="\(escape(changeKey))"/>
                  <t:NewBodyContent BodyType="HTML">\(escape(html))</t:NewBodyContent>
                </t:\(response.rawValue)>
              </m:Items>
            </m:CreateItem>
        """
    }

    static func newMessage(subject: String, to: [String], cc: [String], html: String) -> String {
        """
            <m:CreateItem MessageDisposition="SendAndSaveCopy">
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems"/></m:SavedItemFolderId>
              <m:Items>
                <t:Message>
                  <t:Subject>\(escape(subject))</t:Subject>
                  <t:Body BodyType="HTML">\(escape(html))</t:Body>
        \(recipients("ToRecipients", to))\(recipients("CcRecipients", cc))\
                </t:Message>
              </m:Items>
            </m:CreateItem>
        """
    }

    private static func recipients(_ element: String, _ addresses: [String]) -> String {
        guard !addresses.isEmpty else { return "" }
        let boxes = addresses.map { "<t:Mailbox><t:EmailAddress>\(escape($0))</t:EmailAddress></t:Mailbox>" }.joined()
        return "          <t:\(element)>\(boxes)</t:\(element)>\n"
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
