import SwiftData
import SwiftUI

struct LibrarySubscriptionGridView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let subscriptions: [SubscriptionRecord]
    /// Opens every show under these Inbox settings instead of its stored filter.
    var episodeListOverride: PodcastEpisodeListOverride? = nil
    /// The badge each tile shows; the grouped Inbox varies it per show.
    let badge: (SubscriptionRecord) -> LibrarySubscriptionBadge

    var body: some View {
        // Reads the width in the same layout pass, so the first frame
        // already has its final column count.
        GeometryReader { proxy in
            let metrics = LibraryGridMetrics.resolve(
                containerWidth: proxy.size.width,
                isCompact: horizontalSizeClass == .compact || verticalSizeClass == .compact,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )

            ScrollView {
                LazyVGrid(columns: metrics.columns, spacing: metrics.rowSpacing) {
                    ForEach(subscriptions) { subscription in
                        LibrarySubscriptionTileView(
                            subscription: subscription,
                            metrics: metrics,
                            badge: badge(subscription),
                            episodeListOverride: episodeListOverride
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .swipeActionsContainer()
            .accessibilityIdentifier("Library Grid")
            .contentMargins(.horizontal, metrics.horizontalMargin, for: .scrollContent)
            .contentMargins(.bottom, 72, for: .scrollContent)
        }
    }
}
