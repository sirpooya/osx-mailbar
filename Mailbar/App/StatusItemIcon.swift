import AppKit

/// The menu bar glyph: the supplied `MenuBarIcon.png`, the user's artboard, drawn whole.
///
/// **The artboard is the design, padding included.** The file is bundled exactly as supplied and
/// drawn edge to edge into the standard 18pt square slot. Nothing is cropped, resized, recoloured or
/// re-weighted. (An earlier version cropped to the ink and later lifted the alpha; the user
/// rejected both on 2026-09-24. Do not "improve" the artwork in code.)
///
/// It is a template image: the artwork is black with its shading in alpha, which is exactly what a
/// template keeps, so AppKit tints it to match the menu bar, light or dark, on every display.
enum StatusItemIcon {

    /// Menu bar icons are 18pt inside a 22pt bar. The artboard is square, so the slot is too.
    private static let side: CGFloat = 18

    /// - Parameter dimmed: drawn at reduced opacity when no account could be read, so a stale
    ///   or failing state is visible at a glance without inventing a second icon.
    static func image(dimmed: Bool) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            if let artboard {
                artboard.draw(in: rect, from: .zero, operation: .sourceOver,
                              fraction: dimmed ? 0.45 : 1)
            } else {
                // Fallback only: a menu bar with no icon at all is the one outcome worth extra
                // code to avoid.
                NSColor.black.withAlphaComponent(dimmed ? 0.45 : 1).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 4), xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mailbar"
        return image
    }

    /// Loaded by URL rather than `NSImage(named:)` so a rename fails here, where the fallback can
    /// see it, instead of resolving to nil somewhere further along.
    private static let artboard: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
