import Foundation

struct InboxPodcastGroup: Identifiable {
    let subscription: SubscriptionRecord
    /// In Inbox order.
    let episodes: [EpisodeListItemSnapshot]

    var id: String {
        subscription.feedURL
    }

    var episodeCount: Int {
        episodes.count
    }

    /// `episodes` are the filtered Inbox rows, in Inbox order.
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
