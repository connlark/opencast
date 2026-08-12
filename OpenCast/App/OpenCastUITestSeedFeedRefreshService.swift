import Foundation
import OpenCastCore

nonisolated struct OpenCastUITestSeedFeedRefreshService: FeedService {
    private static let feedURLString = "https://example.com/ui-test-feed.xml"
    private static let podcastTitle = "UI Test Show"
    private static let episodeID = "ui-test-episode-1"

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard url.absoluteString == Self.feedURLString,
              let feedURL = URL(string: Self.feedURLString)
        else {
            throw OpenCastCoreError.invalidFeedURL
        }

        let podcastID = PodcastID(rawValue: Self.feedURLString)
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: feedURL,
                title: Self.podcastTitle,
                author: "UI Test Author",
                summary: "A deterministic show updated through feed refresh.",
                websiteURL: URL(string: "https://example.com/ui-test-show")
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: Self.episodeID),
                    podcastID: podcastID,
                    podcastTitle: Self.podcastTitle,
                    title: "Deterministic UI Episode — Refresh Boundary Signal",
                    summary: "Updated metadata returned by the UI-test feed refresh.",
                    showNotesHTML: "<p>Refreshed deterministic show notes for UI tests.</p>",
                    publishedAt: Date(timeIntervalSince1970: 1_777_776_000),
                    duration: 180,
                    audioURL: URL(string: "https://example.com/ui-test-refreshed.mp3"),
                    guid: Self.episodeID
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_777_777_000)
        )
    }
}
