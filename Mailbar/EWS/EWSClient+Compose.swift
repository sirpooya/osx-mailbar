import Foundation

/// Writing mail since M23 to M25. Each call is one request, except where noted.
extension EWSClient {
    private func compose(_ body: String, url: URL, credential: EWSCredential) async throws -> Data {
        try await sendRaw(SOAP.envelope(.exchange2010SP2, body: body), to: url, credential: credential)
    }

    /// The original's current change key, which a response object must name.
    func changeKey(of id: String, at url: URL, credential: EWSCredential) async throws -> String {
        let data = try await compose(SOAP.getItemIdentity(id: id), url: url, credential: credential)
        let root = try XMLTree.parse(data)
        _ = try EWSResponse.responseMessages(in: root)
        guard let key = root.first("ItemId")?.attributes["ChangeKey"] else {
            throw EWSError.invalidResponse("Exchange did not return the original message.")
        }
        return key
    }

    /// Sends a message in one request (a draft never saved and with no files): a new message,
    /// or a response object that needs no importance or sensitivity.
    func sendDirect(_ draft: Draft, at url: URL, credential: EWSCredential) async throws {
        let fields = ComposeSOAP.Fields(draft)
        let body: String
        if let original = draft.originalID, draft.kind != .new, draft.style == .standard, draft.quotedSelection == nil {
            let key = try await changeKey(of: original, at: url, credential: credential)
            body = ComposeSOAP.response(Self.response(for: draft.kind), to: original, changeKey: key, fields,
                                        newBody: draft.outgoingHTML, .send)
        } else {
            body = ComposeSOAP.message(try await threaded(fields, draft, url: url, credential: credential), .send)
        }
        try EWSResponse.checkSuccess(try await compose(body, url: url, credential: credential))
    }

    /// Saves the draft in Drafts: created the first time (a response object for a reply or a
    /// forward, so the server writes the quote), then rewritten. Returns its id and, for a
    /// newly created response, the server's quote to keep under the user's text.
    func saveDraft(_ draft: Draft, at url: URL, credential: EWSCredential) async throws -> (id: String, baseHTML: String?) {
        if let id = draft.serverID {
            let fields = ComposeSOAP.Fields(draft)
            let body = ComposeSOAP.update(draftID: id, fields, setsSubject: draft.kind == .new || draft.style == .redirect)
            try EWSResponse.checkSuccess(try await compose(body, url: url, credential: credential))
            return (id, nil)
        }
        if let original = draft.originalID, draft.kind != .new, draft.style == .standard, draft.quotedSelection == nil {
            // An empty response first, so the quote the server writes can be read and kept apart
            // from the user's text, then the user's text on top (`update`).
            let key = try await changeKey(of: original, at: url, credential: credential)
            var fields = ComposeSOAP.Fields(draft)
            fields.options = MessageOptions(readReceipt: draft.options.readReceipt, deliveryReceipt: draft.options.deliveryReceipt)
            let created = try ComposeResponse.createdID(try await compose(
                ComposeSOAP.response(Self.response(for: draft.kind), to: original, changeKey: key, fields,
                                     newBody: "", .draft), url: url, credential: credential))
            let saved = try ComposeResponse.savedMessage(try await compose(ComposeSOAP.getDraft(created), url: url, credential: credential))
            var withQuote = draft
            withQuote.serverID = created
            withQuote.baseHTML = saved.html
            let update = ComposeSOAP.update(draftID: created, ComposeSOAP.Fields(withQuote), setsSubject: false)
            try EWSResponse.checkSuccess(try await compose(update, url: url, credential: credential))
            return (created, saved.html)
        }
        let fields = try await threaded(ComposeSOAP.Fields(draft), draft, url: url, credential: credential)
        let id = try ComposeResponse.createdID(try await compose(ComposeSOAP.message(fields, .draft), url: url, credential: credential))
        return (id, nil)
    }

