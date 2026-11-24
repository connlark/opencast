#if DEBUG
import Foundation
import OpenCastCore

nonisolated struct OpenCastUITestDirectoryService: PodcastDirectoryService {
    static let environmentKey = "OPENCAST_UI_TEST_DIRECTORY_FIXTURE"

    func search(query: String) async throws -> [DirectoryPodcastResult] {
        [
            Self.result(id: "preview", title: "UI Test Preview Show", feedURL: OpenCastUITestDirectoryFeedService.feedURL),
            Self.result(id: "unreachable", title: "UI Test Unreachable Show", feedURL: URL(string: "https://unreachable.example.com/feed.xml")!),
        ]
    }

    private static func result(id: String, title: String, feedURL: URL) -> DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: "uitest:\(id)",
            title: title,
            artistName: "UI Test Author",
            genre: "Technology",
            feedURL: feedURL,
            sources: [.apple],
            feedCandidates: [DirectoryFeedCandidate(source: .apple, feedURL: feedURL)]
        )
    }
}

nonisolated struct OpenCastUITestDirectoryFeedService: FeedService {
    static let feedURL = URL(string: "https://example.com/ui-test-preview-feed.xml")!

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard url == Self.feedURL else {
            throw URLError(.cannotFindHost)
        }

        let podcastID = URLCanonicalizer.podcastID(for: url)
        let launchedAt = Date.now
        let episodes = (0..<5).map { index in
            Episode(
                id: EpisodeID(rawValue: "ui-test-preview-episode-\(index)"),
                podcastID: podcastID,
                podcastTitle: "UI Test Preview Show",
                title: "Preview Fixture Episode \(5 - index)",
                publishedAt: launchedAt.addingTimeInterval(Double(-index * 7 * 86_400)),
                duration: 1_500,
                audioURL: URL(string: "https://example.com/ui-test-preview-\(index).mp3"),
                guid: "ui-test-preview-episode-\(index)"
            )
        }
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: url,
                title: "UI Test Preview Show",
                author: "UI Test Author",
                summary: "A fixed show the journey test previews before subscribing."
            ),
            episodes: episodes
        )
    }
}
#endif
