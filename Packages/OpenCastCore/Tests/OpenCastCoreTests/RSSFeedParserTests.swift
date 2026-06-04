import Foundation
import OpenCastCore
import Testing

@Suite("RSS feed parsing")
struct RSSFeedParserTests {
    @Test("Parses RSS and iTunes namespace fields from the American Prestige fixture")
    func parsesFixture() throws {
        let snapshot = try fixtureSnapshot()

        #expect(snapshot.podcast.title == "American Prestige")
        #expect(snapshot.podcast.author == "American Prestige")
        #expect(snapshot.podcast.id.rawValue == "https://example.com/american-prestige.xml")
        #expect(snapshot.podcast.artworkURL?.absoluteString == "https://example.com/american-prestige.jpg")
        #expect(snapshot.episodes.count == 2)
        #expect(snapshot.episodes[0].title == "Episode With GUID")
        #expect(snapshot.episodes[0].duration == 3_723)
        #expect(snapshot.episodes[0].showNotesHTML?.contains("Full notes") == true)
    }

    @Test("Parses enclosure audio URLs")
    func parsesAudioURLs() throws {
        let snapshot = try fixtureSnapshot()

        #expect(snapshot.episodes[0].audioURL?.absoluteString == "https://example.com/audio/ap-001.mp3")
        #expect(snapshot.episodes[1].audioURL?.absoluteString == "https://example.com/audio/ap-002.mp3")
    }

    @Test("Parses fallback identity inputs when GUID and duration are missing")
    func parsesFallbackIdentityInputs() throws {
        let feedURL = URL(string: "https://example.com/fallbacks.xml")!
        let snapshot = try fixtureSnapshot(named: "fallbacks", feedURL: feedURL)
        let audioEpisode = try #require(snapshot.episodes.first { $0.title == "Audio URL Stable Original" })
        let titleDateEpisode = try #require(snapshot.episodes.first { $0.title == "Title Date Stable" })

        #expect(audioEpisode.duration == nil)
        #expect(audioEpisode.guid == nil)
        #expect(audioEpisode.audioURL?.absoluteString == "https://example.com/audio/stable-audio.mp3")
        #expect(
            audioEpisode.id == EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: nil,
                audioURL: audioEpisode.audioURL,
                title: "Audio URL Stable Retitled",
                publishedAt: audioEpisode.publishedAt
            )
        )

        #expect(titleDateEpisode.duration == nil)
        #expect(titleDateEpisode.guid == nil)
        #expect(titleDateEpisode.audioURL == nil)
        #expect(
            titleDateEpisode.id == EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: nil,
                audioURL: nil,
                title: "Title Date Stable",
                publishedAt: titleDateEpisode.publishedAt
            )
        )
    }

    @Test("Rejects feeds with no episodes")
    func rejectsFeedsWithNoEpisodes() throws {
        let url = try #require(Bundle.module.url(forResource: "empty", withExtension: "xml"))
        let data = try Data(contentsOf: url)

        #expect(throws: OpenCastCoreError.self) {
            try RSSFeedParser().parse(data: data, feedURL: URL(string: "https://example.com/empty.xml")!)
        }
    }
}

private func fixtureSnapshot() throws -> FeedSnapshot {
    try fixtureSnapshot(
        named: "americanprestige",
        feedURL: URL(string: "https://example.com/american-prestige.xml")!
    )
}

private func fixtureSnapshot(named name: String, feedURL: URL) throws -> FeedSnapshot {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml"))
    let data = try Data(contentsOf: url)
    return try RSSFeedParser().parse(data: data, feedURL: feedURL)
}
