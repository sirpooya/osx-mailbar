import Foundation

/// The requests writing mail makes since M23 to M25: messages with Bcc, options and a From,
/// drafts in the server's Drafts folder, files, MailTips and the Templates folder. Templates like
/// `SOAP`'s, every interpolated value escaped.
enum ComposeSOAP {
    /// Where a created item goes.
    enum Disposition: Equatable {
        /// Sent now, a copy kept in Sent Items.
        case send
        /// Saved in Drafts, not sent.
        case draft
        /// Saved in a folder by id (the Templates folder).
        case saveIn(String)

        var attribute: String {
            switch self {
            case .send: return "SendAndSaveCopy"
            case .draft, .saveIn: return "SaveOnly"
            }
        }

        var folder: String {
            switch self {
            case .send: return #"<t:DistinguishedFolderId Id="sentitems"/>"#
            case .draft: return #"<t:DistinguishedFolderId Id="drafts"/>"#
            case .saveIn(let id): return #"<t:FolderId Id="\#(SOAP.escape(id))"/>"#
            }
        }
    }

    /// Everything one message carries, in the shape the requests need.
    struct Fields: Equatable, Sendable {
        var subject = ""
        var html = ""
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
        var from = ""
        var options = MessageOptions()
        /// Reply to selected text goes as a new message threaded under the original.
        var inReplyTo = ""
        var references = ""

        init(subject: String = "", html: String = "", to: [String] = [], cc: [String] = [], bcc: [String] = [],
             from: String = "", options: MessageOptions = MessageOptions()) {
            self.subject = subject
            self.html = html
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.from = from
            self.options = options
        }

        init(_ draft: Draft, subject: String? = nil) {
            self.init(subject: subject ?? draft.subjectPreview, html: draft.outgoingHTML,
                      to: Recipients.parse(draft.to), cc: Recipients.parse(draft.cc), bcc: Recipients.parse(draft.bcc),
                      from: draft.from, options: draft.options)
        }
    }

    static func mailboxes(_ element: String, _ addresses: [String]) -> String {
        guard !addresses.isEmpty else { return "" }
        let boxes = addresses.map { "<t:Mailbox><t:EmailAddress>\(SOAP.escape($0))</t:EmailAddress></t:Mailbox>" }.joined()
        return "<t:\(element)>\(boxes)</t:\(element)>"
    }

    private static func from(_ address: String) -> String {
        address.isEmpty ? "" : "<t:From><t:Mailbox><t:EmailAddress>\(SOAP.escape(address))</t:EmailAddress></t:Mailbox></t:From>"
    }

    private static func receipts(_ options: MessageOptions) -> String {
        (options.readReceipt ? "<t:IsReadReceiptRequested>true</t:IsReadReceiptRequested>" : "")
            + (options.deliveryReceipt ? "<t:IsDeliveryReceiptRequested>true</t:IsDeliveryReceiptRequested>" : "")
    }

    /// A new message, in the schema's order (Item's fields, then Message's).
    static func message(_ fields: Fields, _ disposition: Disposition) -> String {
        let sensitivity = fields.options.sensitivity == .normal ? "" : "<t:Sensitivity>\(fields.options.sensitivity.rawValue)</t:Sensitivity>"
        let importance = fields.options.importance == .normal ? "" : "<t:Importance>\(fields.options.importance.rawValue)</t:Importance>"
        let inReplyTo = fields.inReplyTo.isEmpty ? "" : "<t:InReplyTo>\(SOAP.escape(fields.inReplyTo))</t:InReplyTo>"
        let references = fields.references.isEmpty ? "" : "<t:References>\(SOAP.escape(fields.references))</t:References>"
        return """
            <m:CreateItem MessageDisposition="\(disposition.attribute)">
              <m:SavedItemFolderId>\(disposition.folder)</m:SavedItemFolderId>
              <m:Items>
                <t:Message>\
        <t:Subject>\(SOAP.escape(fields.subject))</t:Subject>\(sensitivity)\
        <t:Body BodyType="HTML">\(SOAP.escape(fields.html))</t:Body>\(importance)\(inReplyTo)\
        \(mailboxes("ToRecipients", fields.to))\(mailboxes("CcRecipients", fields.cc))\(mailboxes("BccRecipients", fields.bcc))\
        \(receipts(fields.options))\(from(fields.from))\(references)\
        </t:Message>
              </m:Items>
            </m:CreateItem>
        """
    }

