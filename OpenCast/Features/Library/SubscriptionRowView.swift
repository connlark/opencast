import SwiftData
import SwiftUI

struct SubscriptionRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel

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

    var body: some View {
        HStack(spacing: 12) {
            ArtworkPlaceholder(
                title: subscription.title,
                imageURL: podcastCache?.artworkURL ?? subscription.artworkURL,
                size: 52,
                preview: podcastCache?.artworkPreview,
                onPreviewResolved: updateArtworkPreview
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(subscription.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = subscription.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let lastRefreshAt = subscription.lastRefreshAt {
                    Text("Refreshed \(lastRefreshAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if refreshErrorMessage != nil {
                    Label("Refresh failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            } else if refreshErrorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Last refresh failed")
            }
        }
        .padding(.vertical, 4)
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        guard let podcastCache = appModel.library.podcastCache(for: subscription.feedURL) else {
            return
        }

        appModel.library.updateArtworkPreview(preview, for: podcastCache)
    }
}
