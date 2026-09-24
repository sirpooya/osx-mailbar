import AppKit

/// The menu bar glyph: the supplied `MenuBarIcon.png`, cropped to its ink.
///
/// Built the way osx-jirabar builds its icon. The artwork is black and carries all of its shading
/// (the flap, the seal) in alpha, which is exactly what a template image keeps: AppKit throws the
/// colour away and tints the alpha to match the menu bar, light or dark, on every display. So one
/// file serves both appearances and there is no hardcoded colour anywhere to go wrong on a dark
/// bar (see the `menubar-icon-theming` skill).
enum StatusItemIcon {

    // Menu bar icons are 18pt tall inside a 22pt bar. The envelope is wider than tall.
    private static let height: CGFloat = 18
    private static let glyphHeight: CGFloat = 12

    /// - Parameter dimmed: drawn at reduced opacity when no account could be read, so a stale
    ///   or failing state is visible at a glance without inventing a second icon.
    static func image(dimmed: Bool) -> NSImage {
        let glyph = glyphSize
        let size = NSSize(width: ceil(glyph.width), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphRect = NSRect(x: 0,
                                   y: ((rect.height - glyph.height) / 2).rounded(),
                                   width: glyph.width,
                                   height: glyph.height)
            if let markImage {
                markImage.draw(in: glyphRect, from: .zero, operation: .sourceOver,
                               fraction: dimmed ? 0.45 : 1)
            } else {
                // Fallback only: a menu bar with no icon at all is the one outcome worth extra
                // code to avoid. A rounded rectangle reads as an envelope at this size.
                NSColor.black.withAlphaComponent(dimmed ? 0.45 : 1).setFill()
                NSBezierPath(roundedRect: glyphRect, xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mailbar"
        return image
    }

    /// Aspect preserved from the artwork's own ink, at a fixed height.
    private static var glyphSize: NSSize {
        guard let markImage, markImage.size.height > 0 else {
            return NSSize(width: 17, height: glyphHeight)
        }
        let ratio = markImage.size.width / markImage.size.height
        return NSSize(width: (glyphHeight * ratio).rounded(), height: glyphHeight)
    }

    /// Loaded by URL rather than `NSImage(named:)` so a rename fails here, where the fallback can
    /// see it, instead of resolving to nil somewhere further along.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let source = NSBitmapImageRep(data: data) else { return nil }
        return cropToInk(source)
    }()

    /// Trims fully transparent rows and columns off the edges. The supplied artwork sits in a
    /// square canvas with wide empty margins above and below, so drawn as-is it would be tiny.
    private static func cropToInk(_ source: NSBitmapImageRep) -> NSImage? {
        var minX = source.pixelsWide, maxX = -1
        var minY = source.pixelsHigh, maxY = -1
        for y in 0..<source.pixelsHigh {
            for x in 0..<source.pixelsWide {
                guard let alpha = source.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.03 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let ink = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let image = NSImage(size: ink.size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // colorAt() counts rows from the top; drawing is bottom-up, so flip the origin.
        let fromTop = CGFloat(source.pixelsHigh) - ink.maxY
        source.draw(in: NSRect(origin: .zero, size: ink.size),
                    from: NSRect(x: ink.minX, y: fromTop, width: ink.width, height: ink.height),
                    operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        image.unlockFocus()
        return image
    }
}