    /// Reply, reply all or forward as a response object, which the server fills with the quote,
    /// the subject and (forward) the original's files. Response objects have no importance or
    /// sensitivity: those are set on the saved draft (`update`) before it is sent.
    static func response(_ response: SOAP.Response, to itemID: String, changeKey: String,
                         _ fields: Fields, newBody: String, _ disposition: Disposition) -> String {
        """
            <m:CreateItem MessageDisposition="\(disposition.attribute)">
              <m:SavedItemFolderId>\(disposition.folder)</m:SavedItemFolderId>
              <m:Items>
                <t:\(response.rawValue)>\
        \(mailboxes("ToRecipients", fields.to))\(mailboxes("CcRecipients", fields.cc))\(mailboxes("BccRecipients", fields.bcc))\
        \(receipts(fields.options))\(from(fields.from))\
        <t:ReferenceItemId Id="\(SOAP.escape(itemID))" ChangeKey="\(SOAP.escape(changeKey))"/>\
        <t:NewBodyContent BodyType="HTML">\(SOAP.escape(newBody))</t:NewBodyContent>\
        </t:\(response.rawValue)>
              </m:Items>
            </m:CreateItem>
        """
    }

    /// Rewrites a saved draft with what the composer holds now. Empty recipient lists are
    /// deleted, so a removed address does not linger on the server copy.
    static func update(draftID: String, _ fields: Fields, setsSubject: Bool) -> String {
        func set(_ uri: String, _ inner: String) -> String {
            #"<t:SetItemField><t:FieldURI FieldURI="\#(uri)"/><t:Message>\#(inner)</t:Message></t:SetItemField>"#
        }
        func delete(_ uri: String) -> String { #"<t:DeleteItemField><t:FieldURI FieldURI="\#(uri)"/></t:DeleteItemField>"# }
        var changes = ""
        if setsSubject { changes += set("item:Subject", "<t:Subject>\(SOAP.escape(fields.subject))</t:Subject>") }
        changes += set("item:Sensitivity", "<t:Sensitivity>\(fields.options.sensitivity.rawValue)</t:Sensitivity>")
        changes += set("item:Body", #"<t:Body BodyType="HTML">\#(SOAP.escape(fields.html))</t:Body>"#)
        changes += set("item:Importance", "<t:Importance>\(fields.options.importance.rawValue)</t:Importance>")
        for (uri, element, list) in [("message:ToRecipients", "ToRecipients", fields.to),
                                     ("message:CcRecipients", "CcRecipients", fields.cc),
                                     ("message:BccRecipients", "BccRecipients", fields.bcc)] {
            changes += list.isEmpty ? delete(uri) : set(uri, mailboxes(element, list))
        }
        changes += set("message:IsReadReceiptRequested",
                       "<t:IsReadReceiptRequested>\(fields.options.readReceipt)</t:IsReadReceiptRequested>")
        changes += set("message:IsDeliveryReceiptRequested",
                       "<t:IsDeliveryReceiptRequested>\(fields.options.deliveryReceipt)</t:IsDeliveryReceiptRequested>")
        if !fields.from.isEmpty { changes += set("message:From", from(fields.from)) }
        return """
            <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite">
              <m:ItemChanges>
                <t:ItemChange>
                  <t:ItemId Id="\(SOAP.escape(draftID))"/>
                  <t:Updates>\(changes)</t:Updates>
                </t:ItemChange>
              </m:ItemChanges>
            </m:UpdateItem>
        """
    }

    /// Sends a saved draft. The server moves it out of Drafts and keeps the copy in Sent Items.
    static func sendItem(_ id: String) -> String {
        """
            <m:SendItem SaveItemToFolder="true">
              <m:ItemIds><t:ItemId Id="\(SOAP.escape(id))"/></m:ItemIds>
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems"/></m:SavedItemFolderId>
            </m:SendItem>
        """
    }

    /// Files onto a saved draft, all in one request.
    static func attach(_ files: [OutgoingFile], to parentID: String) -> String {
        let items = files.map { file in
            "<t:FileAttachment><t:Name>\(SOAP.escape(file.name))</t:Name>"
                + "<t:ContentType>\(SOAP.escape(file.contentType))</t:ContentType>"
                + "<t:Content>\(file.data.base64EncodedString())</t:Content></t:FileAttachment>"
        }.joined()
        return """
            <m:CreateAttachment>
              <m:ParentItemId Id="\(SOAP.escape(parentID))"/>
              <m:Attachments>\(items)</m:Attachments>
            </m:CreateAttachment>
        """
    }

    /// The original message attached as a message (Forward as Attachment), from its MIME.
    static func attachMessage(mime base64: String, name: String, to parentID: String) -> String {
        """
            <m:CreateAttachment>
              <m:ParentItemId Id="\(SOAP.escape(parentID))"/>
              <m:Attachments><t:ItemAttachment><t:Name>\(SOAP.escape(name))</t:Name>\
        <t:Message><t:MimeContent CharacterSet="UTF-8">\(base64)</t:MimeContent></t:Message>\
        </t:ItemAttachment></m:Attachments>
            </m:CreateAttachment>
        """
    }

    /// An item's whole MIME, base64, for Forward as Attachment.
    static func getMime(_ id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:IncludeMimeContent>true</t:IncludeMimeContent></m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(SOAP.escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    /// The original's Internet ids, so a reply to selected text threads under it.
    static func getThreadIDs(_ id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
        <t:FieldURI FieldURI="message:InternetMessageId"/><t:FieldURI FieldURI="message:References"/>\
        </t:AdditionalProperties></m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(SOAP.escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    /// A saved draft or template in full, to reopen it in the composer.
    static func getDraft(_ id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape><t:BaseShape>Default</t:BaseShape><t:BodyType>HTML</t:BodyType><t:AdditionalProperties>\
        <t:FieldURI FieldURI="item:Body"/><t:FieldURI FieldURI="message:ToRecipients"/>\
        <t:FieldURI FieldURI="message:CcRecipients"/><t:FieldURI FieldURI="message:BccRecipients"/>\
        <t:FieldURI FieldURI="item:Importance"/><t:FieldURI FieldURI="item:Sensitivity"/>\
        <t:FieldURI FieldURI="message:IsReadReceiptRequested"/><t:FieldURI FieldURI="message:IsDeliveryReceiptRequested"/>\
        <t:FieldURI FieldURI="item:Attachments"/>\
        </t:AdditionalProperties></m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(SOAP.escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    /// MailTips for these recipients (Exchange 2010 and later): automatic replies, group sizes,
    /// outside members, addresses that do not exist.
    static func mailTips(sender: String, recipients: [String]) -> String {
        let boxes = recipients.map { "<t:Mailbox><t:EmailAddress>\(SOAP.escape($0))</t:EmailAddress></t:Mailbox>" }.joined()
        return """
            <m:GetMailTips>
              <m:SendingAs><t:EmailAddress>\(SOAP.escape(sender))</t:EmailAddress></m:SendingAs>
              <m:Recipients>\(boxes)</m:Recipients>
              <m:MailTipsRequested>OutOfOfficeMessage TotalMemberCount ExternalMemberCount InvalidRecipient</m:MailTipsRequested>
            </m:GetMailTips>
        """
    }

    static let templatesName = "Templates"

    /// The Templates folder directly under Drafts.
    static let findTemplatesFolder = """
        <m:FindFolder Traversal="Shallow">
          <m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>
          <m:Restriction>
            <t:IsEqualTo>
              <t:FieldURI FieldURI="folder:DisplayName"/>
              <t:FieldURIOrConstant><t:Constant Value="\(templatesName)"/></t:FieldURIOrConstant>
            </t:IsEqualTo>
          </m:Restriction>
          <m:ParentFolderIds><t:DistinguishedFolderId Id="drafts"/></m:ParentFolderIds>
        </m:FindFolder>
    """

    /// Created only after the user agrees, as the Archive folder is.
    static let createTemplatesFolder = """
        <m:CreateFolder>
          <m:ParentFolderId><t:DistinguishedFolderId Id="drafts"/></m:ParentFolderId>
          <m:Folders><t:Folder><t:DisplayName>\(templatesName)</t:DisplayName></t:Folder></m:Folders>
        </m:CreateFolder>
    """

    /// A folder's newest items, by id, with the fields a row needs.
    static func findItems(inFolder folderID: String, limit: Int = 50) -> String {
        """
            <m:FindItem Traversal="Shallow">
              <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
        <t:FieldURI FieldURI="item:Subject"/><t:FieldURI FieldURI="item:DisplayTo"/>\
        <t:FieldURI FieldURI="item:DateTimeReceived"/><t:FieldURI FieldURI="item:HasAttachments"/>\
        </t:AdditionalProperties></m:ItemShape>
              <m:IndexedPageItemView MaxEntriesReturned="\(limit)" Offset="0" BasePoint="Beginning"/>
              <m:SortOrder><t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder></m:SortOrder>
              <m:ParentFolderIds><t:FolderId Id="\(SOAP.escape(folderID))"/></m:ParentFolderIds>
            </m:FindItem>
        """
    }
}

/// Reading the replies those requests get.
enum ComposeResponse {
    /// The id of the item a `CreateItem` made.
    static func createdID(_ data: Data) throws -> String {
        let root = try EWSResponse.parse(data)
        let messages = try EWSResponse.responseMessages(in: root)
        guard let id = messages.first?.first("ItemId")?.attributes["Id"] else {
            throw EWSError.invalidResponse("Exchange did not return the saved draft.")
        }
        return id
    }

    /// A saved draft or template, as the composer fills itself from it.
    struct SavedMessage: Equatable, Sendable {
        var id: String
        var subject = ""
        var html = ""
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
        var options = MessageOptions()
        var fileNames: [String] = []
    }

    static func savedMessage(_ data: Data) throws -> SavedMessage {
        let root = try EWSResponse.parse(data)
        let messages = try EWSResponse.responseMessages(in: root)
        guard let item = messages.first?.child("Items")?.children.first,
              let id = item.child("ItemId")?.attributes["Id"] else {
            throw EWSError.invalidResponse("Exchange did not return the draft.")
        }
        func addresses(_ field: String) -> [String] {
            item.child(field)?.children.compactMap { $0.child("EmailAddress")?.trimmedText }.filter { !$0.isEmpty } ?? []
        }
        var saved = SavedMessage(id: id)
        saved.subject = item.child("Subject")?.trimmedText ?? ""
        saved.html = item.child("Body")?.text ?? ""
        saved.to = addresses("ToRecipients")
        saved.cc = addresses("CcRecipients")
        saved.bcc = addresses("BccRecipients")
        saved.options.importance = item.child("Importance").flatMap { MessageOptions.Importance(rawValue: $0.trimmedText) } ?? .normal
        saved.options.sensitivity = item.child("Sensitivity").flatMap { MessageOptions.Sensitivity(rawValue: $0.trimmedText) } ?? .normal
        saved.options.readReceipt = item.child("IsReadReceiptRequested")?.trimmedText == "true"
        saved.options.deliveryReceipt = item.child("IsDeliveryReceiptRequested")?.trimmedText == "true"
        saved.fileNames = (item.child("Attachments")?.children ?? []).compactMap { $0.child("Name")?.trimmedText }
        return saved
    }

    static func mime(_ data: Data) throws -> String {
        let root = try EWSResponse.parse(data)
        _ = try EWSResponse.responseMessages(in: root)
        guard let mime = root.first("MimeContent")?.trimmedText, !mime.isEmpty else {
            throw EWSError.invalidResponse("Exchange did not return the message to attach.")
        }
        return mime
    }

    static func threadIDs(_ data: Data) throws -> (messageID: String, references: String) {
        let root = try EWSResponse.parse(data)
        _ = try EWSResponse.responseMessages(in: root)
        return (root.first("InternetMessageId")?.trimmedText ?? "", root.first("References")?.trimmedText ?? "")
    }

    static func mailTips(_ data: Data) throws -> [MailTip] {
        let root = try EWSResponse.parse(data)
        _ = try EWSResponse.responseMessages(in: root)
        return root.all("MailTips").compactMap { tips in
            guard let address = tips.child("RecipientAddress")?.child("EmailAddress")?.trimmedText, !address.isEmpty else { return nil }
            var tip = MailTip(address: address)
            if let reply = tips.child("OutOfOffice")?.first("Message")?.trimmedText, !reply.isEmpty {
                tip.outOfOffice = ComposeResponse.plainText(reply)
            }
            tip.totalMembers = tips.child("TotalMemberCount").flatMap { Int($0.trimmedText) }
            tip.externalMembers = tips.child("ExternalMemberCount").flatMap { Int($0.trimmedText) }
            tip.invalid = tips.child("InvalidRecipient")?.trimmedText == "true"
            return tip
        }
    }

    /// An automatic reply comes as HTML; the tip shows its words on one line.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
