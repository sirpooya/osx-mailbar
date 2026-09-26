import AppKit
import Quartz
import UniformTypeIdentifiers

/// Previewing and saving attachments (M9).
///
/// **The one place mail reaches the disk, and only when the user asks.** Quick Look can only
/// show a file, so Preview writes the attachment to a private folder in this app's temporary
/// directory (owner-only permissions) and shows it in the Quick Look panel; the copy is deleted
/// the moment the panel closes. The folder is also emptied at quit and at launch, in case the app
/// did not quit cleanly. Save writes wherever the user chooses in the save panel, which is theirs
/// to manage. Nothing is written before either is pressed, and the bytes are fetched only then.
@MainActor
enum Attachments {

    /// `<tmp>/Mailbar Attachments/<uuid>/<name>`: one folder per opened file, so two attachments
    /// with the same name never overwrite each other.
    static var openedCopiesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Mailbar Attachments", isDirectory: true)
    }

    static func preview(_ data: Data, named name: String) throws {
        let folder = openedCopiesFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(safeName(name))
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        AttachmentPreview.shared.show(file, folder: folder)
    }

    /// Asks where, then writes there. Returns false when the user cancels.
    static func save(_ data: Data, named name: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeName(name)
        panel.canCreateDirectories = true
        WindowActivation.claim()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try data.write(to: url, options: [.atomic])
        return true
    }

    static func clearOpenedCopies() {
        try? FileManager.default.removeItem(at: openedCopiesFolder)
    }

    /// A name that stays inside its folder: no path separators, no leading dot, never empty.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.drop(while: { $0 == "." })
        return trimmed.isEmpty ? "Attachment" : String(trimmed)
    }

    /// The icon Finder would show for a file of this name.
    static func icon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// The Quick Look panel for one attachment copy at a time. When the panel goes away, or shows the
/// next attachment instead, the previous copy's folder is deleted at once.
///
/// The panel is driven by setting its data source directly: an accessory app's popover is not a
/// reliable responder chain to hand it to. Its close is not always a `windowWillClose` (Escape and
/// Space order it out), so a light timer watches for it leaving the screen.
@MainActor
final class AttachmentPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = AttachmentPreview()

    private var file: URL?
    private var folder: URL?
    private var watcher: Timer?

    func show(_ file: URL, folder: URL) {
        discard()
        self.file = file
        self.folder = folder
        guard let panel = QLPreviewPanel.shared() else { discard(); return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        WindowActivation.claim()
        panel.makeKeyAndOrderFront(nil)
        watcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = QLPreviewPanel.shared(), !panel.isVisible else { return }
                self.discard()
            }
        }
    }

    /// Stops watching and deletes the current copy.
    private func discard() {
        watcher?.invalidate()
        watcher = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        file = nil
        folder = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { file == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { file as NSURL? }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { discard() }
    }
}
