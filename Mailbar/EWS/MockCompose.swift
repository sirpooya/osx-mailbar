import Foundation

/// The pretend server's Drafts folder, Templates folder and MailTips (M23 to M25), for
/// `MAILBAR_MOCK` and the tests. `MockTransport` asks it first; nil means "not mine".
/// Nothing is ever delivered: SendItem only removes the draft, as the real server does.
final class MockCompose: @unchecked Sendable {
    struct Item {
        var subject = ""
        var html = ""
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
        var importance = "Normal"
        var sensitivity = "Normal"
        var folder = "drafts"
        var files: [String] = []
        var created = Date()
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var counter = 0
    private var templatesFolders: Set<String> = []
    /// Drafts sent with SendItem, in order, for tests.
    private(set) var sentDrafts: [Item] = []

    var sentItems: [Item] { lock.withLock { sentDrafts } }
    var draftCount: Int { lock.withLock { items.values.filter { $0.folder == "drafts" }.count } }

    /// A template ready in the work account's mock, so New from Template has something to list.
    init() {
        items["tpl-weekly"] = Item(subject: "Weekly status", html: """
            <html><body><div>Hi all,</div><div><br></div><div>This week:</div><ul><li>Done: </li><li>Next: </li></ul><div>Thanks!</div></body></html>
            """, to: ["designteam@example.com"], folder: "work-templates")
        templatesFolders.insert("work")
    }

    func answer(_ request: String, prefix: String) -> String? {
        lock.withLock { reply(request, prefix: prefix) }
    }

