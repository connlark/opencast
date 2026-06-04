import Foundation
import OpenCastCore
import Testing

@Suite("Inbox builder")
struct InboxBuilderTests {
    @Test("Sorts newest first and keeps played episodes by default")
    func sortsAndKeepsPlayedEpisodes() {
        let podcastID = PodcastID(rawValue: "https://example.com/american-prestige.xml")
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
        let hidingPlayed = InboxBuilder.buildInbox(
            episodes: [old, new],
            progressByEpisodeID: progress,
            includePlayed: false
        )

        #expect(inbox.map(\.id.rawValue) == ["new", "old"])
        #expect(hidingPlayed.map(\.id.rawValue) == ["old"])
    }
}
