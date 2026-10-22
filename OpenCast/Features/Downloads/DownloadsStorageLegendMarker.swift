import SwiftUI

/// A legend entry's numbered swatch, matching its segment in the bar. With
/// Differentiate Without Color on, a ring outlines the swatch so pale fills
/// stand apart from the row.
struct DownloadsStorageLegendMarker: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @ScaledMetric(relativeTo: .caption) private var diameter = 20

    let segment: DownloadsStorageGraphSegment

    var body: some View {
        Text(segment.number, format: .number)
            .font(.caption.bold())
            .foregroundStyle(DownloadsStorageSegmentPalette.digitColor)
            .frame(width: diameter, height: diameter)
            .background(DownloadsStorageSegmentPalette.fill(for: segment), in: .circle)
            .overlay {
                Circle()
                    .strokeBorder(Color.primary, lineWidth: differentiateWithoutColor ? 1.5 : 0)
            }
            .accessibilityHidden(true)
    }
}
