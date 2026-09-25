import AppKit
import SwiftUI

/// Writing a reply, reply all, forward or new message (M12 to M14). Plain text on purpose: the
/// user asked for simple, so there is no formatting bar, no attachments, no signature editor.
struct ComposeView: View {
    @Bindable var store: MailStore
    let onClose: () -> Void

    @State private var confirmingDiscard = false
    @FocusState private var focus: Field?

    private enum Field { case to, cc, subject }

    static let editorHeight: CGFloat = 260

    var body: some View {
        if let draft = store.draft {
            VStack(spacing: 0) {
                toolbar(draft)
                Divider().opacity(0.5)
                if confirmingDiscard { discardBanner }
                fields(draft)
                Divider().opacity(0.5)
                ComposeEditor(text: Binding(get: { store.draft?.body ?? "" },
                                            set: { store.draft?.body = $0 }),
                              onSend: { Task { await store.sendDraft() } })
                    .frame(height: Self.editorHeight)
                footer(draft)
            }
            .onAppear {
                if draft.kind == .forward || draft.kind == .new, draft.to.isEmpty { focus = .to }
            }
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ draft: Draft) -> some View {
        HStack(spacing: 10) {
            Button {
                if draft.hasContent { confirmingDiscard = true } else { store.discardDraft(); onClose() }
            } label: {
                Text("Cancel").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Discard this message")

            Spacer(minLength: 0)
            Text(draft.title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)

            if draft.isSending {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 40)
            } else {
                Button("Send") { Task { await store.sendDraft() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draft.sendProblem != nil)
                    .help(draft.sendProblem ?? "Send (Command Return)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var discardBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash").foregroundStyle(.orange)
            Text("Discard this message? The text will be lost.")
            Spacer(minLength: 4)
            Button("Keep Writing") { confirmingDiscard = false }
            Button("Discard") {
                confirmingDiscard = false
                store.discardDraft()
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Fields

    private func fields(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            recipientField("To", text: Binding(get: { store.draft?.to ?? "" }, set: { store.draft?.to = $0 }),
                           field: .to)
            thinDivider
            recipientField("Cc", text: Binding(get: { store.draft?.cc ?? "" }, set: { store.draft?.cc = $0 }),
                           field: .cc)
            thinDivider
            HStack(spacing: 6) {
                label("Subject")
                if draft.kind == .new {
                    TextField("", text: Binding(get: { store.draft?.subject ?? "" },
                                                set: { store.draft?.subject = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($focus, equals: .subject)
                } else {
                    DirectionalText(draft.subjectPreview, font: .system(size: 12))
                        .foregroundStyle(.secondary)
                        .help("Your server sets the subject, as Outlook does.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func recipientField(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                label(title)
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focus, equals: field)
            }
            // Suggestions for the address being typed, from senders already in the inbox.
            let suggestions = focus == field
                ? store.recipientSuggestions(for: Recipients.currentToken(in: text.wrappedValue),
                                             excluding: text.wrappedValue)
                : []
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(suggestions, id: \.address) { person in
                            Button {
                                text.wrappedValue = Recipients.completing(text.wrappedValue, with: person.address)
                            } label: {
                                Text(person.name.isEmpty ? person.address : "\(person.name)  \(person.address)")
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 56)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
    }

    private var thinDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.leading, 12)
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = draft.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.kind != .new {
                Text(draft.kind == .forward
                     ? "The original message and its attachments are added below by your server."
                     : "The original message is quoted below by your server.")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The text box: plain text, grows no taller than its frame and scrolls, turns right to left
/// when the text starts in Persian, and sends on Cmd+Return. The NSTextView pieces are from
/// osx-jirabar's comment composer.
struct ComposeEditor: NSViewRepresentable {
    @Binding var text: String
    var onSend: () -> Void
    /// The mail composer starts typing here; the event form starts at its title instead.
    var takesFocus = true

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SendingTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        if takesFocus { DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) } }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SendingTextView else { return }
        textView.onSend = onSend
        if textView.string != text { textView.string = text }
        Self.applyDirection(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            ComposeEditor.applyDirection(textView)
        }
    }

    /// Every paragraph takes its own direction from its own first strong character, the same
    /// rule `ComposeHTML` uses for what is sent: a Persian line runs right to left and sits on
    /// the right, and an English line after it runs left to right, "Thanks!" and not "!Thanks".
    /// (osx-jirabar's composer set one direction for the whole box, which is right for a comment
    /// but flipped every English line of a mixed email.)
    static func applyDirection(_ textView: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .natural
        style.alignment = .natural
        if textView.defaultParagraphStyle?.baseWritingDirection != .natural {
            textView.defaultParagraphStyle = style
            textView.typingAttributes[.paragraphStyle] = style
        }
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var needsFix = false
        storage.enumerateAttribute(.paragraphStyle, in: whole) { value, _, stop in
            let current = value as? NSParagraphStyle
            if current?.baseWritingDirection != .natural || current?.alignment != .natural {
                needsFix = true
                stop.pointee = true
            }
        }
        guard needsFix else { return }
        storage.addAttribute(.paragraphStyle, value: style, range: whole)
    }
}

/// Cmd+Return sends, matched by key code so it works on the Persian layout (`ComposerShortcut`).
final class SendingTextView: NSTextView {
    var onSend: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command,
           ComposerShortcut.isSend(keyCode: event.keyCode, command: true), let onSend {
            onSend()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
