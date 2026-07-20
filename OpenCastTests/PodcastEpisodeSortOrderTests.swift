import Foundation
import Testing
@testable import OpenCast

@Suite("Podcast episode sort order")
struct PodcastEpisodeSortOrderTests {
    @Test("Persistence raw values stay stable")
    func persistenceRawValuesStayStable() {
        #expect(PodcastEpisodeSortOrder.newestFirst.rawValue == "newestFirst")
        #expect(PodcastEpisodeSortOrder.oldestFirst.rawValue == "oldestFirst")
        #expect(PodcastEpisodeSortOrder.longestFirst.rawValue == "longestFirst")
        #expect(PodcastEpisodeSortOrder.shortestFirst.rawValue == "shortestFirst")
        #expect(PodcastEpisodeFilter.all.rawValue == "all")
        #expect(PodcastEpisodeFilter.unplayed.rawValue == "unplayed")
        #expect(PodcastEpisodeFilter.inProgress.rawValue == "inProgress")
        #expect(PodcastEpisodeFilter.played.rawValue == "played")
        #expect(PodcastEpisodeFilter.downloaded.rawValue == "downloaded")
    }

    @Test("Oldest first sinks undated episodes and breaks ties deterministically")
    func oldestFirstOrdering() {
        let episodes = [
            makeEpisode(id: "undated-b", title: "Beta", publishedAt: nil),
            makeEpisode(id: "newer", title: "Newer", publishedAt: 20),
            makeEpisode(id: "undated-a", title: "Alpha", publishedAt: nil),
            makeEpisode(id: "older-b", title: "Same", publishedAt: 10),
            makeEpisode(id: "older-a", title: "Same", publishedAt: 10)
        ]

        let sorted = episodes.sorted(by: EpisodeListItemSnapshot.oldestFirst)

        #expect(sorted.map(\.episodeID) == ["older-a", "older-b", "newer", "undated-a", "undated-b"])
    }

    @Test("Duration sorts sink zero and missing durations in both directions")
    func durationOrdering() {
        let episodes = [
            makeEpisode(id: "missing-old", publishedAt: 10, duration: nil),
            makeEpisode(id: "long", publishedAt: 30, duration: 300),
            makeEpisode(id: "zero-new", publishedAt: 40, duration: 0),
            makeEpisode(id: "short", publishedAt: 20, duration: 60)
        ]

        let longest = episodes.sorted(by: EpisodeListItemSnapshot.longestFirst)
        let shortest = episodes.sorted(by: EpisodeListItemSnapshot.shortestFirst)

        #expect(longest.map(\.episodeID) == ["long", "short", "zero-new", "missing-old"])
        #expect(shortest.map(\.episodeID) == ["short", "long", "zero-new", "missing-old"])
    }

    @Test("Equal duration falls back to newest date and episode ID")
    func durationTieBreaks() {
        let episodes = [
            makeEpisode(id: "same-b", publishedAt: 10, duration: 100),
            makeEpisode(id: "newest", publishedAt: 20, duration: 100),
            makeEpisode(id: "same-a", publishedAt: 10, duration: 100)
        ]

        #expect(
            episodes.sorted(by: EpisodeListItemSnapshot.longestFirst).map(\.episodeID)
                == ["newest", "same-a", "same-b"]
        )
        #expect(
            episodes.sorted(by: EpisodeListItemSnapshot.shortestFirst).map(\.episodeID)
                == ["newest", "same-a", "same-b"]
        )
    }

    private func makeEpisode(
        id: String,
        title: String = "Episode",
        publishedAt: TimeInterval?,
        duration: TimeInterval? = 120
    ) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Podcast",
            title: title,
            summary: nil,
            publishedAt: publishedAt.map { Date(timeIntervalSince1970: $0) },
            duration: duration,
            audioURL: "https://example.com/\(id).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: id,
            cachedAt: .now
        )
    }
}
