import Foundation

/// The Exchange build, from the `ServerVersionInfo` header on every response.
struct ServerVersion: Equatable, Sendable {
    let major: Int
    let minor: Int

    /// Exchange 2013 is major version 15. 2016 and 2019 report 15 as well.
    var isModern: Bool { major >= 15 }

    var label: String {
        switch (major, minor) {
        case (15, 2): return "Exchange 2019"
        case (15, 1): return "Exchange 2016"
        case (15, 0): return "Exchange 2013"
        case (14, _): return "Exchange 2010"
        default: return "Exchange \(major).\(minor)"
        }
    }
}

struct InboxStatus: Equatable, Sendable {
    let unreadCount: Int
    let totalCount: Int
    let version: ServerVersion?
}

/// One inbox row. Exactly what the list shows plus what acting on it will need, and nothing more:
/// this is the only mail content the app keeps between polls, and only in memory.
struct MailMessage: Identifiable, Equatable, Sendable {
    /// EWS `ItemId`. Opaque, stable for the life of the item in this folder.
    let id: String
    /// Changes whenever the item does. Needed by every write.
    let changeKey: String
    let senderName: String
    let senderAddress: String
    let subject: String
    var preview: String
    let received: Date
    var isRead: Bool
    var isFlagged: Bool
    let hasAttachments: Bool
    /// An invitation (`t:MeetingRequest`): the reader offers Accept, Tentative, Decline (M17).
    var isMeetingRequest = false
}

/// One opened message. Lives in the reader's state while it is open and nowhere else: when the
/// reader closes, this goes, and so does every image decoded from it.
struct MessageBody: Equatable, Sendable {
    struct Person: Equatable, Sendable {
        let name: String
        let address: String

        var display: String { name.isEmpty ? address : name }
    }

    /// An image the HTML refers to as `cid:<contentID>`.
    struct InlineImage: Equatable, Sendable {
        let attachmentID: String
        let contentID: String
        let contentType: String
    }

    let id: String
    let subject: String
    let from: Person?
    let to: [Person]
    let cc: [Person]
    let received: Date
    let html: String
    let inlineImages: [InlineImage]
    /// Real attachments: everything that is not an image drawn inside the body.
    var files: [FileAttachment] = []
}

/// A file attached to a message, as listed by `GetItem`. The bytes are fetched only when the user
/// opens or saves it.
struct FileAttachment: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let contentType: String
    /// Bytes, as Exchange reports it. Zero when the server leaves it out.
    let size: Int

    var sizeLabel: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : ""
    }
}

/// One envelope from a streaming connection, reduced to what the app acts on.
struct StreamingChunk: Equatable, Sendable {
    /// Any event at all: new, created, deleted, modified, moved or copied.
    var hasChanges = false
    /// The server ended this connection (its timeout ran out). Reconnect with the same subscription.
    var isClosed = false
    /// `ResponseCode` of an error response, such as `ErrorSubscriptionNotFound`.
    var errorCode: String?

    /// The subscription no longer exists server side: subscribe again.
    var subscriptionIsGone: Bool {
        guard let errorCode else { return false }
        return ["ErrorSubscriptionNotFound", "ErrorInvalidSubscription", "ErrorExpiredSubscription",
                "ErrorSubscriptionAccessDenied", "ErrorInvalidPullSubscriptionId"].contains(errorCode)
    }

    static let eventNames = ["NewMailEvent", "CreatedEvent", "DeletedEvent",
                             "ModifiedEvent", "MovedEvent", "CopiedEvent"]
}

/// Reads EWS responses into the models above.
enum EWSResponse {

    /// The subscription id from a `Subscribe` reply.
    static func subscriptionID(from data: Data) throws -> String {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        guard let id = responses.first?.child("SubscriptionId")?.trimmedText, !id.isEmpty else {
            throw EWSError.invalidResponse("Exchange did not return a subscription.")
        }
        return id
    }

    /// One streaming envelope. Never throws for an error response: the error is data here, since
    /// what to do about it (resubscribe, back off) is the caller's decision.
    static func streamingChunk(from data: Data) -> StreamingChunk {
        guard let root = try? XMLTree.parse(data) else { return StreamingChunk() }
        var chunk = StreamingChunk()
        if root.first("Fault") != nil { chunk.errorCode = "Fault" }
        for message in root.first("ResponseMessages")?.children ?? [] {
            if message.attributes["ResponseClass"] == "Error" {
                chunk.errorCode = message.child("ResponseCode")?.trimmedText ?? "Error"
            }
            if message.child("ConnectionStatus")?.trimmedText == "Closed" { chunk.isClosed = true }
            for notification in message.all("Notification") {
                if notification.children.contains(where: { StreamingChunk.eventNames.contains($0.name) }) {
                    chunk.hasChanges = true
                }
            }
        }
        return chunk
    }

