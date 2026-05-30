#if DEBUG
import Foundation
import OpenCastCore

struct OpenCastUITestPodcastDiscoveryService: PodcastDiscoveryService {
    func popular(
        limit: Int,
        country: String,
        allowExplicit: Bool
    ) async throws -> [DirectoryPodcastResult] {
        Array(Self.results.prefix(max(1, limit)))
    }

    private nonisolated static let results = [
        DirectoryPodcastResult(
            id: 9_900_001,
            title: "Deterministic Popular Show",
            artistName: "OpenCast Tests",
            feedURL: URL(string: "https://example.com/ui-test-feed.xml"),
            artworkURL: URL(string: "https://example.com/ui-test-popular-artwork.jpg"),
            collectionViewURL: URL(string: "https://podcasts.apple.com/us/podcast/deterministic-popular-show/id9900001")
        ),
        DirectoryPodcastResult(
            id: 9_900_002,
            title: "Directory Only Suggestion",
            artistName: "OpenCast Tests",
            feedURL: nil,
            artworkURL: nil,
            collectionViewURL: URL(string: "https://podcasts.apple.com/us/podcast/directory-only-suggestion/id9900002")
        )
    ]
}
#endif
