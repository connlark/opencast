import SwiftUI

/// The segmented storage bar. It reads only completed downloads, never
/// in-flight progress, so it redraws when the set of files changes rather
/// than at download progress rate.
struct DownloadsStorageBarView: View {
    private static let segmentSpacing = 2.0
    private static let minimumSegmentWidth = 4.0
    /// The narrowest segment that still fits its number.
    private static let minimumNumberedSegmentWidth = 24.0

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barHeight = 16
    /// Numbers leave the bar at accessibility sizes, so it stops growing
    /// once it is tall enough to read as a bar.
    private static let maximumBarHeight = 28.0

    let model: DownloadsStorageGraphModel

    var body: some View {
        GeometryReader { proxy in
            let widths = DownloadsStorageGraphModel.segmentWidths(
                fractions: model.segments.map(\.fraction),
                totalWidth: proxy.size.width,
                spacing: Self.segmentSpacing,
                minimumWidth: Self.minimumSegmentWidth
            )
            HStack(spacing: Self.segmentSpacing) {
                ForEach(model.segments) { segment in
                    let width = widths[segment.number - 1]
                    Rectangle()
                        .fill(DownloadsStorageSegmentPalette.fill(for: segment))
                        .frame(width: width)
                        .overlay {
                            if showsNumber(inSegmentOfWidth: width) {
                                Text(segment.number, format: .number)
                                    .font(.caption.bold())
                                    .foregroundStyle(DownloadsStorageSegmentPalette.digitColor)
                            }
                        }
                }
            }
        }
        .frame(height: min(barHeight, Self.maximumBarHeight))
        .clipShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage by show")
        .accessibilityValue(model.accessibilitySummary)
        .accessibilityIdentifier("downloads-storage-graph")
        .animation(reduceMotion ? nil : .snappy, value: model.animationKey)
    }

    /// Numbers appear only with Differentiate Without Color, where color
    /// can't pair a segment with its legend row. Accessibility sizes outgrow
    /// the bar, so the legend alone carries the numbers there.
    private func showsNumber(inSegmentOfWidth width: Double) -> Bool {
        differentiateWithoutColor
            && !dynamicTypeSize.isAccessibilitySize
            && width >= Self.minimumNumberedSegmentWidth
    }
}
