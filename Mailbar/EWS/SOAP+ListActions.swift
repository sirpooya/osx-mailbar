import Foundation

/// The requests behind M20 (list actions) and M21 (junk and folders).
extension SOAP {

    /// Moves items into one folder. `ReturnNewItemIds` (Exchange 2010 SP1 and later) makes the
    /// reply carry each item's id in its new folder: a moved item gets a new id, and undo needs
    /// it to move the item back.
    static func moveItems(ids: [String], to target: FolderTarget) -> String {
        """
            <m:MoveItem>
              <m:ToFolderId>\(target.xml)</m:ToFolderId>
              <m:ItemIds>\(itemIDs(ids))</m:ItemIds>
              <m:ReturnNewItemIds>true</m:ReturnNewItemIds>
            </m:MoveItem>
        """
    }

    /// Mark as Junk (and Block Sender, which is the same request): Exchange adds the sender to
    /// the mailbox's Blocked Senders and moves the item to Junk Email. `junk` false is Not Junk:
    /// the sender comes off that list and the item goes back to the Inbox. Exchange 2013 and
    /// later; the app hides these actions on older servers.
    static func markAsJunk(ids: [String], junk: Bool) -> String {
        """
            <m:MarkAsJunk IsJunk="\(junk)" MoveItem="true">
              <m:ItemIds>\(itemIDs(ids))</m:ItemIds>
            </m:MarkAsJunk>
        """
    }

    /// Empties Deleted Items or Junk Email. The one place this app deletes anything for good,
    /// and only after the user confirms (the user's decision, 2026-11-16): `SoftDelete` for
    /// Deleted Items, which the server keeps in its recoverable items for its retention time,
    /// and `MoveToDeletedItems` for Junk. Never `HardDelete`.
    static func emptyFolder(_ target: FolderTarget, deleteType: EmptyDeleteType) -> String {
        """
            <m:EmptyFolder DeleteType="\(deleteType.rawValue)" DeleteSubFolders="false">
              <m:FolderIds>\(target.xml)</m:FolderIds>
            </m:EmptyFolder>
        """
    }

    enum EmptyDeleteType: String, Sendable {
        case softDelete = "SoftDelete"
        case moveToDeletedItems = "MoveToDeletedItems"
    }

    /// A folder's item count, for the "delete N items?" question.
    static func folderCount(_ target: FolderTarget) -> String {
        """
            <m:GetFolder>
              <m:FolderShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties><t:FieldURI FieldURI="folder:TotalCount"/></t:AdditionalProperties>
              </m:FolderShape>
              <m:FolderIds>\(target.xml)</m:FolderIds>
            </m:GetFolder>
        """
    }

    /// The well-known folders' ids, so the tree can show them as the standard views and leave
    /// Drafts and Outbox out. Only names every server from 2010 SP2 accepts.
    static let wellKnownNames = ["inbox", "sentitems", "deleteditems", "junkemail", "drafts", "outbox"]

    static let wellKnownFolders = """
        <m:GetFolder>
          <m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>
          <m:FolderIds>\(wellKnownNames.map { #"<t:DistinguishedFolderId Id="\#($0)"/>"# }.joined())</m:FolderIds>
        </m:GetFolder>
    """

    /// Every folder under the top of the mailbox, all levels, with what the tree needs. The
    /// reply is filtered by the caller: mail folders only (`IPF.Note`), hidden ones left out
    /// (PidTagAttributeHidden, 0x10F4).
    static let mailFolderTree = """
        <m:FindFolder Traversal="Deep">
          <m:FolderShape>
            <t:BaseShape>IdOnly</t:BaseShape>
            <t:AdditionalProperties>
              <t:FieldURI FieldURI="folder:DisplayName"/>
              <t:FieldURI FieldURI="folder:ParentFolderId"/>
              <t:FieldURI FieldURI="folder:FolderClass"/>
              <t:ExtendedFieldURI PropertyTag="0x10F4" PropertyType="Boolean"/>
            </t:AdditionalProperties>
          </m:FolderShape>
          <m:IndexedPageFolderView MaxEntriesReturned="500" Offset="0" BasePoint="Beginning"/>
          <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds>
        </m:FindFolder>
    """

    /// Read state for many items in one request: one `ItemChange` each, as `setRead` builds it.
    static func setRead(ids: [String], read: Bool, modern: Bool) -> String {
        batch(ids.map { setRead(id: $0, read: read, modern: modern) })
    }

    static func setFlag(ids: [String], flagged: Bool, modern: Bool) -> String {
        batch(ids.map { setFlag(id: $0, flagged: flagged, modern: modern) })
    }

