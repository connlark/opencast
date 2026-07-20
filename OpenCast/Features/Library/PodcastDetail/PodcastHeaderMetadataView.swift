import SwiftUI

struct PodcastHeaderMetadataView: View {
    let subscription: SubscriptionRecord
    let episodeCount: Int
    let unplayedCount: Int
    let isRefreshing: Bool
    let refreshErrorMessage: String?

    var body: some View {
        VStack(spacing: 5) {
            Text("\(episodeCount) episodes · \(unplayedCount) unplayed")
                .font(.subheadline)

            Text("Subscribed \(subscription.subscribedAt, format: .dateTime.month(.wide).year())")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let lastRefreshAt = subscription.lastRefreshAt {
                HStack(spacing: 6) {
                    Text("Refreshed \(lastRefreshAt.formatted(.relative(presentation: .named)))")
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if isRefreshing {
                HStack(spacing: 6) {
                    Text("Refreshing")
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if let refreshErrorMessage {
                Label(refreshErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
        .multilineTextAlignment(.center)
    }
}
