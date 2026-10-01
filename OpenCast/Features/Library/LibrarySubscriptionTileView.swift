import SwiftData
import SwiftUI

struct LibrarySubscriptionTileView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var isConfirmingRemoval = false

    let subscription: SubscriptionRecord
    let metrics: LibraryGridMetrics
    let showsNewEpisodeCount: Bool

    private var newEpisodeCount: Int {
        showsNewEpisodeCount ? appModel.library.newEpisodeCount(for: subscription) : 0
    }

    var body: some View {
        let newEpisodeCount = newEpisodeCount

        NavigationLink(value: AppRoute.podcastDetail(feedURL: subscription.feedURL)) {
            SubscriptionTileView(subscription: subscription, metrics: metrics, badgeCount: newEpisodeCount)
        }
        .buttonStyle(.plain)
        .accessibilityValue(LibraryNewEpisodeBadge.accessibilityValue(count: newEpisodeCount))
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
}
