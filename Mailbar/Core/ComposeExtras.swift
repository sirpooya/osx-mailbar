import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// The pieces of writing mail added in M23 to M25: message options, outgoing files, MailTips,
// signatures, the composer's settings, mailto: links, and the store's compose state.

/// Importance, sensitivity and receipts: Outlook's Options for one message.
struct MessageOptions: Equatable, Sendable {
    enum Importance: String, CaseIterable, Sendable { case low = "Low", normal = "Normal", high = "High" }
    enum Sensitivity: String, CaseIterable, Sendable {
        case normal = "Normal", personal = "Personal", privacy = "Private", confidential = "Confidential"
    }

    var importance: Importance = .normal
    var sensitivity: Sensitivity = .normal
    var readReceipt = false
    var deliveryReceipt = false

    var isDefault: Bool { self == MessageOptions() }
}

/// A file to send. The bytes are in memory only, and go with the draft.
struct OutgoingFile: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let contentType: String
    let data: Data

    /// All files on one message together, as the event form allows.
    static let maxTotal = 25 * 1024 * 1024

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }

    static func from(_ url: URL) throws -> OutgoingFile {
        let data = try Data(contentsOf: url)
        let type = UTTypeLookup.mimeType(forExtension: url.pathExtension)
        return OutgoingFile(name: url.lastPathComponent, contentType: type, data: data)
    }
}

enum UTTypeLookup {
    static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// What the server says about one recipient before sending (`GetMailTips`).
struct MailTip: Equatable, Sendable {
    let address: String
    /// Their automatic reply, when it is on.
    var outOfOffice: String?
    /// A group's size.
    var totalMembers: Int?
    var externalMembers: Int?
    var invalid = false
}

/// The lines a set of tips shows under To: outside the organization, automatic replies, big
/// groups. Outside means another domain than the sender's, or a group with outside members.
enum MailTipLines {
    static let largeAudience = 25

    static func lines(for recipients: [String], tips: [String: MailTip], myAddress: String) -> [String] {
        let domain = myAddress.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        var lines: [String] = []
        let outside = recipients.filter { address in
            let theirs = address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
            return (!domain.isEmpty && !theirs.isEmpty && theirs != domain)
                || (tips[address.lowercased()]?.externalMembers ?? 0) > 0
        }
        if !outside.isEmpty {
            lines.append(outside.count == 1 ? "\(outside[0]) is outside your organization."
                         : "\(outside.count) recipients are outside your organization.")
        }
        for address in recipients {
            guard let tip = tips[address.lowercased()] else { continue }
            if let reply = tip.outOfOffice, !reply.isEmpty {
                lines.append("Automatic reply from \(address): \(reply)")
            }
            if let total = tip.totalMembers, total >= largeAudience {
                lines.append("\(address) goes to \(total) people.")
            }
            if tip.invalid { lines.append("\(address) does not exist on the server.") }
        }
        return lines
    }
}

/// A named signature, the user's own text (configuration, not mailbox data).
struct Signature: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var text: String
}

/// The composer's settings, all in UserDefaults under the `mailbar.` prefix (see `Keys`).
enum ComposeSettings {
    static let signaturesKey = "mailbar.signatures"
    /// Per account: `[accountUUID: signatureUUID]`, for new mail and for replies and forwards.
    static let newSignatureKey = "mailbar.signatureForNew"
    static let replySignatureKey = "mailbar.signatureForReplies"
    static let showCcBccKey = "mailbar.showCcBcc"
    static let alwaysCcMeKey = "mailbar.alwaysCcMe"
    static let alwaysBccMeKey = "mailbar.alwaysBccMe"
    static let undoSendSecondsKey = "mailbar.undoSendSeconds"
    /// Other addresses the user may send from (aliases, shared mailboxes), comma separated.
    static let fromAddressesKey = "mailbar.fromAddresses"

    static let undoChoices = [0, 5, 10, 20]

    static func signatures(_ defaults: UserDefaults = .standard) -> [Signature] {
        guard let data = defaults.data(forKey: signaturesKey),
              let list = try? JSONDecoder().decode([Signature].self, from: data) else { return [] }
        return list
    }

