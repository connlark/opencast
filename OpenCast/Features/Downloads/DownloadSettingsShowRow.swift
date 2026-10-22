import SwiftUI

/// A show in Download Settings: whether it downloads new episodes and the
/// Keep Downloaded choice it has, or the default it follows.
struct DownloadSettingsShowRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let subscription: SubscriptionRecord

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: subscription.feedURL)
    }

    private var summary: String {
        let settings = appModel.downloadSettings
        let automation = settings.autoDownloadsNewEpisodes(forPodcastID: subscription.feedURL)
            ? "Downloads new episodes"
            : "Manual"
        let keepLimit = settings.keepLimitOverride(forPodcastID: subscription.feedURL)?.shortTitle
            ?? "Default (\(settings.defaultKeepLimit.title))"
        return "\(automation) · \(keepLimit)"
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
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
