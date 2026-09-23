import Foundation
import OpenCastCore

/// What the Share menu offers for one episode: the plain link and, when the
/// episode has a playhead, a "Share from 12:34" link. Built from the cached
/// snapshot, never the playback item, whose audio URL becomes the local file
/// once the episode is downloaded.
struct EpisodeShareContext: Equatable {
    let title: String
    let artworkURL: URL?
    let url: URL
    let startURL: URL?
    let startLabel: String?

    static func make(
        episode: EpisodeListItemSnapshot,
        isCurrentEpisode: Bool,
        livePosition: TimeInterval,
        progress: EpisodeProgressSummary,
        baseURL: URL = OpenCastConstants.episodeShareBaseURL
    ) -> EpisodeShareContext? {
        guard let payload = EpisodeSharePayload(
            audioURL: episode.audioURL,
            title: episode.title,
            podcastTitle: episode.podcastTitle,
            artworkURL: episode.artworkURL,
            feedURL: episode.podcastID,
            guid: episode.guid,
            duration: episode.duration,
            publishedAt: episode.publishedAt
        ),
            let url = try? EpisodeShareURL.url(base: baseURL, payload: payload)
        else {
            return nil
        }

        // Whole seconds, floored like the player's clock, so the link starts
        // where the label says. A finished episode has no playhead to share,
        // and the page ignores a start past the end of the episode.
        let position = isCurrentEpisode ? livePosition : progress.hasVisibleProgress ? progress.position : 0
        let startSeconds = position.isFinite && position >= 1 && position < Double(payload.maximumStartSeconds + 1)
            ? Int(position.rounded(.down))
            : 0
        let offersStart = startSeconds >= 1 && (isCurrentEpisode || !progress.isCompleted)
        let startURL = offersStart
            ? try? EpisodeShareURL.url(base: baseURL, payload: payload, startSeconds: startSeconds)
            : nil

        return EpisodeShareContext(
            title: payload.title,
            artworkURL: URL(string: payload.artworkURL),
            url: url,
            startURL: startURL,
            startLabel: startURL == nil ? nil : TimeInterval(startSeconds).formattedPlaybackDuration
        )
    }

    /// The one place live playback and progress state is read.
    static func make(episode: EpisodeListItemSnapshot, appModel: OpenCastAppModel) -> EpisodeShareContext? {
        let isCurrentEpisode = appModel.playback.currentEpisode?.id.rawValue == episode.episodeID
        return make(
            episode: episode,
            isCurrentEpisode: isCurrentEpisode,
            livePosition: isCurrentEpisode ? appModel.playback.position : 0,
            progress: appModel.library.progressSummary(for: episode)
        )
    }
}
