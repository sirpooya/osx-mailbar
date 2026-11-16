import AppKit
import SwiftUI
import WebKit

/// The popover's line while a sent message waits out Undo Send, and the one after a held send
/// failed. Shown with the other banners, over the list or the reader.
struct ComposeBanners: View {
    @Bindable var store: MailStore

    var body: some View {
        if let pending = store.compose.pending {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(pending.deadline.timeIntervalSince(context.date).rounded(.up)))
                row(symbol: "paperplane.fill", tint: .accentColor,
                    text: store.compose.isSendingHeld ? "Sending..." : "Sending in \(left) s.") {
                    Button("Undo") { store.undoSend() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(store.compose.isSendingHeld)
                    Button("Send Now") { store.sendHeldNow() }
                        .disabled(store.compose.isSendingHeld)
                }
            }
        }
        if let failure = store.compose.sendFailure, !store.isComposing {
            row(symbol: "exclamationmark.triangle.fill", tint: .orange, text: failure) {
                if store.draft != nil {
                    Button("Open") {
                        store.compose.sendFailure = nil
                        store.isComposing = true
                    }
                }
                Button("Dismiss") { store.compose.sendFailure = nil }
            }
        }
        if let notice = store.compose.notice, !store.isComposing {
            row(symbol: "checkmark.circle.fill", tint: .green, text: notice) {
                Button("OK") { store.compose.notice = nil }
            }
        }
    }

    private func row<Actions: View>(symbol: String, tint: Color, text: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack(spacing: 6) { actions() }.controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10))
    }
}

/// The reader's More menu beside Reply, Reply All and Forward: Forward as Attachment,
/// Redirect, and Resend for a message the user sent.
struct ComposeMoreMenu: View {
    @Bindable var store: MailStore
    let body_: MessageBody?
    let accountID: UUID

    var body: some View {
        Menu {
            Button("Forward as Attachment") { start(.asAttachment) }
            Button("Redirect") { start(.redirect) }
            Divider()
            Button("Resend") {
                guard let message = body_ else { return }
                store.startResend(of: message, in: accountID)
            }
            .disabled(!isMine)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(body_ == nil)
        .help("More ways to send this on")
        .accessibilityLabel("More ways to send this on")
    }

    /// Resend is for mail the user sent: from this account, or anything in Sent Items.
    private var isMine: Bool {
        guard let message = body_ else { return false }
        let me = store.accounts.account(accountID)?.email.lowercased() ?? ""
        return store.mailFolder == .sent || (!me.isEmpty && message.from?.address.lowercased() == me)
    }

    private func start(_ style: Draft.Style) {
        guard let message = body_ else { return }
        store.startForward(style, of: message, in: accountID)
    }
}

/// The text selected in the open message, for Reply to Selection. Read by the app's own
/// script in the app's world; the message's scripts stay off.
@MainActor
enum ReaderSelection {
    static func selectedText() async -> String? {
        guard let webView = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(find) }).first else { return nil }
        let value = try? await webView.evaluateJavaScript("window.getSelection().toString()", in: nil, contentWorld: .defaultClient)
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func find(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView, web.window?.isVisible == true { return web }
        for child in view.subviews {
            if let found = find(child) { return found }
        }
        return nil
    }
}

/// Launch flags that put the composer's states on screen without a click, for `mac-qc`. DEBUG
/// and mock mode only, like `QCFlags`.
@MainActor
enum ComposeQC {
    static func value(_ flag: String) -> String? {
        #if DEBUG
        guard MockMode.current != nil else { return nil }
        if CommandLine.arguments.contains(flag) { return "" }
        return CommandLine.arguments.first { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }
        #else
        return nil
        #endif
    }

    static var undoSeconds: Int? { value("--undo-seconds").flatMap(Int.init) }

    private static var applied = false

    static func apply(store: MailStore, editor: RichEditorController, showsBcc: Binding<Bool>) {
        #if DEBUG
        guard MockMode.current != nil, !applied else { return }
        applied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if let start = value("--compose-start"), let account = store.selectedAccount,
               let first = store.state(for: account.id).messages.first,
               let (url, credential) = store.connection(for: account.id),
               let body = try? await store.client.message(id: first.id, at: url, credential: credential) {
                store.discardDraft()
                switch start {
                case "attachment": store.startForward(.asAttachment, of: body, in: account.id)
                case "redirect": store.startForward(.redirect, of: body, in: account.id)
                case "resend": store.startResend(of: body, in: account.id)
                default: store.startResponse(.reply, to: body, in: account.id,
                                             selection: "Could you send the signed form by Thursday?")
                }
                store.prepareDraft()
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let link = value("--mailto").flatMap(URL.init(string:)).flatMap(MailtoLink.init) {
                store.discardDraft()
                store.startMailto(link)
                store.prepareDraft()
            }
            if value("--compose-bcc") != nil {
                showsBcc.wrappedValue = true
                store.draft?.bcc = "omid@example.org, "
            }
            if value("--compose-from") != nil { store.draft?.from = "team@example.com" }
            if value("--compose-options") != nil {
                store.draft?.options = MessageOptions(importance: .high, sensitivity: .confidential, readReceipt: true)
            }
            if value("--mailtips") != nil {
                store.draft?.to = "sara.rahimi@example.com, designteam@example.com, someone@example.net, "
            }
            if value("--compose-check-names") != nil {
                store.draft?.to = "narges, karimi, "
                await store.checkNames()
            }
            if value("--compose-files") != nil {
                store.draft?.attachments = [
                    OutgoingFile(name: "Quarterly report.pdf", contentType: "application/pdf", data: Data(count: 248_000)),
                    OutgoingFile(name: "screenshot.png", contentType: "image/png", data: Data(count: 61_000)),
                ]
            }
            if value("--compose-format") != nil, let textView = editor.textView {
                let bold = NSFontManager.shared.convert(RichEditorController.baseFont, toHaveTrait: .boldFontMask)
                let text = NSMutableAttributedString(string: "Hi team,\n\nThe review moves to ",
                                                     attributes: [.font: RichEditorController.baseFont])
                text.append(NSAttributedString(string: "Thursday 10:00", attributes: [.font: bold]))
                text.append(NSAttributedString(string: ". Agenda:\n\u{2022} Search results\n\u{2022} Drafts\n\nNotes are ",
                                               attributes: [.font: RichEditorController.baseFont]))
                text.append(NSAttributedString(string: "on the wiki", attributes: [.font: RichEditorController.baseFont,
                                                                                   .link: URL(string: "https://example.com/wiki")!]))
                text.append(NSAttributedString(string: ".\n\nممنون", attributes: [.font: RichEditorController.baseFont]))
                textView.textStorage?.setAttributedString(text)
                textView.didChangeText()
            }
            if value("--compose-mention") != nil, let textView = editor.textView {
                textView.string = "Thanks for the notes. @sa"
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                editor.refreshState()
            }
            if value("--compose-templates-ask") != nil { store.compose.asksToCreateTemplates = true }
            if value("--compose-saved") != nil { await store.saveDraftToServer() }
            if value("--undo-send-toast") != nil {
                try? await Task.sleep(for: .milliseconds(500))
                store.sendWithUndo()
            }
            if value("--show-drafts") != nil {
                await store.saveDraftToServer()
                store.discardDraft()
                store.mailFolder = .drafts
                await store.loadFolder(.drafts)
            }
        }
        #endif
    }
}
