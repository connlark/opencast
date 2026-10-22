import SwiftUI

/// A Group by Show section header: the show, its download count and size,
/// its Keep Downloaded chip (a link to the show's download settings while
/// it is in the library) and the collapse control.
struct DownloadsShowSectionHeader: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.editMode) private var editMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let group: DownloadsShowGroup
    let isExpanded: Bool
    let onToggleExpansion: () -> Void

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: group.podcastID)
    }

    /// Accessibility sizes stack the header, as `DownloadsStorageLegendRow`
    /// does, with the chip and collapse control on their own line.
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            ArtworkPlaceholder(
                title: group.title,
                imageURL: podcastCache?.artworkURL ?? group.artworkURL,
                size: 32,
                preview: podcastCache.flatMap { appModel.library.artworkPreview(for: $0) }
            )

            // Headers draw secondary; the concrete primary restores the
            // title's weight and the detail's usual secondary.
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(DownloadsStorageText.showDetail(episodeCount: group.episodeCount, byteCount: group.byteCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                limitChip
                    .foregroundStyle(Color.primary)
                    .accessibilityIdentifier("download-show-limit-\(group.podcastID)")

                Button(
                    isExpanded ? "Collapse \(group.title)" : "Expand \(group.title)",
                    systemImage: "chevron.down",
                    action: onToggleExpansion
                )
                .labelStyle(.iconOnly)
                .font(.subheadline.bold())
                .rotationEffect(isExpanded ? .zero : .degrees(-90))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
                .accessibilityIdentifier("download-show-toggle-\(group.podcastID)")
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download-show-section-\(group.podcastID)")
    }

    @ViewBuilder
    private var limitChip: some View {
        let chip = DownloadKeepLimitChip(
            keepLimit: appModel.downloadSettings.resolvedKeepLimit(forPodcastID: group.podcastID)
        )
        if group.isOrphaned {
            chip
        } else {
            NavigationLink(value: AppRoute.podcastDownloadSettings(feedURL: group.podcastID)) {
                chip
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .disabled(editMode?.wrappedValue.isEditing == true)
        }
    }
}
