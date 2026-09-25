import SwiftUI

/// Text whose glyphs are filled by a gradient travelling across them, the way Cursor's
/// "Generating" label reads. Ported from osx-autoconnect's `ShimmerText` (its status line), with
/// the tuned values it ships: a pass every 0.9 s, intensity 0.35, a highlight about one line long.
///
/// The gradient is the text colour, not a band drawn over grey text: an overlay haloes the line,
/// while a fill ramps dim to bright and back, so the peak reads as a highlight passing over words
/// that are grey again behind it. Driven by the clock (`TimelineView`), so an ancestor's
/// `.animation` cannot replace the loop with a single slide.
struct ShimmerText: View {
    let text: String
    var font: Font = .caption2
    /// Seconds for one pass of the highlight.
    var period: Double = 0.9
    /// How bright the peak gets, 0 to 1.
    var intensity: Double = 0.35
    /// The highlight's length as a multiple of the line's width.
    var length: Double = 1.05

    var body: some View {
        // Sized by the plain text, then painted by the gradient: the glyphs are the mask, so
        // layout cannot depend on the animation.
        Text(text).font(font).lineLimit(1).fixedSize()
            .hidden()
            .overlay { fill }
            .accessibilityLabel(text)
    }

    /// The same glyphs at full opacity, for masking; masking a dimmed copy would wash the peak out.
    private var glyphs: some View {
        Text(text).font(font).foregroundStyle(.black).lineLimit(1).fixedSize()
    }

    private var fill: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            // One glint every two and a half line-widths; tighter reads as stripes.
            let tile = width * 2.5
            let band = min(width * length, tile * 0.9)

            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let progress = elapsed.truncatingRemainder(dividingBy: period) / period
                // Leading-aligned by construction; two tiles so the wrap is invisible.
                HStack(spacing: 0) {
                    LinearGradient(stops: stops(half: (band / 2) / (tile * 2)),
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: tile * 2)
                    Spacer(minLength: 0)
                }
                .offset(x: -tile * (1 - progress))
            }
        }
        .mask(glyphs)
        .allowsHitTesting(false)
    }

    /// Two identical dim, bright, dim ramps, so the pattern repeats every tile.
    private func stops(half: Double) -> [Gradient.Stop] {
        let dim = Color.primary.opacity(0.3)
        let peak = Color.primary.opacity(min(1, 0.45 + 0.55 * intensity))
        return [
            .init(color: dim, location: 0),
            .init(color: peak, location: half),
            .init(color: dim, location: 2 * half),
            .init(color: dim, location: 0.5),
            .init(color: peak, location: 0.5 + half),
            .init(color: dim, location: 0.5 + 2 * half),
            .init(color: dim, location: 1),
        ]
    }
}