    static func setSignatures(_ list: [Signature], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(list), forKey: signaturesKey)
    }

    static func signatureChoice(_ key: String, account: UUID, _ defaults: UserDefaults = .standard) -> UUID? {
        (defaults.dictionary(forKey: key)?[account.uuidString] as? String).flatMap(UUID.init(uuidString:))
    }

    static func setSignatureChoice(_ key: String, account: UUID, signature: UUID?, _ defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: key) ?? [:]
        map[account.uuidString] = signature?.uuidString
        defaults.set(map, forKey: key)
    }

    /// The signature for a draft of this kind from this account, or nil.
    static func signature(for kind: Draft.Kind, account: UUID, _ defaults: UserDefaults = .standard) -> Signature? {
        let key = kind == .new ? newSignatureKey : replySignatureKey
        guard let id = signatureChoice(key, account: account, defaults) else { return nil }
        return signatures(defaults).first { $0.id == id }
    }

    static func undoSeconds(_ defaults: UserDefaults = .standard) -> Int {
        #if DEBUG
        // `--undo-seconds=20` (mock mode), to photograph the Sending toast.
        if MockMode.current != nil,
           let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--undo-seconds=") }),
           let seconds = Int(flag.dropFirst("--undo-seconds=".count)) { return seconds }
        #endif
        guard defaults.object(forKey: undoSendSecondsKey) != nil else { return 5 }
        return min(max(defaults.integer(forKey: undoSendSecondsKey), 0), 20)
    }

    static func showCcBcc(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: showCcBccKey) }
    static func alwaysCcMe(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: alwaysCcMeKey) }
    static func alwaysBccMe(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: alwaysBccMeKey) }

    static func fromAddresses(_ defaults: UserDefaults = .standard) -> [String] {
        Recipients.parse(defaults.string(forKey: fromAddressesKey) ?? "").filter(Recipients.isValid)
    }

    /// The text a signature adds under a fresh draft's (empty) body.
    static func signatureBlock(_ signature: Signature) -> String {
        "\n\n" + signature.text
    }
}

/// A `mailto:` link, RFC 6068: addresses before `?`, then `to`, `cc`, `bcc`, `subject`, `body`.
struct MailtoLink: Equatable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var body = ""

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        func decode(_ text: Substring) -> String {
            (String(text).replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? String(text))
        }
        to = Recipients.parse(decode(parts.first ?? ""))
        guard parts.count > 1 else { return }
        for pair in parts[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = kv[0].lowercased()
            let value = kv.count > 1 ? decode(kv[1]) : ""
            switch key {
            case "to": to += Recipients.parse(value)
            case "cc": cc += Recipients.parse(value)
            case "bcc": bcc += Recipients.parse(value)
            case "subject": subject = value
            case "body": body = value.replacingOccurrences(of: "\r\n", with: "\n")
            default: break
            }
        }
    }
}

/// The composer's working state that is not the draft itself. In memory only.
@MainActor
@Observable
final class ComposeState {
    /// A sent message held back for Undo Send.
    struct PendingSend: Equatable {
        let draft: Draft
        let deadline: Date
    }

    var pending: PendingSend?
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    /// A held send that then failed: the reason, shown with a way back to the message.
    var sendFailure: String?

    /// Server copy status, for the composer's footer.
    enum SaveStatus: Equatable { case idle, saving, saved(Date), failed(String) }
    var saveStatus: SaveStatus = .idle
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
    /// The save under way, which a send waits for so the message is never created twice.
    @ObservationIgnored var savingTask: Task<Void, Never>?
    var isSendingHeld = false

    /// MailTips by lowercased address, asked once per address per session.
    var mailTips: [String: MailTip] = [:]
    @ObservationIgnored var tipsAsked: Set<String> = []

    /// Check Names: typed names that did not resolve to one person, with what the server offered.
    var unresolved: [String: [PersonSuggestion]] = [:]
    var isCheckingNames = false

    /// The rich editor's text, so formatting survives the composer closing and reopening.
    @ObservationIgnored var richText: NSAttributedString?
    @ObservationIgnored var richDraftID: UUID?

    /// Templates: the Drafts/Templates folder per account, and what it holds.
    @ObservationIgnored var templatesFolder: [UUID: String] = [:]
    var templates: [MailMessage] = []
    var templatesLoading = false
    /// The composer asks before creating the Templates folder, as Archive does.
    var asksToCreateTemplates = false
    var notice: String?

    /// Fetching the original's files for Redirect and Resend.
    var isPreparing = false
}