    /// Throws for a SOAP fault or for a response message whose `ResponseClass` is `Error`.
    /// Returns the response messages that succeeded (or merely warned).
    static func responseMessages(in root: XMLTreeNode) throws -> [XMLTreeNode] {
        if let fault = root.first("Fault") {
            let text = fault.child("faultstring")?.trimmedText
                ?? fault.first("Message")?.trimmedText
                ?? "Exchange returned a SOAP fault."
            throw EWSError.server(text)
        }
        guard let container = root.first("ResponseMessages") else {
            throw EWSError.invalidResponse("The reply had no response messages.")
        }
        let messages = container.children
        for message in messages where message.attributes["ResponseClass"] == "Error" {
            let code = message.child("ResponseCode")?.trimmedText ?? "Error"
            let text = message.child("MessageText")?.trimmedText ?? code
            throw EWSError.server(code == text ? text : "\(text) (\(code))")
        }
        return messages
    }

    static func serverVersion(in root: XMLTreeNode) -> ServerVersion? {
        guard let info = root.first("ServerVersionInfo"),
              let major = info.attributes["MajorVersion"].flatMap(Int.init) else { return nil }
        return ServerVersion(major: major, minor: info.attributes["MinorVersion"].flatMap(Int.init) ?? 0)
    }

    static func inboxStatus(from data: Data) throws -> InboxStatus {
        let root = try parse(data)
        let messages = try responseMessages(in: root)
        guard let folder = messages.first?.first("Folder") ?? root.first("Folder"),
              let unread = folder.child("UnreadCount").flatMap({ Int($0.trimmedText) }) else {
            throw EWSError.invalidResponse("The reply did not include the inbox unread count.")
        }
        let total = folder.child("TotalCount").flatMap { Int($0.trimmedText) } ?? 0
        return InboxStatus(unreadCount: unread, totalCount: total, version: serverVersion(in: root))
    }

    static func messages(from data: Data) throws -> [MailMessage] {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        guard let items = responses.first?.first("Items") else {
            throw EWSError.invalidResponse("The reply did not include the inbox items.")
        }
        // Any item type: a meeting request or a delivery report sits in the inbox as well and is
        // shown like mail. The one thing every item has is an ItemId.
        return items.children.compactMap(message(from:))
    }

    /// Item id to a one-line preview, from a `GetItem` of text bodies.
    static func previews(from data: Data) throws -> [String: String] {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        var result: [String: String] = [:]
        for response in responses {
            for item in response.child("Items")?.children ?? [] {
                guard let id = item.child("ItemId")?.attributes["Id"] else { continue }
                result[id] = previewText(item.child("Body")?.text ?? "")
            }
        }
        return result
    }

    static func body(from data: Data) throws -> MessageBody {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        guard let item = responses.first?.child("Items")?.children.first,
              let id = item.child("ItemId")?.attributes["Id"] else {
            throw EWSError.invalidResponse("The reply did not include the message.")
        }

        func people(_ field: String) -> [MessageBody.Person] {
            item.child(field)?.children.filter { $0.name == "Mailbox" }.map(person) ?? []
        }

        let inline: [MessageBody.InlineImage] = (item.child("Attachments")?.children ?? []).compactMap { attachment in
            guard attachment.name == "FileAttachment",
                  let attachmentID = attachment.child("AttachmentId")?.attributes["Id"],
                  let contentID = attachment.child("ContentId")?.trimmedText, !contentID.isEmpty else { return nil }
            let type = attachment.child("ContentType")?.trimmedText ?? ""
            // Only images can be drawn inline; anything else waits for attachments support.
            guard type.lowercased().hasPrefix("image/") else { return nil }
            return MessageBody.InlineImage(attachmentID: attachmentID, contentID: contentID, contentType: type)
        }

        // Anything the body does not draw is a file the user can open. Outlook marks some inline
        // images IsInline=false, so "drawn" means referenced as cid: in the HTML, not the flag.
        let html = item.child("Body")?.text ?? ""
        let drawn = Set(inline.map(\.attachmentID)).filter { id in
            inline.first { $0.attachmentID == id }.map { html.localizedCaseInsensitiveContains("cid:\($0.contentID)") } ?? false
        }
        let files: [FileAttachment] = (item.child("Attachments")?.children ?? []).compactMap { attachment in
            guard attachment.name == "FileAttachment",
                  let attachmentID = attachment.child("AttachmentId")?.attributes["Id"],
                  !drawn.contains(attachmentID) else { return nil }
            return FileAttachment(id: attachmentID,
                                  name: attachment.child("Name")?.trimmedText.nonEmpty ?? "Attachment",
                                  contentType: attachment.child("ContentType")?.trimmedText ?? "",
                                  size: attachment.child("Size").flatMap { Int($0.trimmedText) } ?? 0)
        }

        return MessageBody(
            id: id,
            subject: item.child("Subject")?.trimmedText.nonEmpty ?? "(No subject)",
            from: item.path("From", "Mailbox").map(person),
            to: people("ToRecipients"),
            cc: people("CcRecipients"),
            received: item.child("DateTimeReceived").flatMap { parseDate($0.trimmedText) } ?? .distantPast,
            html: html,
            inlineImages: inline,
            files: files)
    }

