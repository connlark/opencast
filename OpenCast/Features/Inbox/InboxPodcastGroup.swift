import Foundation

/// One show in the Group by Podcast Inbox: the subscription and how many of
/// its episodes pass the current filter. Groups keep the Inbox's order, so a
/// show appears where its newest matching episode would.
struct InboxPodcastGroup: Identifiable {
    let subscription: SubscriptionRecord
    let episodeCount: Int

    var id: String {
        subscription.feedURL
    }

    /// `episodes` are the filtered Inbox rows. An episode whose show is no
    /// longer subscribed has no cell to stand in and is skipped.
    static func make(
        episodes: [EpisodeListItemSnapshot],
        subscriptions: [SubscriptionRecord]
    ) -> [InboxPodcastGroup] {
        var orderedPodcastIDs: [String] = []
        var countsByPodcastID: [String: Int] = [:]
        for episode in episodes {
            if countsByPodcastID[episode.podcastID] == nil {
                orderedPodcastIDs.append(episode.podcastID)
            }
            countsByPodcastID[episode.podcastID, default: 0] += 1
        }

        let subscriptionsByFeedURL = Dictionary(
            subscriptions.map { ($0.feedURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return orderedPodcastIDs.compactMap { podcastID in
            subscriptionsByFeedURL[podcastID].map { subscription in
                InboxPodcastGroup(subscription: subscription, episodeCount: countsByPodcastID[podcastID, default: 0])
            }
        }
    }
}
