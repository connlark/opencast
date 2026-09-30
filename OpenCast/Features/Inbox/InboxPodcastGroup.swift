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
        var subscriptionsByFeedURL: [String: SubscriptionRecord] = [:]
        for subscription in subscriptions where subscriptionsByFeedURL[subscription.feedURL] == nil {
            subscriptionsByFeedURL[subscription.feedURL] = subscription
        }

        var orderedPodcastIDs: [String] = []
        var countsByPodcastID: [String: Int] = [:]
        for episode in episodes {
            guard subscriptionsByFeedURL[episode.podcastID] != nil else {
                continue
            }
            if countsByPodcastID[episode.podcastID] == nil {
                orderedPodcastIDs.append(episode.podcastID)
            }
            countsByPodcastID[episode.podcastID, default: 0] += 1
        }

        return orderedPodcastIDs.compactMap { podcastID in
            guard let subscription = subscriptionsByFeedURL[podcastID],
                  let episodeCount = countsByPodcastID[podcastID]
            else {
                return nil
            }
            return InboxPodcastGroup(subscription: subscription, episodeCount: episodeCount)
        }
    }
}