    /// Files, and for Forward as Attachment the original as a message, onto a saved draft, then
    /// sends it.
    func sendSaved(_ id: String, draft: Draft, at url: URL, credential: EWSCredential) async throws {
        if draft.style == .asAttachment, let original = draft.originalID {
            let mime = try ComposeResponse.mime(try await compose(ComposeSOAP.getMime(original), url: url, credential: credential))
            let name = draft.originalSubject.isEmpty ? "Message" : draft.originalSubject
            try EWSResponse.checkSuccess(try await compose(ComposeSOAP.attachMessage(mime: mime, name: name, to: id),
                                                           url: url, credential: credential))
        }
        if !draft.attachments.isEmpty {
            try EWSResponse.checkSuccess(try await compose(ComposeSOAP.attach(draft.attachments, to: id),
                                                           url: url, credential: credential))
        }
        try EWSResponse.checkSuccess(try await compose(ComposeSOAP.sendItem(id), url: url, credential: credential))
    }

    /// A reply to selected text is a new message: the In-Reply-To and References headers keep
    /// it in the original's thread, as a server-built reply would be.
    private func threaded(_ fields: ComposeSOAP.Fields, _ draft: Draft, url: URL,
                          credential: EWSCredential) async throws -> ComposeSOAP.Fields {
        guard draft.quotedSelection != nil, let original = draft.originalID else { return fields }
        let ids = try ComposeResponse.threadIDs(try await compose(ComposeSOAP.getThreadIDs(original), url: url, credential: credential))
        var fields = fields
        fields.inReplyTo = ids.messageID
        fields.references = [ids.references, ids.messageID].filter { !$0.isEmpty }.joined(separator: " ")
        return fields
    }

    func deleteDraft(_ id: String, at url: URL, credential: EWSCredential) async throws {
        try EWSResponse.checkSuccess(try await compose(SOAP.moveToDeletedItems(id: id), url: url, credential: credential))
    }

    func savedMessage(_ id: String, at url: URL, credential: EWSCredential) async throws -> ComposeResponse.SavedMessage {
        try ComposeResponse.savedMessage(try await compose(ComposeSOAP.getDraft(id), url: url, credential: credential))
    }

    func mailTips(sender: String, recipients: [String], at url: URL, credential: EWSCredential) async throws -> [MailTip] {
        try ComposeResponse.mailTips(try await compose(ComposeSOAP.mailTips(sender: sender, recipients: recipients),
                                                       url: url, credential: credential))
    }

    /// Nil when Drafts has no Templates folder.
    func templatesFolderID(at url: URL, credential: EWSCredential) async throws -> String? {
        try EWSResponse.folderID(from: try await compose(ComposeSOAP.findTemplatesFolder, url: url, credential: credential))
    }

    func createTemplatesFolder(at url: URL, credential: EWSCredential) async throws -> String {
        guard let id = try EWSResponse.folderID(from: try await compose(ComposeSOAP.createTemplatesFolder, url: url,
                                                                         credential: credential)) else {
            throw EWSError.invalidResponse("Exchange did not return the new Templates folder.")
        }
        return id
    }

    func items(inFolder id: String, at url: URL, credential: EWSCredential) async throws -> [MailMessage] {
        try EWSResponse.messages(from: try await compose(ComposeSOAP.findItems(inFolder: id), url: url, credential: credential))
    }

    func saveTemplate(_ draft: Draft, in folderID: String, at url: URL, credential: EWSCredential) async throws {
        var fields = ComposeSOAP.Fields(draft, subject: draft.kind == .new ? draft.subject : draft.subjectPreview)
        fields.bcc = []
        try EWSResponse.checkSuccess(try await compose(ComposeSOAP.message(fields, .saveIn(folderID)), url: url, credential: credential))
    }

    static func response(for kind: Draft.Kind) -> SOAP.Response {
        switch kind {
        case .reply: return .reply
        case .replyAll: return .replyAll
        case .forward, .new: return .forward
        }
    }
}
