import Foundation
import Observation

// M20 List actions and M21 Junk and folders (2026-11-16): the types and the state behind
// multi-select, the undo toast, row swipes, the folder tree, favorites, emptying a folder and
// unsubscribing. Everything here is in memory, except the favorites and the swipe choices,
// which are configuration (folder ids and names, never mail).

/// A mail folder of the mailbox, from `FindFolder` (M21). Equal by id alone, so a changed name
/// or count is still the same folder (and the same key for its list).
struct MailboxFolder: Hashable, Sendable, Identifiable, Codable {
    let id: String
    var name: String
    /// Steps below the top of the tree, for indenting it in a menu.
    var depth = 0
    /// Which standard folder this is, when it is one (the Inbox, Deleted Items...), so picking
    /// it opens the standard view instead of a second copy of it.
    var wellKnown: String? = nil

    static func == (lhs: MailboxFolder, rhs: MailboxFolder) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private enum CodingKeys: String, CodingKey { case id, name }

    init(id: String, name: String, depth: Int = 0, wellKnown: String? = nil) {
        self.id = id
        self.name = name
        self.depth = depth
        self.wellKnown = wellKnown
    }

    /// The view this folder opens: a standard one for the well-known folders.
    var mailFolder: MailFolder {
        switch wellKnown {
        case "inbox": .inbox
        case "sentitems": .sent
        case "deleteditems": .deleted
        case "junkemail": .junk
        case "archive": .archive
        default: .custom(self)
        }
    }
}

/// Where a `MoveItem` puts mail, or where undo puts it back.
enum FolderTarget: Hashable, Sendable {
    case distinguished(String)
    case id(String)

    var xml: String {
        switch self {
        case .distinguished(let name): #"<t:DistinguishedFolderId Id="\#(SOAP.escape(name))"/>"#
        case .id(let id): #"<t:FolderId Id="\#(SOAP.escape(id))"/>"#
        }
    }
}

/// What a swipe across a row does, set in Settings, General.
enum SwipeAction: String, CaseIterable, Identifiable, Sendable {
    case none
    case archive
    case delete
    case toggleRead
    case flag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .archive: "Archive"
        case .delete: "Delete"
        case .toggleRead: "Mark Read or Unread"
        case .flag: "Flag"
        }
    }

    /// The glyph the row reveals as it slides, for this message.
    func symbol(for message: MailMessage) -> String {
        switch self {
        case .none: ""
        case .archive: "archivebox.fill"
        case .delete: "trash.fill"
        case .toggleRead: message.isRead ? "envelope.badge.fill" : "envelope.open.fill"
        case .flag: message.isFlagged ? "flag.slash.fill" : "flag.fill"
        }
    }

    /// Whether this folder offers the action at all (no Archive in Archive, no Delete in
    /// Deleted Items, as on the row's own buttons).
    func applies(in folder: MailFolder) -> Bool {
        switch self {
        case .none: false
        case .archive: folder.canArchive
        case .delete: folder.canDelete
        case .toggleRead, .flag: true
        }
    }

    static let leftDefault = SwipeAction.delete
    static let rightDefault = SwipeAction.archive

    static func left(_ defaults: UserDefaults = .standard) -> SwipeAction {
        defaults.string(forKey: Keys.swipeLeft).flatMap(SwipeAction.init) ?? leftDefault
    }

    static func right(_ defaults: UserDefaults = .standard) -> SwipeAction {
        defaults.string(forKey: Keys.swipeRight).flatMap(SwipeAction.init) ?? rightDefault
    }
}

extension Keys {
    /// What a two-finger swipe to the left, or to the right, does to a row (M20).
    static let swipeLeft = "mailbar.swipeLeft"
    static let swipeRight = "mailbar.swipeRight"
    /// Favorite folders per account, JSON `{account uuid: [{id, name}]}`. Folder ids and names
    /// only: configuration, never mail (M21).
    static let favoriteFolders = "mailbar.favoriteFolders"
}

/// The `List-Unsubscribe` header's ways out, best first (M20).
struct UnsubscribeLink: Equatable, Sendable {
    var web: URL?
    var mail: UnsubscribeMail?

    var isEmpty: Bool { web == nil && mail == nil }

    /// An https link opens in the browser; a plain-http one only when there is no mailto.
    var preferred: Preferred? {
        if let web, web.scheme?.lowercased() == "https" { return .web(web) }
        if let mail { return .mail(mail) }
        if let web { return .web(web) }
        return nil
    }

    enum Preferred: Equatable {
        case web(URL)
        case mail(UnsubscribeMail)
    }

    /// Reads the header's value: angle-bracketed URIs, comma separated (RFC 2369).
    static func parse(_ header: String) -> UnsubscribeLink? {
        var link = UnsubscribeLink()
        let pattern = try? NSRegularExpression(pattern: "<([^>]+)>")
        let range = NSRange(header.startIndex..., in: header)
        for match in pattern?.matches(in: header, range: range) ?? [] {
            guard let found = Range(match.range(at: 1), in: header) else { continue }
            let raw = header[found].trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = raw.lowercased()
            if lower.hasPrefix("mailto:"), link.mail == nil {
                link.mail = UnsubscribeMail(raw)
            } else if lower.hasPrefix("https:") || lower.hasPrefix("http:"),
                      let url = URL(string: raw) {
                if link.web == nil || (link.web?.scheme == "http" && lower.hasPrefix("https:")) { link.web = url }
            }
        }
        return link.isEmpty ? nil : link
    }

