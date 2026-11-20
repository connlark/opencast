import SwiftUI

/// Not `PlaylistTint`'s declaration order, which puts near hues side by side.
enum DownloadsStorageSegmentPalette {
    static let ordered: [PlaylistTint] = [.blue, .orange, .green, .purple, .teal, .red]

    static func fill(for segment: DownloadsStorageGraphSegment) -> Color {
        tint(for: segment)?.color ?? .gray
    }

    /// Black clears 4.5:1 on every fill in both appearances; white falls to about 3.2:1 on
    /// dark-mode blue, too low for caption digits.
    static let digitColor = Color.black

    private static func tint(for segment: DownloadsStorageGraphSegment) -> PlaylistTint? {
        segment.paletteIndex.map { ordered[$0 % ordered.count] }
    }
}
