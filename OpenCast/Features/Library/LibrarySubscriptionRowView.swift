import SwiftData
import SwiftUI

struct LibrarySubscriptionRowView: View {
    @State private var isConfirmingRemoval = false

    let subscription: SubscriptionRecord

    static func accessibilityIdentifier(for feedURL: String) -> String {
        "subscription-row-\(feedURL)"
    }

    var body: some View {
        NavigationLink(value: AppRoute.podcastDetail(feedURL: subscription.feedURL)) {
            SubscriptionRowView(subscription: subscription)
        }
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
