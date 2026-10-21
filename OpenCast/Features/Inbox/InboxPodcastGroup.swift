import Foundation

/// One show in the Group by Podcast Inbox: the subscription and which of
/// its episodes pass the current filter, newest first. Groups keep the
/// Inbox's order, so a show appears where its newest matching episode would.
struct InboxPodcastGroup: Identifiable {
    let subscription: SubscriptionRecord
    /// The show's Inbox rows, in Inbox order; the row count is the badge.
    let episodes: [EpisodeListItemSnapshot]

    var id: String {
        subscription.feedURL
    }

    var episodeCount: Int {
        episodes.count
    }

    /// `episodes` are the filtered Inbox rows. An episode whose show is no
    /// longer subscribed has no cell to stand in and is skipped.
    static func make(
        episodes: [EpisodeListItemSnapshot],
        subscriptions: [SubscriptionRecord]
    ) -> [InboxPodcastGroup] {
        var orderedPodcastIDs: [String] = []
        var episodesByPodcastID: [String: [EpisodeListItemSnapshot]] = [:]
        for episode in episodes {
            if episodesByPodcastID[episode.podcastID] == nil {
                orderedPodcastIDs.append(episode.podcastID)
            }
            episodesByPodcastID[episode.podcastID, default: []].append(episode)
        }

        let subscriptionsByFeedURL = Dictionary(
            subscriptions.map { ($0.feedURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return orderedPodcastIDs.compactMap { podcastID in
            subscriptionsByFeedURL[podcastID].map { subscription in
                InboxPodcastGroup(subscription: subscription, episodes: episodesByPodcastID[podcastID, default: []])
            }
        }
    }
}
