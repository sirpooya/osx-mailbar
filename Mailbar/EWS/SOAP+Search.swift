import Foundation

// Search across folders, the Online Archive, typed keywords and calendar events (2026-11-16).

extension SOAP {

    /// Mail matching `query` in one or more folders, newest first, with each item's
    /// `item:ParentFolderId` so a row can say where it is.
    ///
    /// `FindItem` has no deep traversal (Microsoft's schema allows Shallow, SoftDeleted and
    /// Associated only), so "every folder" is every folder listed in `ParentFolderIds`.
    ///
    /// Exchange 2013 and later: `QueryString`, the server's index, with what was typed passed
    /// through as AQS and the criteria appended. Older servers: a restriction built from the
    /// keywords read here (`ParsedSearch`), the plain words matched in subject or body.
    static func searchMail(in parents: [SearchParent], query: SearchQuery, limit: Int, modern: Bool,
                           now: Date = Date(), calendar: Calendar = .current) -> String {
        var find = findMessages(in: .inbox, limit: limit, modern: modern)
        let subjectField = #"<t:FieldURI FieldURI="item:Subject"/>"#
        if let field = find.range(of: subjectField) {
            find.replaceSubrange(field, with: subjectField + #"<t:FieldURI FieldURI="item:ParentFolderId"/>"#)
        }
        if let open = find.range(of: "<m:ParentFolderIds>"),
           let close = find.range(of: "</m:ParentFolderIds>", range: open.upperBound..<find.endIndex) {
            find.replaceSubrange(open.upperBound..<close.lowerBound, with: parents.map(\.xml).joined())
        }
        if modern {
            return find.replacingOccurrences(of: "</m:ParentFolderIds>",
                                             with: "</m:ParentFolderIds>\n      <m:QueryString>\(escape(query.queryString))</m:QueryString>")
        }
        guard let restriction = mailRestriction(query.parsed(now: now, calendar: calendar)) else { return find }
        return find.replacingOccurrences(of: "      <m:SortOrder>",
                                         with: "      <m:Restriction>\(restriction)</m:Restriction>\n      <m:SortOrder>")
    }

    /// The parts of a typed search an older server can match, ANDed: the plain words in subject
    /// or body (one substring, as M8 did), the sender's name or address, the To line, the
    /// subject, attachments, and the received dates.
    static func mailRestriction(_ parsed: ParsedSearch) -> String? {
        var conditions: [String] = []
        let words = parsed.words.joined(separator: " ")
        if !words.isEmpty {
            conditions.append("<t:Or>\(contains("item:Subject", words))\(contains("item:Body", words))</t:Or>")
        }
        for from in parsed.from {
            // PidTagSenderName and PidTagSenderSmtpAddress: message:From is not a string to match in.
            conditions.append("<t:Or>\(containsTag("0x0C1A", from))\(containsTag("0x5D01", from))</t:Or>")
        }
        for to in parsed.to { conditions.append(contains("item:DisplayTo", to)) }
        for subject in parsed.subject { conditions.append(contains("item:Subject", subject)) }
        if let attachments = parsed.hasAttachments {
            conditions.append(compare("IsEqualTo", "item:HasAttachments", attachments ? "true" : "false"))
        }
        let iso = ISO8601DateFormatter()
        if let after = parsed.after {
            conditions.append(compare("IsGreaterThanOrEqualTo", "item:DateTimeReceived", iso.string(from: after)))
        }
        if let before = parsed.before {
            conditions.append(compare("IsLessThan", "item:DateTimeReceived", iso.string(from: before)))
        }
        switch conditions.count {
        case 0: return nil
        case 1: return conditions[0]
        default: return "<t:And>\(conditions.joined())</t:And>"
        }
    }

    private static func contains(_ field: String, _ value: String) -> String {
        """
        <t:Contains ContainmentMode="Substring" ContainmentComparison="IgnoreCase">\
        <t:FieldURI FieldURI="\(field)"/><t:Constant Value="\(escape(value))"/></t:Contains>
        """
    }

    private static func containsTag(_ tag: String, _ value: String) -> String {
        """
        <t:Contains ContainmentMode="Substring" ContainmentComparison="IgnoreCase">\
        <t:ExtendedFieldURI PropertyTag="\(tag)" PropertyType="String"/><t:Constant Value="\(escape(value))"/></t:Contains>
        """
    }

    private static func compare(_ element: String, _ field: String, _ value: String) -> String {
        """
        <t:\(element)><t:FieldURI FieldURI="\(field)"/>\
        <t:FieldURIOrConstant><t:Constant Value="\(escape(value))"/></t:FieldURIOrConstant></t:\(element)>
        """
    }

    /// Events whose title, place or notes match, for the search's Events section. A plain
    /// `FindItem` on the calendar (not a `CalendarView`, which takes no query): a repeating
    /// event comes back once, as its series. 2013 and later: `QueryString`; older servers: the
    /// title or the location contains the words.
    static func searchEvents(_ text: String, limit: Int, modern: Bool) -> String {
        let fields = ["item:Subject", "calendar:Start", "calendar:End", "calendar:IsAllDayEvent",
                      "calendar:Location", "calendar:IsRecurring", "calendar:MyResponseType"]
            .map { #"          <t:FieldURI FieldURI="\#($0)"/>"# }.joined(separator: "\n")
        let restriction = modern ? "" : """
              <m:Restriction><t:Or>\(contains("item:Subject", text))\(contains("calendar:Location", text))</t:Or></m:Restriction>
        """
        let queryString = modern ? "\n      <m:QueryString>\(escape(text))</m:QueryString>" : ""
        return """
            <m:FindItem Traversal="Shallow">
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
        \(fields)
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:IndexedPageItemView MaxEntriesReturned="\(max(1, limit))" Offset="0" BasePoint="Beginning"/>
        \(restriction)
              <m:SortOrder><t:FieldOrder Order="Descending"><t:FieldURI FieldURI="calendar:Start"/></t:FieldOrder></m:SortOrder>
              <m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds>\(queryString)
            </m:FindItem>
        """
    }

    /// The Online Archive's top, to learn whether the mailbox has one (Exchange 2010 SP1 and
    /// later). A mailbox without one answers with an error, which means "no".
    static let onlineArchiveProbe = """
        <m:GetFolder>
          <m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>
          <m:FolderIds><t:DistinguishedFolderId Id="archivemsgfolderroot"/></m:FolderIds>
        </m:GetFolder>
    """

    /// The Online Archive's mail folders, all levels, read like the mailbox's own tree.
    static var onlineArchiveFolders: String {
        mailFolderTree.replacingOccurrences(of: #"<t:DistinguishedFolderId Id="msgfolderroot"/>"#,
                                            with: #"<t:DistinguishedFolderId Id="archivemsgfolderroot"/>"#)
    }
}

/// One search result and the folder it is in.
struct SearchHit: Sendable {
    let message: MailMessage
    let folderID: String?
}

extension EWSResponse {
    /// Every response message's items (a request over several folders may answer once per
    /// folder), each with its `ParentFolderId`.
    static func searchHits(from data: Data) throws -> [SearchHit] {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        return responses.flatMap { response in
            (response.first("Items")?.children ?? []).compactMap { item in
                message(from: item).map { SearchHit(message: $0, folderID: item.child("ParentFolderId")?.attributes["Id"]) }
            }
        }
    }

    /// Whether the archive probe found a folder. False on an error answer (no archive).
    static func hasFolder(_ data: Data) -> Bool {
        guard let root = try? parse(data), root.first("Fault") == nil,
              let message = root.first("ResponseMessages")?.children.first else { return false }
        return message.attributes["ResponseClass"] == "Success" && message.first("Folder") != nil
    }

    /// Events from a plain `FindItem` on the calendar, each response message's.
    static func searchEvents(from data: Data) throws -> [CalendarEvent] {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        return responses.flatMap { ($0.first("Items")?.children ?? []).compactMap(calendarEvent(from:)) }
    }
}

extension EWSClient {
    func searchMail(in parents: [SearchParent], query: SearchQuery, modern: Bool,
                    at url: URL, credential: EWSCredential, limit: Int = EWSClient.pageSize) async throws -> [SearchHit] {
        let body = SOAP.searchMail(in: parents, query: query, limit: limit, modern: modern)
        let data = try await sendRaw(SOAP.envelope(modern ? .exchange2013 : .exchange2010SP2, body: body),
                                     to: url, credential: credential)
        return try EWSResponse.searchHits(from: data)
    }

    func searchEvents(_ text: String, modern: Bool, at url: URL, credential: EWSCredential,
                      limit: Int = 25) async throws -> [CalendarEvent] {
        let body = SOAP.searchEvents(text, limit: limit, modern: modern)
        let data = try await sendRaw(SOAP.envelope(modern ? .exchange2013 : .exchange2010SP2, body: body),
                                     to: url, credential: credential)
        return try EWSResponse.searchEvents(from: data)
    }

    /// True when the mailbox has an Online Archive, false when the server says it has none.
    /// Throws only when the server could not be asked.
    func hasOnlineArchive(at url: URL, credential: EWSCredential) async throws -> Bool {
        let data: Data
        do {
            data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.onlineArchiveProbe),
                                     to: url, credential: credential)
        } catch EWSError.server {
            return false
        }
        return EWSResponse.hasFolder(data)
    }

    /// The Online Archive's mail folders, flattened like the mailbox's tree.
    func onlineArchiveFolders(at url: URL, credential: EWSCredential) async throws -> [MailboxFolder] {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.onlineArchiveFolders),
                                     to: url, credential: credential)
        return try EWSResponse.mailFolders(from: data, wellKnown: [:], archiveID: nil)
    }
}
