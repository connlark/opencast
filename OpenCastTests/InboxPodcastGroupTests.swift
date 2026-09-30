import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Inbox podcast groups")
struct InboxPodcastGroupTests {
    @Test("Groups follow the order of each show's newest matching episode and count its episodes")
    func groupsKeepInboxOrderAndCount() {
        let alpha = SubscriptionRecord(feedURL: "https://example.com/alpha.xml", title: "Alpha")
        let beta = SubscriptionRecord(feedURL: "https://example.com/beta.xml", title: "Beta")
        let episodes = [
            makeEpisode(id: "beta-1", podcastID: beta.feedURL),
            makeEpisode(id: "alpha-1", podcastID: alpha.feedURL),
            makeEpisode(id: "beta-2", podcastID: beta.feedURL),
            makeEpisode(id: "beta-3", podcastID: beta.feedURL)
        ]

        let groups = InboxPodcastGroup.make(episodes: episodes, subscriptions: [alpha, beta])

        #expect(groups.map(\.id) == [beta.feedURL, alpha.feedURL])
        #expect(groups.map(\.episodeCount) == [3, 1])
    }

    @Test("Episodes without a subscription and shows without episodes have no group")
    func skipsUnmatchedShowsAndEpisodes() {
        let subscribed = SubscriptionRecord(feedURL: "https://example.com/subscribed.xml", title: "Subscribed")
        let silent = SubscriptionRecord(feedURL: "https://example.com/silent.xml", title: "Silent")
        let episodes = [
            makeEpisode(id: "orphan", podcastID: "https://example.com/removed.xml"),
            makeEpisode(id: "kept", podcastID: subscribed.feedURL)
        ]

        let groups = InboxPodcastGroup.make(episodes: episodes, subscriptions: [subscribed, silent])

        #expect(groups.map(\.id) == [subscribed.feedURL])
        #expect(groups.map(\.episodeCount) == [1])
    }

    @Test("An empty episode list yields no groups")
    func emptyEpisodes() {
        let subscription = SubscriptionRecord(feedURL: "https://example.com/feed.xml", title: "Show")

        #expect(InboxPodcastGroup.make(episodes: [], subscriptions: [subscription]).isEmpty)
    }

    private func makeEpisode(id: String, podcastID: String) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: id,
            podcastID: podcastID,
            title: "Episode \(id)",
            audioURL: "https://example.com/\(id).mp3",
            guid: id
        )
    }
}
