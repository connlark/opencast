import SwiftUI

/// A show in the storage legend: its swatch, size, episode count and Keep
/// Downloaded limit. A subscribed show opens its download settings; one
/// that left the library stays a plain row, still deletable by swipe.
struct DownloadsStorageLegendRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let breakdown: DownloadsPodcastBreakdown
    /// Nil inside Other, whose shows share Other's swatch.
    let segment: DownloadsStorageGraphSegment?
    let onDelete: () -> Void

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: breakdown.podcastID)
    }

    var body: some View {
        Group {
            if breakdown.isOrphaned {
                content
            } else {
                NavigationLink(value: AppRoute.podcastDownloadSettings(feedURL: breakdown.podcastID)) {
                    content
                }
            }
        }
        .accessibilityIdentifier("download-podcast-\(breakdown.podcastID)")
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    /// Accessibility sizes stack the row, so the title keeps the full width
    /// instead of breaking a letter at a time beside the swatch and chip.
    private var content: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                if let segment {
                    DownloadsStorageLegendMarker(segment: segment)
                }

                ArtworkPlaceholder(
                    title: breakdown.title,
                    imageURL: podcastCache?.artworkURL ?? breakdown.artworkURL,
                    size: 40,
                    preview: podcastCache.flatMap { appModel.library.artworkPreview(for: $0) }
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(breakdown.title)
                    .lineLimit(2)
                Text(
                    DownloadsStorageText.showDetail(
                        episodeCount: breakdown.episodeCount,
                        byteCount: breakdown.byteCount
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if breakdown.isOrphaned {
                    Label("No longer in library", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DownloadKeepLimitChip(
                keepLimit: appModel.downloadSettings.resolvedKeepLimit(forPodcastID: breakdown.podcastID)
            )
        }
        .accessibilityElement(children: .combine)
    }
}
