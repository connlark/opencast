import Foundation

nonisolated struct PlaylistCoverSources: Equatable, Sendable {
    static let maximumArtworkCount = 4

    let artworkURLs: [URL]
    let fallbackTitle: String

    static func make(
        summary: PlaylistSummary,
        items: [PlaylistItem],
        podcastArtworkURL: (String) -> URL?
    ) -> PlaylistCoverSources {
        var artworkURLs: [URL] = []
        for podcastID in summary.coverPodcastIDs {
            guard artworkURLs.count < maximumArtworkCount else {
                break
            }
            let url = podcastArtworkURL(podcastID) ?? items.lazy
                .filter { $0.podcastID == podcastID }
                .compactMap { $0.artworkURL.flatMap(URL.init(string:)) }
                .first
            if let url {
                artworkURLs.append(url)
            }
        }
        return PlaylistCoverSources(artworkURLs: artworkURLs, fallbackTitle: summary.name)
    }
}