    private static func person(_ mailbox: XMLTreeNode) -> MessageBody.Person {
        MessageBody.Person(name: mailbox.child("Name")?.trimmedText ?? "",
                           address: mailbox.child("EmailAddress")?.trimmedText ?? "")
    }

    /// Attachment id to its decoded bytes, from a `GetAttachment` reply.
    static func attachmentContents(from data: Data) throws -> [String: Data] {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        var result: [String: Data] = [:]
        for attachment in responses.flatMap({ $0.child("Attachments")?.children ?? [] }) {
            guard let id = attachment.child("AttachmentId")?.attributes["Id"],
                  let base64 = attachment.child("Content")?.text,
                  let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { continue }
            result[id] = bytes
        }
        return result
    }

    /// The first folder id in a `FindFolder` or `CreateFolder` reply, or nil when none matched.
    static func folderID(from data: Data) throws -> String? {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        return responses.first?.first("FolderId")?.attributes["Id"]
    }

    /// For replies that carry nothing but success or failure.
    static func checkSuccess(_ data: Data) throws {
        _ = try responseMessages(in: try parse(data))
    }

    static func message(from item: XMLTreeNode) -> MailMessage? {
        guard let itemID = item.child("ItemId"), let id = itemID.attributes["Id"] else { return nil }
        let mailbox = item.path("From", "Mailbox")
        let name = mailbox?.child("Name")?.trimmedText ?? ""
        let address = mailbox?.child("EmailAddress")?.trimmedText ?? ""
        let subject = item.child("Subject")?.trimmedText ?? ""
        let received = item.child("DateTimeReceived").flatMap { parseDate($0.trimmedText) } ?? .distantPast

        return MailMessage(
            id: id,
            changeKey: itemID.attributes["ChangeKey"] ?? "",
            senderName: name.isEmpty ? (address.isEmpty ? "No sender" : address) : name,
            senderAddress: address,
            subject: subject.isEmpty ? "(No subject)" : subject,
            preview: previewText(item.child("Preview")?.text ?? ""),
            received: received,
            isRead: item.child("IsRead")?.trimmedText == "true",
            isFlagged: isFlagged(item),
            hasAttachments: item.child("HasAttachments")?.trimmedText == "true",
            isMeetingRequest: item.name == "MeetingRequest")
    }

    /// `item:Flag` on 2013 and later, the MAPI flag status (2 is flagged) on older servers.
    private static func isFlagged(_ item: XMLTreeNode) -> Bool {
        if let status = item.path("Flag", "FlagStatus")?.trimmedText {
            return status == "Flagged"
        }
        for property in item.children where property.name == "ExtendedProperty" {
            if property.child("ExtendedFieldURI")?.attributes["PropertyTag"]?.lowercased() == "0x1090" {
                return property.child("Value")?.trimmedText == "2"
            }
        }
        return false
    }

    /// One line: every run of whitespace, including the blank lines between paragraphs, becomes a
    /// single space. Capped, since the row only ever shows one line of it.
    static func previewText(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(256))
    }

    static func parseDate(_ text: String) -> Date? {
        plainDate.date(from: text) ?? fractionalDate.date(from: text)
    }

    // ISO8601DateFormatter is documented thread safe; it just is not marked Sendable.
    private nonisolated(unsafe) static let plainDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ data: Data) throws -> XMLTreeNode {
        do {
            return try XMLTree.parse(data)
        } catch let error as XMLTree.ParseError {
            throw EWSError.invalidResponse(error.message)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
