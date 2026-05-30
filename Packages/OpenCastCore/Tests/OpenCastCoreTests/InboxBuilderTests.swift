import Foundation
import OpenCastCore
import Testing

@Suite("Inbox builder")
struct InboxBuilderTests {
    @Test("Sorts newest first and filters played episodes")
    func sortsAndFilters() {
        let podcastID = PodcastID(rawValue: "https://jumble.top/f/americanprestige.xml")
        let old = Episode(
            id: EpisodeID(rawValue: "old"),
            podcastID: podcastID,
            podcastTitle: "American Prestige",
            title: "Old",
            publishedAt: Date(timeIntervalSince1970: 1)
        )
        let new = Episode(
            id: EpisodeID(rawValue: "new"),
            podcastID: podcastID,
            podcastTitle: "American Prestige",
            title: "New",
            publishedAt: Date(timeIntervalSince1970: 2)
        )
        let progress = [
            new.id: EpisodeProgress(episodeID: new.id, isPlayed: true)
        ]

        let inbox = InboxBuilder.buildInbox(episodes: [old, new], progressByEpisodeID: progress)
        let includingPlayed = InboxBuilder.buildInbox(
            episodes: [old, new],
            progressByEpisodeID: progress,
            includePlayed: true
        )

        #expect(inbox.map(\.id.rawValue) == ["old"])
        #expect(includingPlayed.map(\.id.rawValue) == ["new", "old"])
    }
}