    private func reply(_ request: String, prefix: String) -> String? {
        let itemID = Self.first(#"ItemId Id="([^"]+)""#, in: request)
        if request.contains("<m:GetMailTips>") { return Self.mailTips(Self.all("<t:EmailAddress>([^<]*)</t:EmailAddress>", in: request).dropFirst()) }

        if request.contains("<m:FindFolder"), request.contains("Value=\"\(ComposeSOAP.templatesName)\"") {
            return MockFixtures.findFolder(found: templatesFolders.contains(prefix) ? "\(prefix)-templates" : nil)
        }
        if request.contains("<m:CreateFolder>"), request.contains("<t:DisplayName>\(ComposeSOAP.templatesName)</t:DisplayName>") {
            templatesFolders.insert(prefix)
            return MockFixtures.createFolder(id: "\(prefix)-templates")
        }

        if request.contains("<m:CreateItem"), request.contains(#"MessageDisposition="SaveOnly""#) {
            let folder: String
            if request.contains(#"DistinguishedFolderId Id="drafts""#) {
                folder = "drafts"
            } else if let id = Self.first(#"SavedItemFolderId><t:FolderId Id="([^"]+)""#, in: request), id.hasSuffix("-templates") {
                folder = id
            } else {
                return nil
            }
            counter += 1
            let id = (folder == "drafts" ? "draft-" : "tpl-") + "\(counter)"
            var item = Item(folder: folder)
            item.subject = Self.unescape(Self.first("<t:Subject>([^<]*)</t:Subject>", in: request) ?? "")
            item.html = Self.unescape(Self.first(#"<t:Body BodyType="HTML">([^<]*)</t:Body>"#, in: request) ?? "")
            for response in ["ReplyToItem", "ReplyAllToItem", "ForwardItem"] where request.contains("<t:\(response)>") {
                item.subject = (response == "ForwardItem" ? "FW: " : "RE: ") + "Original subject"
                item.html = Self.quote(new: Self.unescape(Self.first(#"<t:NewBodyContent BodyType="HTML">([^<]*)</t:NewBodyContent>"#,
                                                                         in: request) ?? ""))
            }
            item.to = Self.addresses("ToRecipients", in: request)
            item.cc = Self.addresses("CcRecipients", in: request)
            item.bcc = Self.addresses("BccRecipients", in: request)
            items[id] = item
            return Self.created(id)
        }
        if request.contains("<m:UpdateItem"), let itemID, var item = items[itemID] {
            if let subject = Self.first("<t:Subject>([^<]*)</t:Subject>", in: request) { item.subject = Self.unescape(subject) }
            if let html = Self.first(#"<t:Body BodyType="HTML">([^<]*)</t:Body>"#, in: request) { item.html = Self.unescape(html) }
            item.to = Self.addresses("ToRecipients", in: request)
            item.cc = Self.addresses("CcRecipients", in: request)
            item.bcc = Self.addresses("BccRecipients", in: request)
            item.importance = Self.first("<t:Importance>(\\w+)</t:Importance>", in: request) ?? item.importance
            item.sensitivity = Self.first("<t:Sensitivity>(\\w+)</t:Sensitivity>", in: request) ?? item.sensitivity
            items[itemID] = item
            return MockFixtures.success("UpdateItem")
        }
        if request.contains("<m:CreateAttachment>"), let parent = Self.first(#"ParentItemId Id="([^"]+)""#, in: request),
           items[parent] != nil {
            items[parent]?.files += Self.all("<t:Name>([^<]*)</t:Name>", in: request).map(Self.unescape)
            return MockFixtures.success("CreateAttachment")
        }
        if request.contains("<m:SendItem"), let itemID {
            guard let item = items.removeValue(forKey: itemID) else { return Self.error("SendItem", "ErrorItemNotFound") }
            sentDrafts.append(item)
            return MockFixtures.success("SendItem")
        }
        if request.contains("<m:DeleteItem"), let itemID, items[itemID] != nil {
            items[itemID] = nil
            return MockFixtures.success("DeleteItem")
        }
        if request.contains("<m:GetItem>"), request.contains("<t:IncludeMimeContent>true</t:IncludeMimeContent>") {
            let mime = "From: someone@example.net\r\nSubject: Original\r\nContent-Type: text/plain\r\n\r\nHello\r\n"
            return Self.wrap("GetItem", "<m:Items><t:Message><t:MimeContent CharacterSet=\"UTF-8\">\(Data(mime.utf8).base64EncodedString())</t:MimeContent><t:ItemId Id=\"\(itemID ?? "")\" ChangeKey=\"ck\"/></t:Message></m:Items>")
        }
        if request.contains("<m:GetItem>"), request.contains("message:InternetMessageId") {
            return Self.wrap("GetItem", "<m:Items><t:Message><t:ItemId Id=\"\(itemID ?? "")\" ChangeKey=\"ck\"/><t:InternetMessageId>&lt;original-1@example.net&gt;</t:InternetMessageId><t:References>&lt;root-1@example.net&gt;</t:References></t:Message></m:Items>")
        }
        if request.contains("<m:GetItem>"), let itemID, let item = items[itemID] {
            return Self.wrap("GetItem", "<m:Items>\(Self.message(itemID, item, full: true))</m:Items>")
        }
        if request.contains("<m:FindItem") {
            let folder: String
            if request.contains(#"DistinguishedFolderId Id="drafts""#) {
                folder = "drafts"
            } else if let id = Self.first(#"ParentFolderIds><t:FolderId Id="([^"]+)""#, in: request), id.hasSuffix("-templates") {
                folder = id
            } else {
                return nil
            }
            let found = items.filter { $0.value.folder == folder && (folder != "drafts" || true) }
                .sorted { $0.value.created > $1.value.created }
                .map { Self.message($0.key, $0.value, full: false) }.joined()
            return Self.wrap("FindItem", "<m:RootFolder TotalItemsInView=\"\(found.isEmpty ? 0 : 1)\" IncludesLastItemInRange=\"true\"><t:Items>\(found)</t:Items></m:RootFolder>")
        }
        return nil
    }

    // MARK: - Fixtures

    private static func quote(new html: String) -> String {
        "<html><head></head><body>\(html)<hr><div><b>From:</b> Narges Ahmadi<br><b>Subject:</b> Original subject</div>"
            + "<div>The original message, quoted by the server.</div></body></html>"
    }

    private static func message(_ id: String, _ item: Item, full: Bool) -> String {
        func boxes(_ list: [String]) -> String {
            list.map { "<t:Mailbox><t:Name>\($0)</t:Name><t:EmailAddress>\($0)</t:EmailAddress></t:Mailbox>" }.joined()
        }
        let date = ISO8601DateFormatter().string(from: item.created)
        var xml = "<t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"ck\"/><t:Subject>\(SOAP.escape(item.subject))</t:Subject>"
            + "<t:Sensitivity>\(item.sensitivity)</t:Sensitivity>"
        if full { xml += "<t:Body BodyType=\"HTML\">\(SOAP.escape(item.html))</t:Body>" }
        if full, !item.files.isEmpty {
            xml += "<t:Attachments>" + item.files.enumerated().map {
                "<t:FileAttachment><t:AttachmentId Id=\"\(id)-f\($0.offset)\"/><t:Name>\(SOAP.escape($0.element))</t:Name></t:FileAttachment>"
            }.joined() + "</t:Attachments>"
        }
        xml += "<t:DateTimeReceived>\(date)</t:DateTimeReceived><t:HasAttachments>\(!item.files.isEmpty)</t:HasAttachments>"
            + "<t:Importance>\(item.importance)</t:Importance>"
            + "<t:DisplayTo>\(SOAP.escape(item.to.joined(separator: "; ")))</t:DisplayTo>"
            + "<t:ToRecipients>\(boxes(item.to))</t:ToRecipients><t:CcRecipients>\(boxes(item.cc))</t:CcRecipients>"
            + "<t:BccRecipients>\(boxes(item.bcc))</t:BccRecipients><t:IsRead>true</t:IsRead></t:Message>"
        return xml
    }

    /// Sara has an automatic reply on; the Design Team group is large.
    private static func mailTips(_ addresses: ArraySlice<String>) -> String {
        let tips = addresses.map { address -> String in
            var inner = "<t:RecipientAddress><t:EmailAddress>\(address)</t:EmailAddress></t:RecipientAddress><t:PendingMailTips/>"
            if address.hasPrefix("sara") {
                inner += "<t:OutOfOffice><t:ReplyBody><t:Message>&lt;p&gt;I am away until Monday. For urgent things please write to Narges.&lt;/p&gt;</t:Message></t:ReplyBody></t:OutOfOffice>"
            }
            if address == "designteam@example.com" {
                inner += "<t:TotalMemberCount>42</t:TotalMemberCount><t:ExternalMemberCount>0</t:ExternalMemberCount>"
            }
            return "<m:MailTipsResponseMessageType ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:MailTips>\(inner)</m:MailTips></m:MailTipsResponseMessageType>"
        }.joined()
        return envelope("<m:GetMailTipsResponse ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:ResponseMessages>\(tips)</m:ResponseMessages></m:GetMailTipsResponse>")
    }

    private static func created(_ id: String) -> String {
        wrap("CreateItem", "<m:Items><t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"ck\"/></t:Message></m:Items>")
    }

    private static func wrap(_ operation: String, _ inner: String) -> String {
        envelope("<m:\(operation)Response><m:ResponseMessages><m:\(operation)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(operation)ResponseMessage></m:ResponseMessages></m:\(operation)Response>")
    }

    private static func error(_ operation: String, _ code: String) -> String {
        envelope("<m:\(operation)Response><m:ResponseMessages><m:\(operation)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(code)</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode></m:\(operation)ResponseMessage></m:ResponseMessages></m:\(operation)Response>")
    }

    private static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    private static func addresses(_ element: String, in request: String) -> [String] {
        guard let block = first("<t:\(element)>(.*?)</t:\(element)>", in: request) else { return [] }
        return all("<t:EmailAddress>([^<]*)</t:EmailAddress>", in: block).map(unescape)
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        all(pattern, in: text).first
    }

    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
