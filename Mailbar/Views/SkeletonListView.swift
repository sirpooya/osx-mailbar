import SwiftUI

/// The shape of the inbox, drawn before the inbox exists. Same three lines at the same paddings
/// as `MessageRowView`, so the rows that replace it land without the list changing height.
/// From osx-jirabar's skeleton.
struct SkeletonListView: View {
    var rowCount = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { index in
                SkeletonRow(fractions: Self.fractions[index % Self.fractions.count])
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .top)
        // A slow breath, not a sweep.
        .opacity(dimmed ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                   value: dimmed)
        .onAppear { if !reduceMotion { dimmed = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the inbox")
    }

    /// Sender, subject and preview widths per row, varied so it reads as mail, not a barcode.
    private static let fractions: [(CGFloat, CGFloat, CGFloat)] = [
        (0.35, 0.70, 0.90), (0.25, 0.55, 0.80), (0.42, 0.78, 0.86),
        (0.30, 0.48, 0.74), (0.38, 0.66, 0.92), (0.28, 0.60, 0.70),
    ]
}

private struct SkeletonRow: View {
    let fractions: (CGFloat, CGFloat, CGFloat)

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: MessageRowView.Metrics.dotColumn, height: 1)
            VStack(alignment: .leading, spacing: MessageRowView.Metrics.lineSpacing + 3) {
                line(fractions.0, height: 12)
                HStack(spacing: 8) {
                    line(fractions.1, height: 11)
                    bar(width: 44, height: 10)
                }
                line(fractions.2, height: 11)
            }
        }
        .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
        .padding(.vertical, MessageRowView.Metrics.verticalPadding + 1)
    }

    private func line(_ fraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            bar(width: proxy.size.width * fraction, height: height)
        }
        .frame(height: height)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(0.09))
            .frame(width: width, height: height)
    }
}
