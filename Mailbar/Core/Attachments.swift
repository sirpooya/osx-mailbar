import AppKit
import UniformTypeIdentifiers

/// Opening and saving attachments (M9).
///
/// **The one place mail reaches the disk, and only when the user asks.** Another app can only
/// open a file, so Open writes the attachment to a private folder in this app's temporary
/// directory (owner-only permissions) and hands that to the default app. The folder is emptied
/// when Mailbar quits and again at launch, in case it did not quit cleanly. Save writes wherever
/// the user chooses in the save panel, which is theirs to manage. Nothing is written before
/// either button is pressed, and the bytes are fetched only then.
@MainActor
enum Attachments {

    /// `<tmp>/Mailbar Attachments/<uuid>/<name>`: one folder per opened file, so two attachments
    /// with the same name never overwrite each other.
    static var openedCopiesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Mailbar Attachments", isDirectory: true)
    }

    static func open(_ data: Data, named name: String) throws {
        let folder = openedCopiesFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(safeName(name))
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
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
