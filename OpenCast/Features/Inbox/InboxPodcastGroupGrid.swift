import SwiftData
import SwiftUI

/// The Group by Podcast Inbox as a grid, on the Library grid's metrics.
struct InboxPodcastGroupGrid<Header: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let groups: [InboxPodcastGroup]
    let episodeListOverride: PodcastEpisodeListOverride
    private let header: Header

    init(
        groups: [InboxPodcastGroup],
        episodeListOverride: PodcastEpisodeListOverride,
        @ViewBuilder header: () -> Header
    ) {
        self.groups = groups
        self.episodeListOverride = episodeListOverride
        self.header = header()
    }

    var body: some View {
        // Reads the width in the same layout pass, so the first frame
        // already has its final column count.
        GeometryReader { proxy in
            let metrics = LibraryGridMetrics.resolve(
                containerWidth: proxy.size.width,
                isCompact: horizontalSizeClass == .compact || verticalSizeClass == .compact,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    LazyVGrid(columns: metrics.columns, spacing: metrics.rowSpacing) {
                        ForEach(groups) { group in
                            InboxPodcastGroupLink(group: group, episodeListOverride: episodeListOverride) {
                                SubscriptionTileView(
                                    subscription: group.subscription,
                                    metrics: metrics,
                                    badgeCount: group.episodeCount
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .accessibilityIdentifier("Inbox Podcast Grid")
            .contentMargins(.horizontal, metrics.horizontalMargin, for: .scrollContent)
            .contentMargins(.bottom, 72, for: .scrollContent)
        }
    }
}
