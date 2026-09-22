import SwiftData
import SwiftUI

struct LibrarySubscriptionRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var isConfirmingRemoval = false

    let subscription: SubscriptionRecord
    let showsNewEpisodeCount: Bool

    static func accessibilityIdentifier(for feedURL: String) -> String {
        "subscription-row-\(feedURL)"
    }

    private var newEpisodeCount: Int {
        showsNewEpisodeCount ? appModel.library.newEpisodeCount(for: subscription) : 0
    }

    var body: some View {
        let newEpisodeCount = newEpisodeCount

        NavigationLink(value: AppRoute.podcastDetail(feedURL: subscription.feedURL)) {
            SubscriptionRowView(subscription: subscription, newEpisodeCount: newEpisodeCount)
        }
        .accessibilityValue(LibraryNewEpisodeBadge.accessibilityValue(count: newEpisodeCount))
        .accessibilityIdentifier(Self.accessibilityIdentifier(for: subscription.feedURL))
        .modifier(
            SubscriptionRemovalModifier(
                isConfirmingRemoval: $isConfirmingRemoval,
                subscription: subscription,
                supportsSwipeAction: true,
                supportsContextMenu: true
            )
        )
    }
}
