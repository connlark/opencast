import Foundation

/// Builds the show picker's rows from the library's subscriptions.
enum PlaylistOrganizerShowChoiceBuilder {
    /// Library order, one choice per feed URL (first record wins); title and
    /// artwork from the podcast cache first, the subscription second.
    static func make(
        subscriptions: [SubscriptionRecord],
        podcastCache: (String) -> PodcastCacheSnapshot?,
        episodeCount: (String) -> Int
    ) -> [PlaylistOrganizerShowChoice] {
        var seenFeedURLs = Set<String>()
        return subscriptions.compactMap { subscription in
            let feedURL = subscription.feedURL
            guard seenFeedURLs.insert(feedURL).inserted else {
                return nil
            }
            let podcast = podcastCache(feedURL)
            return PlaylistOrganizerShowChoice(
                podcastID: feedURL,
                title: podcast?.title ?? subscription.title,
                author: podcast?.author ?? subscription.author,
                artworkURL: podcast?.artworkURL ?? subscription.artworkURL,
                artworkPreview: podcast?.artworkPreview,
                episodeCount: episodeCount(feedURL)
            )
        }
    }
}
