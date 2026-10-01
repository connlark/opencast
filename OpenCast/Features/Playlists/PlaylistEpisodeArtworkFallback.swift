import Foundation

/// Playlist items keep their artwork after the show leaves the library,
/// so an episode without its own artwork is filed with the show's.
nonisolated enum PlaylistEpisodeArtworkFallback {
    static func episode(
        _ episode: EpisodeListItemSnapshot,
        showArtworkURL: String?
    ) -> EpisodeListItemSnapshot {
        guard episode.artworkURL == nil, let showArtworkURL else {
            return episode
        }
        return EpisodeListItemSnapshot(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            podcastTitle: episode.podcastTitle,
            title: episode.title,
            summary: episode.summary,
            publishedAt: episode.publishedAt,
            duration: episode.duration,
            audioURL: episode.audioURL,
            artworkURL: showArtworkURL,
            artworkPreview: episode.artworkPreview,
            guid: episode.guid,
            cachedAt: episode.cachedAt
        )
    }
}
