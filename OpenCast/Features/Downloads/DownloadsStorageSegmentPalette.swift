import SwiftUI

/// The storage bar's colors, in bar order. The order differs from
/// `PlaylistTint`'s declaration order, which puts near hues side by side;
/// here neighbors always contrast. Six entries cover a bar of six shows;
/// Other is gray.
enum DownloadsStorageSegmentPalette {
    static let ordered: [PlaylistTint] = [.blue, .orange, .green, .purple, .teal, .red]

    static func fill(for segment: DownloadsStorageGraphSegment) -> Color {
        tint(for: segment)?.color ?? .gray
    }

    /// The digit color on every fill, including Other's gray. Black clears
    /// 4.5:1 on all six system colors in light and dark appearance; the
    /// playlist palette's white labels measure about 3.2:1 on dark-mode blue
    /// and 3.6:1 on purple, too low for caption digits.
    static let digitColor = Color.black

    private static func tint(for segment: DownloadsStorageGraphSegment) -> PlaylistTint? {
        segment.paletteIndex.map { ordered[$0 % ordered.count] }
    }
}
