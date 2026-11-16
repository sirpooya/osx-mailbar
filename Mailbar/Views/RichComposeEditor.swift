import AppKit
import Observation
import SwiftUI

/// The mail body editor since M25: an `NSTextView` that takes bold, italic, underline, lists and
/// links from the formatting bar, checks spelling as you type (macOS's own), turns each paragraph
/// right to left on its own when it starts in Persian, offers people for an @mention, takes files
/// dropped on it as attachments, and sends on Cmd+Return.
@MainActor
@Observable
final class RichEditorController {
    @ObservationIgnored weak var textView: RichTextView?
    /// What follows an "@" being typed, or nil.
    var mentionQuery: String?
    @ObservationIgnored var mentionRange: NSRange?
    /// Which formatting the caret or selection has, for the bar's on and off states.
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    @ObservationIgnored var onChange: ((NSAttributedString) -> Void)?

    static let baseFont = NSFont.systemFont(ofSize: 13)

    // MARK: Formatting

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        let current = (range.length > 0 ? storage.attribute(.font, at: range.location, effectiveRange: nil)
                       : textView.typingAttributes[.font]) as? NSFont ?? Self.baseFont
        let on = manager.traits(of: current).contains(trait)
        func convert(_ font: NSFont) -> NSFont {
            on ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
        if range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                storage.addAttribute(.font, value: convert(value as? NSFont ?? Self.baseFont), range: sub)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        textView.typingAttributes[.font] = convert(current)
        refreshState()
    }

    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let current = (range.length > 0 ? storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil)
                       : textView.typingAttributes[.underlineStyle]) as? Int ?? 0
        let value = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        if range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) {
            storage.addAttribute(.underlineStyle, value: value, range: range)
            textView.didChangeText()
        }
        textView.typingAttributes[.underlineStyle] = value
        refreshState()
    }

    /// Adds or removes the marker on every paragraph the selection touches. A numbered list
    /// counts from one.
    func toggleList(_ kind: RichHTML.ListKind) {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let paragraphs = string.paragraphRange(for: textView.selectedRange())
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        if lines.isEmpty { lines = [NSRange(location: paragraphs.location, length: 0)] }
        let allOn = lines.allSatisfy { RichHTML.listItem(string.substring(with: $0))?.0 == kind }
        guard textView.shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        storage.beginEditing()
        for (index, line) in lines.enumerated().reversed() {
            let text = (storage.string as NSString).substring(with: line)
            if let (_, length) = RichHTML.listItem(text) {
                storage.deleteCharacters(in: NSRange(location: line.location, length: length))
            }
            if !allOn {
                let marker = kind == .bulleted ? RichHTML.bullet : "\(index + 1). "
                storage.insert(NSAttributedString(string: marker, attributes: textView.typingAttributes), at: line.location)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    /// Makes the selection a link, or inserts the address as one where the caret is.
    func setLink(_ address: String) {
        guard let textView, let storage = textView.textStorage else { return }
        var target = address.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        if !target.contains(":") { target = Recipients.isValid(target) ? "mailto:" + target : "https://" + target }
        guard let url = URL(string: target) else { return }
        var range = textView.selectedRange()
        if range.length == 0 {
            let shown = NSAttributedString(string: address, attributes: textView.typingAttributes)
            guard textView.shouldChangeText(in: range, replacementString: address) else { return }
            storage.insert(shown, at: range.location)
            range.length = shown.length
        } else if !textView.shouldChangeText(in: range, replacementString: nil) {
            return
        }
        storage.addAttribute(.link, value: url, range: range)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    /// Back to plain text: every format off, list markers kept as typed.
    func clearFormatting() {
        guard let textView, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: whole, replacementString: nil) else { return }
        storage.setAttributes([.font: Self.baseFont], range: whole)
        textView.typingAttributes = [.font: Self.baseFont]
        textView.didChangeText()
        ComposeEditor.applyDirection(textView)
    }

    /// The "@sa" being typed becomes "@Sara Rahimi", a mailto link, as Outlook writes a mention.
    func completeMention(_ person: PersonSuggestion) {
        guard let textView, let storage = textView.textStorage, let range = mentionRange,
              NSMaxRange(range) <= storage.length else { return }
        let shown = "@" + person.display
        guard textView.shouldChangeText(in: range, replacementString: shown + " ") else { return }
        var attributes = textView.typingAttributes
        attributes[.link] = URL(string: "mailto:" + person.address)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: shown, attributes: attributes))
        storage.insert(NSAttributedString(string: " ", attributes: [.font: Self.baseFont]), at: range.location + (shown as NSString).length)
        storage.endEditing()
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + (shown as NSString).length + 1, length: 0))
        textView.typingAttributes.removeValue(forKey: .link)
        mentionQuery = nil
        mentionRange = nil
    }

    // MARK: State

    func refreshState() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, let storage = textView.textStorage, range.location < storage.length {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }
        let traits = RichHTML.traits(attributes[.font] as? NSFont)
        isBold = traits.bold
        isItalic = traits.italic
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        updateMention()
    }

    /// The word before the caret, when it starts with "@" and has two letters after it.
    private func updateMention() {
        guard let textView else { return }
        let caret = textView.selectedRange()
        guard caret.length == 0 else { mentionQuery = nil; return }
        let string = textView.string as NSString
        var start = caret.location
        while start > 0 {
            let character = string.character(at: start - 1)
            if let scalar = Unicode.Scalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        let word = string.substring(with: NSRange(location: start, length: caret.location - start))
        if word.hasPrefix("@"), word.count >= 3, !word.dropFirst().contains("@") {
            mentionQuery = String(word.dropFirst())
            mentionRange = NSRange(location: start, length: caret.location - start)
        } else {
            mentionQuery = nil
            mentionRange = nil
        }
    }
}

