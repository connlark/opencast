import SwiftUI

struct PodcastHeroHeaderView: View {
    let subscription: SubscriptionRecord
    let podcast: PodcastCacheSnapshot?
    let artworkPreview: ArtworkPreview?
    let episodeCount: Int
    let unplayedCount: Int
    let lastRefreshedAt: Date?
    let isRefreshing: Bool
    let refreshErrorMessage: String?
    let health: FeedHealthStatus?
    let notificationHealth: NotificationFeedHealth?
    let primaryAction: PodcastPrimaryAction?
    let onPlay: (EpisodeListItemSnapshot) -> Void
    let onPreviewResolved: (ArtworkPreview) -> Void

    @State private var artworkLength: CGFloat = 220

    var body: some View {
        VStack(spacing: 16) {
            ArtworkPlaceholder(
                title: subscription.title,
                imageURL: podcast?.artworkURL ?? subscription.artworkURL,
                size: artworkLength,
                preview: artworkPreview,
                onPreviewResolved: onPreviewResolved
            )
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)

            VStack(spacing: 5) {
                Text(subscription.title)
                    .font(.title2)
                    .bold()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let author = subscription.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityElement(children: .combine)

            PodcastHeaderMetadataView(
                subscription: subscription,
                episodeCount: episodeCount,
                unplayedCount: unplayedCount,
                lastRefreshedAt: lastRefreshedAt,
                isRefreshing: isRefreshing,
                refreshErrorMessage: refreshErrorMessage,
                health: health,
                notificationHealth: notificationHealth
            )

            PodcastDescriptionView(summaryHTML: podcast?.summary)

            if let primaryAction {
                PodcastPrimaryActionButton(action: primaryAction, onPlay: onPlay)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            artworkLength = min(max(width * 0.55, 120), 300)
        }
    }
}
