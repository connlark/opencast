import Foundation
@testable import OpenCast

extension EpisodeListItemSnapshot {
    /// Shared construction for the formerly-duplicated per-file `makeEpisode`
    /// copies (dead-code audit finding 9). `audioURL` and `guid` stay
    /// explicit at every call: nil-audio episodes are load-bearing in the
    /// download and remote-transcription suites.
    static func fixture(
        episodeID: String,
        podcastID: String = "https://example.com/feed.xml",
        podcastTitle: String = "Example Show",
        title: String = "Example Episode",
        summary: String? = nil,
        publishedAt: Date? = nil,
        duration: TimeInterval? = 60,
        audioURL: String?,
        artworkURL: String? = nil,
        artworkPreview: ArtworkPreview? = nil,
        guid: String?,
        cachedAt: Date = .now
    ) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: podcastID,
            podcastTitle: podcastTitle,
            title: title,
            summary: summary,
            publishedAt: publishedAt,
            duration: duration,
            audioURL: audioURL,
            artworkURL: artworkURL,
            artworkPreview: artworkPreview,
            guid: guid,
            cachedAt: cachedAt
        )
    }
}
