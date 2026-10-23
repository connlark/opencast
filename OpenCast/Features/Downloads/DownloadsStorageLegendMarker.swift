import SwiftUI

/// A legend entry's swatch, a dot in its segment's color. With
/// Differentiate Without Color on, it grows to carry the segment's number,
/// as the bar does, and a ring outlines it so pale fills stand apart from
/// the row.
struct DownloadsStorageLegendMarker: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @ScaledMetric(relativeTo: .body) private var dotDiameter = 12
    @ScaledMetric(relativeTo: .caption) private var numberedDiameter = 20

    let segment: DownloadsStorageGraphSegment

    var body: some View {
        let diameter = differentiateWithoutColor ? numberedDiameter : dotDiameter
        Circle()
            .fill(DownloadsStorageSegmentPalette.fill(for: segment))
            .frame(width: diameter, height: diameter)
            .overlay {
                if differentiateWithoutColor {
                    Text(segment.number, format: .number)
                        .font(.caption.bold())
                        .foregroundStyle(DownloadsStorageSegmentPalette.digitColor)
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }
}
