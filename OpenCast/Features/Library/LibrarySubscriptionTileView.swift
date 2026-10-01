import SwiftData
import SwiftUI

struct LibrarySubscriptionTileView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isConfirmingRemoval = false

    let subscription: SubscriptionRecord
    let metrics: LibraryGridMetrics
    let badge: LibrarySubscriptionBadge
    /// Opens the show under these Inbox settings instead of its stored filter.
    var episodeListOverride: PodcastEpisodeListOverride? = nil

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: subscription.feedURL)
    }

    private var latestRefreshLog: RefreshLogSnapshot? {
        appModel.library.latestRefreshLogByFeedURL[subscription.feedURL]
    }

    private var isRefreshing: Bool {
        appModel.library.isRefreshing(feedURL: subscription.feedURL)
    }

    private var refreshErrorMessage: String? {
        guard let errorMessage = latestRefreshLog?.errorMessage,
              !errorMessage.isEmpty
        else {
            return nil
        }

        return errorMessage
    }

    private var badgeCount: Int {
        switch badge {
        case .hidden:
            0
        case .newEpisodes:
            appModel.library.newEpisodeCount(for: subscription)
        case .episodeCount(let count):
            count
        }
    }

    var body: some View {
        let badgeCount = badgeCount

        NavigationLink(value: AppRoute.podcastDetail(feedURL: subscription.feedURL, episodeListOverride: episodeListOverride)) {
            VStack(alignment: .leading, spacing: metrics.isCompact ? 6 : 10) {
                ArtworkPlaceholder(
                    title: subscription.title,
                    imageURL: podcastCache?.artworkURL ?? subscription.artworkURL,
                    size: metrics.tileWidth,
                    preview: podcastCache.flatMap { appModel.library.artworkPreview(for: $0) },
                    onPreviewResolved: updateArtworkPreview
                )
                .overlay(alignment: .topLeading) {
                    refreshStatusOverlay
                }
                .overlay(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        LibraryNewEpisodeBadge(count: badgeCount)
                            .padding(4)
                    }
                }

                Text(subscription.title)
                    .font(metrics.isCompact ? .subheadline : .headline)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(badge.accessibilityValue(count: badgeCount))
        .accessibilityIdentifier(LibrarySubscriptionRowView.accessibilityIdentifier(for: subscription.feedURL))
        .modifier(
            SubscriptionRemovalModifier(
                isConfirmingRemoval: $isConfirmingRemoval,
                subscription: subscription,
                // Compact tiles are too narrow for a trailing swipe action.
                supportsSwipeAction: !metrics.isCompact,
                supportsContextMenu: true
            )
        )
    }

    @ViewBuilder
    private var refreshStatusOverlay: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .padding(6)
                .glassEffect(.regular, in: .circle)
                .padding(6)
                .accessibilityLabel("Refreshing")
        } else if refreshErrorMessage != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(6)
                .glassEffect(.regular, in: .circle)
                .padding(6)
                .accessibilityLabel("Last refresh failed")
        }
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        guard let podcastCache else {
            return
        }

        appModel.library.updateArtworkPreview(preview, for: podcastCache)
    }
}
