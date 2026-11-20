import Foundation

enum PlaylistOrganizerShowChoiceBuilder {
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
