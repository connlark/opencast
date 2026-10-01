import Foundation

/// The artwork a playlist's mosaic cover draws: one image per distinct show,
/// in item order, at most four, plus the title whose initials stand in when
/// no show has artwork.
nonisolated struct PlaylistCoverSources: Equatable, Sendable {
    static let maximumArtworkCount = 4

    let artworkURLs: [URL]
    let fallbackTitle: String

    /// Prefers the show's current artwork and falls back to an item's stored
    /// artwork, so shows that are no longer in the library still draw.
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
