import SwiftData
import SwiftUI

struct LibrarySubscriptionRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var isConfirmingRemoval = false

    let subscription: SubscriptionRecord
    let badge: LibrarySubscriptionBadge
    /// Opens the show under these Inbox settings instead of its stored filter.
    var episodeListOverride: PodcastEpisodeListOverride? = nil

    static func accessibilityIdentifier(for feedURL: String) -> String {
        "subscription-row-\(feedURL)"
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
            SubscriptionRowView(subscription: subscription, newEpisodeCount: badgeCount)
        }
        .accessibilityValue(badge.accessibilityValue(count: badgeCount))
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
