import SwiftData
import SwiftUI

struct LibrarySubscriptionGridView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let subscriptions: [SubscriptionRecord]
    let showsNewEpisodeCount: Bool

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
                            showsNewEpisodeCount: showsNewEpisodeCount
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
