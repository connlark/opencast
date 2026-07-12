import SwiftData
import SwiftUI

struct LibrarySubscriptionTileView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var tileWidth = 160.0
    @State private var isConfirmingRemoval = false

    let subscription: SubscriptionRecord

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

    private var artworkSize: CGFloat {
        CGFloat(tileWidth)
    }

    var body: some View {
        NavigationLink(value: AppRoute.podcastDetail(feedURL: subscription.feedURL)) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    ArtworkPlaceholder(
                        title: subscription.title,
                        imageURL: podcastCache?.artworkURL ?? subscription.artworkURL,
                        size: artworkSize,
                        preview: podcastCache?.artworkPreview,
                        onPreviewResolved: updateArtworkPreview
                    )

                    refreshStatusOverlay
                }

                Text(subscription.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            .onGeometryChange(for: Double.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                let clampedWidth = min(max(newWidth, 160), 240)
                guard abs(tileWidth - clampedWidth) >= 0.5 else {
                    return
                }

                tileWidth = clampedWidth
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(LibrarySubscriptionRowView.accessibilityIdentifier(for: subscription.feedURL))
        .modifier(
            SubscriptionRemovalModifier(
                isConfirmingRemoval: $isConfirmingRemoval,
                subscription: subscription,
                supportsSwipeAction: false,
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
                .accessibilityLabel("Refreshing")
        } else if refreshErrorMessage != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(6)
                .glassEffect(.regular, in: .circle)
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
