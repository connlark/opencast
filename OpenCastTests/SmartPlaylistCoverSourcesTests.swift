import Foundation
import Testing
@testable import OpenCast

/// Which shows a smart playlist's cover draws: by dominance, deduplicated,
/// capped at three, with the podcast's artwork preferred over an episode's.
@Suite("Smart playlist cover sources")
struct SmartPlaylistCoverSourcesTests {
    private static let podcastArtwork: [String: URL] = [
        "alpha": url("alpha-show"),
        "bravo": url("bravo-show"),
        "charlie": url("charlie-show"),
        "delta": url("delta-show")
    ]

    @Test("Shows order by episode count, ties by first appearance in rule order")
    func ordersByDominanceThenFirstAppearance() {
        let episodes = [
            episode("bravo"),
            episode("alpha"),
            episode("charlie"),
            episode("alpha"),
            episode("charlie"),
            episode("alpha")
        ]

        let sources = make(episodes)

        // alpha holds three, charlie two, bravo one.
        #expect(sources.artworkURLs == [Self.url("alpha-show"), Self.url("charlie-show"), Self.url("bravo-show")])
    }

    @Test("A tie keeps the show that appears first")
    func tieKeepsFirstAppearance() {
        let sources = make([episode("charlie"), episode("alpha"), episode("alpha"), episode("charlie")])

        #expect(sources.artworkURLs == [Self.url("charlie-show"), Self.url("alpha-show")])
    }

    @Test("Each show draws once, however many episodes it has")
    func deduplicatesShows() {
        let sources = make(Array(repeating: episode("delta"), count: 5))

        #expect(sources.artworkURLs == [Self.url("delta-show")])
    }

    @Test("At most three shows draw, the most dominant ones")
    func capsAtThreeShows() {
        let episodes = [
            episode("delta"),
            episode("alpha"), episode("alpha"),
            episode("bravo"), episode("bravo"), episode("bravo"),
            episode("charlie"), episode("charlie")
        ]

        let sources = make(episodes)

        #expect(SmartPlaylistCoverSources.maximumShowCount == 3)
        #expect(sources.artworkURLs == [Self.url("bravo-show"), Self.url("alpha-show"), Self.url("charlie-show")])
    }

    @Test("No episodes draw nothing, so the cover falls back to its symbol")
    func emptyEvaluationDrawsNothing() {
        #expect(make([]) == .empty)
        #expect(make([]).artworkURLs.isEmpty)
    }

    @Test("A show without podcast artwork falls back to the first of its episodes with artwork")
    func fallsBackToEpisodeArtwork() {
        let episodes = [
            episode("removed", artwork: nil),
            episode("removed", artwork: "removed-episode-2"),
            episode("removed", artwork: "removed-episode-3")
        ]

        #expect(make(episodes).artworkURLs == [Self.url("removed-episode-2")])
    }

    @Test("The podcast's artwork wins over an episode's own artwork")
    func prefersPodcastArtwork() {
        #expect(make([episode("alpha", artwork: "alpha-episode")]).artworkURLs == [Self.url("alpha-show")])
    }

    @Test("A show with no artwork at all gives its place to the next show")
    func skipsShowsWithoutArtwork() {
        let episodes = [
            episode("bare", artwork: nil), episode("bare", artwork: nil), episode("bare", artwork: nil),
            episode("delta"), episode("delta"),
            episode("alpha"),
            episode("bravo"),
            episode("charlie")
        ]

        #expect(make(episodes).artworkURLs == [Self.url("delta-show"), Self.url("alpha-show"), Self.url("bravo-show")])
    }

    @Test("Shows sharing one image draw it once, so the stack never repeats a card")
    func skipsRepeatedArtwork() {
        let shared = Self.url("shared")
        let sources = SmartPlaylistCoverSources.make(
            episodes: [episode("alpha"), episode("alpha"), episode("bravo"), episode("charlie")]
        ) { podcastID in
            podcastID == "charlie" ? Self.url("charlie-show") : shared
        }

        #expect(sources.artworkURLs == [shared, Self.url("charlie-show")])
    }

    private func make(_ episodes: [EpisodeListItemSnapshot]) -> SmartPlaylistCoverSources {
        SmartPlaylistCoverSources.make(episodes: episodes) { Self.podcastArtwork[$0] }
    }

    private static func url(_ name: String) -> URL {
        URL(string: "https://example.com/art/\(name).jpg")!
    }

    private func episode(_ podcastID: String, artwork: String? = "episode") -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: UUID().uuidString,
            podcastID: podcastID,
            podcastTitle: podcastID.capitalized,
            title: "Episode",
            summary: nil,
            publishedAt: nil,
            duration: 600,
            audioURL: "https://example.com/audio/\(podcastID).mp3",
            artworkURL: artwork.map { Self.url($0).absoluteString },
            artworkPreview: nil,
            guid: nil,
            cachedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
