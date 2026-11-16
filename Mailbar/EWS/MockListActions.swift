import Foundation

/// Mock replies for M20 (list actions) and M21 (junk and folders). Invented folders and mail
/// only. The memory of where each item went lives in `MockTransport`.
extension MockFixtures {

    /// Distinguished name to the mock folder id, as `GetFolder` would report it.
    static func wellKnownID(_ name: String, prefix: String) -> String { "\(prefix)-wk-\(name)" }

    /// The mailbox's folders under the top: the standard ones, custom ones a level or two deep,
    /// a Persian one, and some the app must leave out (a calendar, a hidden folder, Drafts'
    /// child). `(id, name, parent, class, hidden)`.
    static func folderTree(prefix: String) -> [(String, String, String, String, Bool)] {
        let root = "\(prefix)-root"
        let wk = { (name: String) in wellKnownID(name, prefix: prefix) }
        var folders: [(String, String, String, String, Bool)] = [
            (wk("inbox"), "Inbox", root, "IPF.Note", false),
            (wk("drafts"), "Drafts", root, "IPF.Note", false),
            ("\(prefix)-folder-templates", "Templates", wk("drafts"), "IPF.Note", false),
            (wk("sentitems"), "Sent Items", root, "IPF.Note", false),
            (wk("deleteditems"), "Deleted Items", root, "IPF.Note", false),
            (wk("junkemail"), "Junk Email", root, "IPF.Note", false),
            (wk("outbox"), "Outbox", root, "IPF.Note", false),
            ("\(prefix)-calendar", "Calendar", root, "IPF.Appointment", false),
            ("\(prefix)-folder-hidden", "Conversation Action Settings", root, "IPF.Note", true),
        ]
        if prefix == "work" {
            folders += [
                ("work-archive", "Archive", root, "IPF.Note", false),
                ("work-folder-receipts", "Receipts", wk("inbox"), "IPF.Note", false),
                ("work-folder-projects", "Projects", root, "IPF.Note", false),
                ("work-folder-atlas", "Atlas", "work-folder-projects", "IPF.Note", false),
                ("work-folder-budget", "Budget 2026", "work-folder-projects", "IPF.Note", false),
                ("work-folder-reports", "گزارش‌ها", root, "IPF.Note", false),
                ("work-folder-newsletters", "Newsletters", root, "", false),
            ]
        } else {
            folders.append(("team-folder-shared", "Shared", root, "IPF.Note", false))
        }
        return folders
    }

    /// Mail that lives in the custom folders from the start, by folder id.
    static let folderMail: [String: [Message]] = [
        "work-folder-atlas": [
            Message(sender: "Narges Ahmadi", address: "narges@example.com", subject: "Atlas: kickoff notes",
                    preview: "Scope, owners and the first three milestones, as agreed on Monday.",
                    hoursAgo: 52, isRead: true),
            Message(sender: "Omid Karimi", address: "omid@example.org", subject: "Atlas weekly status",
                    preview: "Two items slipped a week; the rest is on track.", hoursAgo: 170, isRead: true,
                    isFlagged: true),
        ],
        "work-folder-receipts": [
            Message(sender: "Travel Desk", address: "travel@example.com", subject: "Receipt: train tickets",
                    preview: "Your booking reference and the receipt are attached.", hoursAgo: 300, isRead: true,
                    hasAttachments: true),
        ],
    ]

    /// The `List-Unsubscribe` header a fixture message carries, if any: the newsletter offers
    /// both ways, the prize mail only a mailto.
    static func unsubscribeHeader(for message: Message) -> String? {
        switch message.address {
        case "news@example.net":
            return "<mailto:leave@news.example.net?subject=unsubscribe>, <https://news.example.net/unsubscribe?list=weekly>"
        case "winner@example.net":
            return "<mailto:stop@example.net?subject=Remove%20me>"
        default:
            return nil
        }
    }

    static func getFolders(_ folders: [(id: String, total: Int)]) -> String {
        let messages = folders.map { folder in
            """
            <m:GetFolderResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
            <m:Folders><t:Folder><t:FolderId Id="\(folder.id)" ChangeKey="f"/><t:TotalCount>\(folder.total)</t:TotalCount></t:Folder></m:Folders>\
            </m:GetFolderResponseMessage>
            """
        }.joined()
        return envelope("GetFolder", messages)
    }

    static func findFolderTree(prefix: String) -> String {
        let folders = folderTree(prefix: prefix).map { id, name, parent, folderClass, hidden in
            """
            <t:Folder><t:FolderId Id="\(id)" ChangeKey="f"/><t:ParentFolderId Id="\(parent)" ChangeKey="p"/>\
            \(folderClass.isEmpty ? "" : "<t:FolderClass>\(folderClass)</t:FolderClass>")\
            <t:DisplayName>\(SOAP.escape(name))</t:DisplayName>\
            \(hidden ? #"<t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x10f4" PropertyType="Boolean"/><t:Value>true</t:Value></t:ExtendedProperty>"# : "")\
            </t:Folder>
            """
        }.joined()
        return envelope("FindFolder", """
            <m:FindFolderResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
            <m:RootFolder TotalItemsInView="\(folderTree(prefix: prefix).count)" IncludesLastItemInRange="true">\
            <t:Folders>\(folders)</t:Folders></m:RootFolder></m:FindFolderResponseMessage>
            """)
    }

    /// `MoveItem` and `MarkAsJunk` replies, with each item's id in its new folder.
    static func moved(_ ids: [String], operation: String) -> String {
        let messages = ids.map { id in
            let item = operation == "MarkAsJunk"
                ? #"<m:MovedItemId Id="\#(id)" ChangeKey="ck"/>"#
                : #"<m:Items><t:Message><t:ItemId Id="\#(id)" ChangeKey="ck"/></t:Message></m:Items>"#
            return """
            <m:\(operation)ResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\(item)</m:\(operation)ResponseMessage>
            """
        }.joined()
        return envelope(operation, messages)
    }

    static func headers(id: String, unsubscribe: String?) -> String {
        let header = unsubscribe.map { #"<t:InternetMessageHeader HeaderName="List-Unsubscribe">\#(SOAP.escape($0))</t:InternetMessageHeader>"# } ?? ""
        return envelope("GetItem", """
            <m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
            <m:Items><t:Message><t:ItemId Id="\(id)" ChangeKey="ck"/><t:InternetMessageHeaders>\
            <t:InternetMessageHeader HeaderName="Subject">mock</t:InternetMessageHeader>\(header)\
            </t:InternetMessageHeaders></t:Message></m:Items></m:GetItemResponseMessage>
            """)
    }

    private static func envelope(_ operation: String, _ messages: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <m:\(operation)Response xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>\(messages)</m:ResponseMessages>
            </m:\(operation)Response>
          </s:Body>
        </s:Envelope>
        """
    }
}