struct RichComposeEditor: NSViewRepresentable {
    let controller: RichEditorController
    /// The text to start from: the stored rich text when the composer comes back to a draft.
    let initial: NSAttributedString
    /// Plain text set from outside (a signature, a template, a QC flag) replaces what is shown.
    let plain: String
    var onSend: () -> Void
    var onDropFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = RichTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.onDropFiles = onDropFiles
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.typingAttributes = [.font: RichEditorController.baseFont]
        textView.textStorage?.setAttributedString(initial)
        controller.textView = textView
        ComposeEditor.applyDirection(textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? RichTextView else { return }
        textView.onSend = onSend
        textView.onDropFiles = onDropFiles
        controller.textView = textView
        if textView.string != plain {
            let replacement = initial.string == plain ? initial
                : NSAttributedString(string: plain, attributes: [.font: RichEditorController.baseFont])
            textView.textStorage?.setAttributedString(replacement)
            ComposeEditor.applyDirection(textView)
            controller.onChange?(textView.attributedString())
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: RichEditorController

        init(controller: RichEditorController) { self.controller = controller }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            ComposeEditor.applyDirection(textView)
            controller.onChange?(textView.attributedString())
            controller.refreshState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.refreshState()
        }

        /// Return in a list item starts the next one; Return on an empty item ends the list.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let storage = textView.textStorage else { return false }
            let string = storage.string as NSString
            let caret = textView.selectedRange()
            let paragraph = string.paragraphRange(for: NSRange(location: caret.location, length: 0))
            var line = string.substring(with: paragraph)
            if line.hasSuffix("\n") { line.removeLast() }
            guard let (kind, length) = RichHTML.listItem(line) else { return false }
            if (line as NSString).length == length {
                textView.insertText("", replacementRange: NSRange(location: paragraph.location, length: length))
                return true
            }
            var next = RichHTML.bullet
            if kind == .numbered, let number = Int(line.prefix(while: \.isNumber)) { next = "\(number + 1). " }
            textView.insertText("\n" + next, replacementRange: caret)
            return true
        }
    }
}

/// Cmd+Return sends (by key code, as `SendingTextView`); files dropped become attachments
/// instead of text.
final class RichTextView: NSTextView {
    var onSend: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command,
           ComposerShortcut.isSend(keyCode: event.keyCode, command: true), let onSend {
            onSend()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }
}
