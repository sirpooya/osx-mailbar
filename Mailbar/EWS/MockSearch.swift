import Foundation

/// The mock server's search (2026-11-16): `FindItem` over several folders with each item's
/// `ParentFolderId`, AQS keywords in `QueryString`, an Online Archive for the work account
/// (none for the team one), and calendar events found by `QueryString`. Every name and
/// address is invented. DEBUG and tests only, like the rest of `MockTransport`.
enum MockSearch {

    /// The reply to a search request, or nil when the request is not one of these.
    /// `mail` gives a folder's fixture messages by distinguished id or folder id.
    static func reply(to request: String, prefix: String, isTeam: Bool, empty: Bool,
                      itemID: String?,
                      mail: (String) -> [MockFixtures.Message],
                      events: () -> [MockCalendar.Event]) -> String? {
        if request.contains("<m:GetFolder>"), request.contains(#"Id="archivemsgfolderroot""#) {
            return isTeam ? folderNotFound : archiveRoot
        }
        if request.contains("<m:FindFolder"), request.contains(#"Id="archivemsgfolderroot""#) {
            return isTeam ? folderNotFound : archiveTree
        }
        if request.contains("<m:GetItem>"), let itemID, itemID.contains("-oa-"),
           let message = archiveMailbox(prefix).first(where: { $0.id == itemID }) {
            return MockFixtures.getItem(message)
        }
        if request.contains("<m:FindItem"), !request.contains("<m:CalendarView"),
           request.contains(#"<m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/>"#) {
            let query = queryText(in: request)
            let found = isTeam || empty ? [] : events().filter { event in
                query.map { matches(event, query: $0, exact: !request.contains("<m:QueryString>")) } ?? true
            }
            return MockCalendar.findResponse(start: .distantPast, end: .distantFuture, events: found)
        }
        guard request.contains("<m:FindItem"), request.contains(#"FieldURI="item:ParentFolderId""#),
              let parents = firstMatch("<m:ParentFolderIds>(.*?)</m:ParentFolderIds>", in: request) else { return nil }
        let ids = matches(#"Id="([^"]+)""#, in: parents)
        let query = queryText(in: request)
        let modern = request.contains("<m:QueryString>")
        var hits: [(MockFixtures.Message, String)] = []
        for id in ids {
            let messages = id.hasPrefix("\(prefix)-oa-folder") ? archiveMailbox(prefix).filter { $0.id.hasPrefix(id.replacingOccurrences(of: "-folder", with: "")) }
                : mail(id)
            for message in messages where query.map({ matches(message, query: $0, exact: !modern) }) ?? true {
                hits.append((message, id))
            }
        }
        if empty { hits = [] }
        hits.sort { $0.0.hoursAgo < $1.0.hoursAgo }
        var xml = MockFixtures.findItem(hits.map(\.0))
        for (index, hit) in hits.enumerated() {
            let tag = #"<t:ItemId Id="\#(hit.0.id)" ChangeKey="ck-\#(index)"/>"#
            xml = xml.replacingOccurrences(of: tag, with: tag + #"<t:ParentFolderId Id="\#(hit.1)" ChangeKey="f"/>"#)
        }
        return xml
    }

    /// The query string (2013 and later), or the first substring constant (older servers).
    private static func queryText(in request: String) -> String? {
        (firstMatch("<m:QueryString>([^<]*)</m:QueryString>", in: request)
            ?? firstMatch(#"<t:Contains[^>]*><t:FieldURI[^>]*/><t:Constant Value="([^"]*)"/>"#, in: request))
            .map(unescape)
    }

    /// AQS read the way Exchange's index would: every plain word somewhere in the item, each
    /// keyword on its own field. `exact` (an older server's substring) matches the text whole.
    static func matches(_ message: MockFixtures.Message, query: String, exact: Bool = false, now: Date = Date()) -> Bool {
        func has(_ text: String, _ needle: String) -> Bool {
            SearchHighlight.fold(text).range(of: SearchHighlight.fold(needle),
                                             options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let everything = "\(message.sender) \(message.address) \(message.to ?? "") \(message.subject) \(message.preview)"
        if exact { return has(everything, query) }
        let parsed = ParsedSearch.parse(query, now: now)
        let received = now.addingTimeInterval(-message.hoursAgo * 3600)
        if parsed.words.contains(where: { !has(everything, $0) }) { return false }
        if parsed.from.contains(where: { !has("\(message.sender) \(message.address)", $0) }) { return false }
        if parsed.to.contains(where: { !has(message.to ?? "Sample User sample.user@example.com", $0) }) { return false }
        if parsed.subject.contains(where: { !has(message.subject, $0) }) { return false }
        if let attachments = parsed.hasAttachments, attachments != (message.hasAttachments || !message.files.isEmpty) { return false }
        if let after = parsed.after, received < after { return false }
        if let before = parsed.before, received >= before { return false }
        return true
    }

    private static func matches(_ event: MockCalendar.Event, query: String, exact: Bool) -> Bool {
        let text = SearchHighlight.fold("\(event.subject) \(event.location)").lowercased()
        let words = exact ? [query] : ParsedSearch.parse(query).words
        return words.allSatisfy { text.contains(SearchHighlight.fold($0).lowercased()) }
    }

    // MARK: - The Online Archive (work account only)

    static let archiveFolders = [("folder-2024", "Archive 2024"), ("folder-projects", "Old Projects")]

    /// Old mail in the Online Archive, ids `<prefix>-oa-2024-n` and `<prefix>-oa-projects-n`.
    static func archiveMailbox(_ prefix: String) -> [MockFixtures.Message] {
        guard prefix == "work" else { return [] }
        let year: [MockFixtures.Message] = [
            .init(sender: "Sara Rahimi", address: "sara.rahimi@example.com",
                  subject: "Design review: last year's component audit",
                  preview: "The audit is attached; most review notes are about spacing and colour tokens.",
                  hoursAgo: 24 * 380, isRead: true, hasAttachments: true),
            .init(sender: "Finance", address: "finance@example.com",
                  subject: "Expense deadline reminder (2024)",
                  preview: "Please file every receipt before the books close.",
                  hoursAgo: 24 * 410, isRead: true),
        ]
        let projects: [MockFixtures.Message] = [
            .init(sender: "Omid Karimi", address: "omid@example.org",
                  subject: "Project Atlas wrap-up and review",
                  preview: "Thanks everyone; the retrospective notes are in the shared folder.",
                  hoursAgo: 24 * 520, isRead: true),
        ]
        func numbered(_ list: [MockFixtures.Message], _ folder: String) -> [MockFixtures.Message] {
            list.enumerated().map { index, message in
                var message = message
                message.id = "\(prefix)-oa-\(folder)-\(index)"
                return message
            }
        }
        return numbered(year, "2024") + numbered(projects, "projects")
    }

    private static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Header>
            <h:ServerVersionInfo MajorVersion="15" MinorVersion="1" MajorBuildNumber="2507" MinorBuildNumber="6" \
        xmlns:h="http://schemas.microsoft.com/exchange/services/2006/types"/>
          </s:Header>
          <s:Body>
        \(body)
          </s:Body>
        </s:Envelope>
        """
    }

    private static let namespaces = #"xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types""#

    private static let folderNotFound = envelope("""
        <m:GetFolderResponse \(namespaces)><m:ResponseMessages>\
        <m:GetFolderResponseMessage ResponseClass="Error"><m:MessageText>The specified folder could not be found in the store.</m:MessageText>\
        <m:ResponseCode>ErrorFolderNotFound</m:ResponseCode></m:GetFolderResponseMessage></m:ResponseMessages></m:GetFolderResponse>
        """)

    private static let archiveRoot = envelope("""
        <m:GetFolderResponse \(namespaces)><m:ResponseMessages>\
        <m:GetFolderResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
        <m:Folders><t:Folder><t:FolderId Id="work-oa-root" ChangeKey="f"/></t:Folder></m:Folders>\
        </m:GetFolderResponseMessage></m:ResponseMessages></m:GetFolderResponse>
        """)

    private static var archiveTree: String {
        let folders = archiveFolders.map { id, name in
            """
            <t:Folder><t:FolderId Id="work-oa-\(id)" ChangeKey="f"/><t:ParentFolderId Id="work-oa-root"/>\
            <t:FolderClass>IPF.Note</t:FolderClass><t:DisplayName>\(name)</t:DisplayName></t:Folder>
            """
        }.joined()
        return envelope("""
            <m:FindFolderResponse \(namespaces)><m:ResponseMessages>\
            <m:FindFolderResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
            <m:RootFolder TotalItemsInView="\(archiveFolders.count)" IncludesLastItemInRange="true"><t:Folders>\(folders)</t:Folders></m:RootFolder>\
            </m:FindFolderResponseMessage></m:ResponseMessages></m:FindFolderResponse>
            """)
    }

    // MARK: - Helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
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