    /// The header from a raw header block (PidTagTransportMessageHeaders), folded lines joined.
    static func header(inRawHeaders raw: String) -> String? {
        var value: String?
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if value != nil, let first = line.first, first == " " || first == "\t" {
                value! += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if value != nil { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "list-unsubscribe" {
                value = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }
}

/// A `mailto:` link: the address, and the subject and body it asks for.
struct UnsubscribeMail: Equatable, Sendable {
    var address: String
    var subject = ""
    var body = ""

    init?(_ raw: String) {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "mailto" else { return nil }
        let address = components.path.removingPercentEncoding ?? components.path
        guard Recipients.isValid(address) else { return nil }
        self.address = address
        for item in components.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": subject = item.value ?? ""
            case "body": body = item.value ?? ""
            default: break
            }
        }
        if subject.isEmpty { subject = "unsubscribe" }
    }
}

/// The toast at the popover's foot after mail moved, with the way to put it back (M20).
struct UndoToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let accountID: UUID
    /// Nil when the server gave no new ids, so nothing can be put back.
    let undo: Undo?

    struct Undo: Equatable {
        /// The moved items' ids where they are now.
        let ids: [String]
        /// Where they came from.
        let back: FolderTarget
        /// Junk is undone with `MarkAsJunk` IsJunk false, which also unblocks the sender.
        let wasJunk: Bool
        /// The rows as they were, for putting them back on screen at once.
        let rows: [MailMessage]
        /// The list they left.
        let folder: MailFolder
    }

    static let seconds: Double = 5
}

/// A question the popover asks before something that cannot be put back (M20, M21).
enum PendingConfirmation: Equatable {
    /// Empty Deleted Items (for good) or Junk Email (into Deleted Items), `count` items.
    case empty(MailFolder, accountID: UUID, count: Int)
    /// Unsubscribe from a list, by opening its page or sending its mail.
    case unsubscribe(UnsubscribeLink.Preferred, sender: String, accountID: UUID)
}

/// The folder tree of one account, as `FindFolder` gave it.
enum FolderTreePhase: Equatable {
    case loading
    case loaded([MailboxFolder])
    case failed

    var folders: [MailboxFolder] {
        if case .loaded(let list) = self { return list }
        return []
    }
}

/// Multi-select, the toast, swipes, the folder trees and favorites: the list's own state,
/// held by the store (`MailStore.listActions`).
@MainActor
@Observable
final class ListActionsState {
    /// Selected rows of the list showing, by item id. Cmd-click toggles, Shift-click extends.
    var selection: Set<String> = []
    /// Where a Shift-click extends from: the last row clicked.
    @ObservationIgnored var anchor: String?
    var toast: UndoToast?
    var pending: PendingConfirmation?
    /// The row under the pointer, which a swipe acts on.
    @ObservationIgnored var hoveredRow: String?
    /// The row following a swipe, and how far it has slid.
    var swipingRow: String?
    var swipeOffset: CGFloat = 0
    var folderTrees: [UUID: FolderTreePhase] = [:]
    /// Unsubscribe links found per message, while the popover is open.
    var unsubscribeLinks: [String: UnsubscribeLink] = [:]
    var favorites: [String: [MailboxFolder]] = ListActionsState.loadFavorites()

    func favorites(for accountID: UUID) -> [MailboxFolder] {
        favorites[accountID.uuidString] ?? []
    }

    func isFavorite(_ folder: MailboxFolder, accountID: UUID) -> Bool {
        favorites(for: accountID).contains(folder)
    }

    func toggleFavorite(_ folder: MailboxFolder, accountID: UUID, persist: Bool = true) {
        var list = favorites(for: accountID)
        if let index = list.firstIndex(of: folder) { list.remove(at: index) } else { list.append(folder) }
        favorites[accountID.uuidString] = list
        guard persist, let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: Keys.favoriteFolders)
    }

    nonisolated private static func loadFavorites() -> [String: [MailboxFolder]] {
        guard let data = UserDefaults.standard.data(forKey: Keys.favoriteFolders),
              let decoded = try? JSONDecoder().decode([String: [MailboxFolder]].self, from: data) else { return [:] }
        return decoded
    }

    /// Ids in list order from the anchor to `id`, for a Shift-click.
    static func range(from anchor: String?, to id: String, in order: [String]) -> [String] {
        guard let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) else { return [id] }
        return Array(order[min(start, end)...max(start, end)])
    }

    /// A click on a row with these modifiers: true when it changed the selection rather than
    /// asking to open the message.
    func click(_ id: String, command: Bool, shift: Bool, order: [String]) -> Bool {
        if shift {
            selection.formUnion(Self.range(from: anchor ?? selection.first, to: id, in: order))
            anchor = anchor ?? id
            return true
        }
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
            return true
        }
        selection = []
        anchor = id
        return false
    }

    func clearSelection() {
        selection = []
        anchor = nil
    }

    /// The rest of a many-row Archive that found no Archive folder, archived once the user
    /// says to create one.
    @ObservationIgnored var pendingArchiveIDs: [String] = []

    func takePendingArchive() -> [String] {
        defer { pendingArchiveIDs = [] }
        return pendingArchiveIDs
    }

    /// The popover closed: what was found about its messages goes with it.
    func popoverClosed() {
        unsubscribeLinks = [:]
        clearSelection()
        swipingRow = nil
        swipeOffset = 0
        if case .unsubscribe = pending { pending = nil }
    }
}

extension MailMessage {
    /// The same row under the id the server gave it in another folder.
    func withID(_ newID: String) -> MailMessage {
        var copy = MailMessage(id: newID, changeKey: "", senderName: senderName, senderAddress: senderAddress,
                               subject: subject, preview: preview, received: received, isRead: isRead,
                               isFlagged: isFlagged, hasAttachments: hasAttachments)
        copy.meeting = meeting
        copy.displayTo = displayTo
        copy.importance = importance
        copy.lastVerb = lastVerb
        copy.isToMe = isToMe
        copy.size = size
        return copy
    }
}