    /// Several one-item `UpdateItem` requests as one, keeping each item's own change exactly as
    /// the one-item builder wrote it.
    static func batch(_ singles: [String]) -> String {
        guard let first = singles.first,
              let open = first.range(of: "<m:ItemChanges>"),
              let close = first.range(of: "</m:ItemChanges>") else { return singles.first ?? "" }
        let changes = singles.compactMap { single -> String? in
            guard let start = single.range(of: "<t:ItemChange>"),
                  let end = single.range(of: "</t:ItemChange>") else { return nil }
            return String(single[start.lowerBound..<end.upperBound])
        }
        return String(first[..<open.upperBound]) + "\n" + changes.joined(separator: "\n") + "\n" + String(first[close.lowerBound...])
    }

    /// The message's headers, for `List-Unsubscribe`: the parsed list (`item:InternetMessageHeaders`)
    /// and the raw block (PidTagTransportMessageHeaders, 0x007D), since the parsed list leaves
    /// some headers out on some servers.
    static func unsubscribeHeaders(id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
                  <t:FieldURI FieldURI="item:InternetMessageHeaders"/>
                  <t:ExtendedFieldURI PropertyTag="0x007D" PropertyType="String"/>
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    private static func itemIDs(_ ids: [String]) -> String {
        ids.map { #"<t:ItemId Id="\#(escape($0))"/>"# }.joined()
    }
}

extension EWSResponse {
    /// Each moved item's new id, in the order asked, nil where the server gave none (a move
    /// to another mailbox, or a server before 2010 SP1). `MarkAsJunk` names it `MovedItemId`.
    static func movedIDs(from data: Data) throws -> [String?] {
        let root = try parse(data)
        return try responseMessages(in: root).map { message in
            message.first("MovedItemId")?.attributes["Id"] ?? message.first("ItemId")?.attributes["Id"]
        }
    }

    static func totalCount(from data: Data) throws -> Int {
        let root = try parse(data)
        let messages = try responseMessages(in: root)
        return messages.first?.first("TotalCount").flatMap { Int($0.trimmedText) } ?? 0
    }

    /// Distinguished name to folder id, from `SOAP.wellKnownFolders`, in the order asked. A
    /// folder the server refused is simply missing; this never throws for one of them.
    static func wellKnownFolderIDs(from data: Data) throws -> [String: String] {
        let root = try parse(data)
        if root.first("Fault") != nil { _ = try responseMessages(in: root) }
        guard let container = root.first("ResponseMessages") else { return [:] }
        var found: [String: String] = [:]
        for (name, message) in zip(SOAP.wellKnownNames, container.children)
        where message.attributes["ResponseClass"] != "Error" {
            if let id = message.first("FolderId")?.attributes["Id"] { found[name] = id }
        }
        return found
    }

    /// The mail folders, as a tree flattened into menu order: each folder followed by its
    /// children, siblings by name, the standard folders first at the top in Outlook's order.
    /// Drafts and Outbox, hidden folders and folders of other kinds are left out.
    static func mailFolders(from data: Data, wellKnown: [String: String], archiveID: String?) throws -> [MailboxFolder] {
        let root = try parse(data)
        guard let response = try responseMessages(in: root).first else { return [] }
        struct Node { let id: String; let name: String; let parent: String? }
        var nodes: [Node] = []
        let kinds = Dictionary(wellKnown.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let skipped = Set(["drafts", "outbox"].compactMap { wellKnown[$0] })
        var excluded = Set<String>()
        for folder in response.all("Folder") + response.all("SearchFolder") {
            guard let id = folder.child("FolderId")?.attributes["Id"] else { continue }
            let folderClass = folder.child("FolderClass")?.trimmedText ?? ""
            let hidden = folder.all("ExtendedProperty").contains {
                $0.first("ExtendedFieldURI")?.attributes["PropertyTag"]?.lowercased() == "0x10f4"
                    && $0.child("Value")?.trimmedText.lowercased() == "true"
            }
            if folder.name == "SearchFolder" || hidden || skipped.contains(id)
                || !(folderClass.isEmpty || folderClass.hasPrefix("IPF.Note")) {
                excluded.insert(id)
                continue
            }
            nodes.append(Node(id: id, name: folder.child("DisplayName")?.trimmedText ?? "",
                              parent: folder.child("ParentFolderId")?.attributes["Id"]))
        }
        // A folder under one that was left out goes with it.
        var changed = true
        while changed {
            changed = false
            for node in nodes where !excluded.contains(node.id) {
                if let parent = node.parent, excluded.contains(parent) {
                    excluded.insert(node.id)
                    changed = true
                }
            }
        }
        nodes.removeAll { excluded.contains($0.id) }
        let ids = Set(nodes.map(\.id))
        let children = Dictionary(grouping: nodes) { node in node.parent.flatMap { ids.contains($0) ? $0 : nil } ?? "" }
        let order = ["inbox", "sentitems", "archive", "deleteditems", "junkemail"]
        func kind(_ node: Node) -> String? {
            kinds[node.id] ?? (node.id == archiveID ? "archive" : nil)
        }
        func sorted(_ list: [Node]) -> [Node] {
            list.sorted { a, b in
                let rankA = kind(a).flatMap { order.firstIndex(of: $0) } ?? order.count
                let rankB = kind(b).flatMap { order.firstIndex(of: $0) } ?? order.count
                if rankA != rankB { return rankA < rankB }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        var flat: [MailboxFolder] = []
        func walk(_ parent: String, depth: Int) {
            for node in sorted(children[parent] ?? []) {
                flat.append(MailboxFolder(id: node.id, name: node.name, depth: depth, wellKnown: kind(node)))
                walk(node.id, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        return flat
    }

    /// The `List-Unsubscribe` header's links, or nil when the message has none.
    static func unsubscribeLink(from data: Data) throws -> UnsubscribeLink? {
        let root = try parse(data)
        guard let item = try responseMessages(in: root).first else { return nil }
        let parsed = item.all("InternetMessageHeader").first {
            $0.attributes["HeaderName"]?.lowercased() == "list-unsubscribe"
        }?.trimmedText
        let raw = item.all("ExtendedProperty").first {
            $0.first("ExtendedFieldURI")?.attributes["PropertyTag"]?.lowercased() == "0x7d"
                || $0.first("ExtendedFieldURI")?.attributes["PropertyTag"]?.lowercased() == "0x007d"
        }?.child("Value")?.text
        guard let header = parsed ?? raw.flatMap(UnsubscribeLink.header(inRawHeaders:)) else { return nil }
        return UnsubscribeLink.parse(header)
    }
}

extension EWSClient {
    /// Moves items and returns their new ids, in the order given.
    func moveItems(_ ids: [String], to target: FolderTarget, at url: URL, credential: EWSCredential) async throws -> [String?] {
        guard !ids.isEmpty else { return [] }
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.moveItems(ids: ids, to: target)),
                                     to: url, credential: credential)
        return try EWSResponse.movedIDs(from: data)
    }

    /// Exchange 2013 and later only.
    func markAsJunk(_ ids: [String], junk: Bool, at url: URL, credential: EWSCredential) async throws -> [String?] {
        guard !ids.isEmpty else { return [] }
        let data = try await sendRaw(SOAP.envelope(.exchange2013, body: SOAP.markAsJunk(ids: ids, junk: junk)),
                                     to: url, credential: credential)
        return try EWSResponse.movedIDs(from: data)
    }

    func setRead(_ read: Bool, ids: [String], modern: Bool, at url: URL, credential: EWSCredential) async throws {
        guard !ids.isEmpty else { return }
        let data = try await sendRaw(SOAP.envelope(modern ? .exchange2013 : .exchange2010SP2,
                                                   body: SOAP.setRead(ids: ids, read: read, modern: modern)),
                                     to: url, credential: credential)
        try EWSResponse.checkSuccess(data)
    }

    func setFlag(_ flagged: Bool, ids: [String], modern: Bool, at url: URL, credential: EWSCredential) async throws {
        guard !ids.isEmpty else { return }
        let data = try await sendRaw(SOAP.envelope(modern ? .exchange2013 : .exchange2010SP2,
                                                   body: SOAP.setFlag(ids: ids, flagged: flagged, modern: modern)),
                                     to: url, credential: credential)
        try EWSResponse.checkSuccess(data)
    }

    func emptyFolder(_ target: FolderTarget, deleteType: SOAP.EmptyDeleteType, at url: URL, credential: EWSCredential) async throws {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.emptyFolder(target, deleteType: deleteType)),
                                     to: url, credential: credential)
        try EWSResponse.checkSuccess(data)
    }

    func folderCount(_ target: FolderTarget, at url: URL, credential: EWSCredential) async throws -> Int {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.folderCount(target)),
                                     to: url, credential: credential)
        return try EWSResponse.totalCount(from: data)
    }

    /// The mailbox's mail folders, flattened in menu order (see `EWSResponse.mailFolders`).
    func mailFolders(archiveID: String?, at url: URL, credential: EWSCredential) async throws -> [MailboxFolder] {
        let known = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.wellKnownFolders),
                                      to: url, credential: credential)
        let tree = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.mailFolderTree),
                                     to: url, credential: credential)
        return try EWSResponse.mailFolders(from: tree, wellKnown: EWSResponse.wellKnownFolderIDs(from: known),
                                           archiveID: archiveID)
    }

    func unsubscribeLink(for id: String, at url: URL, credential: EWSCredential) async throws -> UnsubscribeLink? {
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.unsubscribeHeaders(id: id)),
                                     to: url, credential: credential)
        return try EWSResponse.unsubscribeLink(from: data)
    }
}
