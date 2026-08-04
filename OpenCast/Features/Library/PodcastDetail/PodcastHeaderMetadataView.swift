import SwiftUI

struct PodcastHeaderMetadataView: View {
    let subscription: SubscriptionRecord
    let episodeCount: Int
    let unplayedCount: Int
    let lastRefreshedAt: Date?
    let isRefreshing: Bool
    let refreshErrorMessage: String?
    var health: FeedHealthStatus?
    var notificationHealth: NotificationFeedHealth?

    var body: some View {
        VStack(spacing: 5) {
            Text("\(episodeCount) episodes · \(unplayedCount) unplayed")
                .font(.subheadline)

            Text("Subscribed \(subscription.subscribedAt, format: .dateTime.month(.wide).year())")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let checkedUpdatedLine = health?.checkedUpdatedLine {
                HStack(spacing: 6) {
                    Text(checkedUpdatedLine)
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let lastRefreshedAt {
                HStack(spacing: 6) {
                    Text("Refreshed \(lastRefreshedAt.formatted(.relative(presentation: .named)))")
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

            if let notificationHealth, notificationHealth.isDegraded {
                Label("Notifications degraded for this show", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let health, health.replacesRefreshedLine, let statusLine = health.statusLine {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let refreshErrorMessage {
                Label(
                    refreshErrorMessage,
                    systemImage: health?.kind == .partial
                        ? "exclamationmark.circle"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .multilineTextAlignment(.center)
            }
        }
        .multilineTextAlignment(.center)
    }
}
