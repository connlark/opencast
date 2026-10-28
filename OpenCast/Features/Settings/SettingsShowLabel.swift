import SwiftUI

/// A show's artwork and title, with an optional summary line, as the
/// per-show rows in Settings lead with them.
struct SettingsShowLabel: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let subscription: SubscriptionRecord
    let summary: String?

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: subscription.feedURL)
    }

    /// Accessibility sizes put the artwork above the text, which then has
    /// the row's full width.
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            ArtworkPlaceholder(
                title: subscription.title,
                imageURL: podcastCache?.artworkURL ?? subscription.artworkURL,
                size: 40,
                preview: podcastCache.flatMap { appModel.library.artworkPreview(for: $0) }
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.title)
                    .lineLimit(2)
                if let summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
