import Foundation
import OpenCastCore

/// Built from the cached snapshot, never the playback item, whose audio URL becomes the local
/// file once the episode is downloaded.
struct EpisodeShareContext: Equatable, Sendable {
    enum Playhead {
        case playing
        case paused(TimeInterval)
        case saved(EpisodeProgressSummary)
    }

    enum Start: Equatable {
        case fixed(URL, label: String)
        /// Resolved when the link is shared, by `url(startingAt:)`.
        case currentTime
    }

    let title: String
    let artworkURL: URL?
    let url: URL
    let start: Start?
    private let payload: EpisodeSharePayload
    private let baseURL: URL

    static func make(
        episode: EpisodeListItemSnapshot,
        playhead: Playhead,
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

        let start: Start? = switch playhead {
        case .playing:
            .currentTime
        case .paused(let position):
            fixedStart(at: position, payload: payload, baseURL: baseURL)
        case .saved(let progress):
            // A finished episode has no visible progress, so no playhead.
            progress.hasVisibleProgress
                ? fixedStart(at: progress.position, payload: payload, baseURL: baseURL)
                : nil
        }

        return EpisodeShareContext(
            title: payload.title,
            artworkURL: URL(string: payload.artworkURL),
            url: url,
            start: start,
            payload: payload,
            baseURL: baseURL
        )
    }

    /// Nonisolated: the share sheet mints "Share from Current Time" off the main thread.
    nonisolated func url(startingAt position: TimeInterval) -> URL {
        guard let startSeconds = Self.startSeconds(at: position, payload: payload),
              let startURL = try? EpisodeShareURL.url(base: baseURL, payload: payload, startSeconds: startSeconds)
        else {
            return url
        }
        return startURL
    }

    /// Nothing read here may change while the episode plays: an open menu rebuilds when its
    /// content changes, collapsing the Share submenu, and SwiftUI realises menu content once, so
    /// a sampled position would go stale. The position is read only when the link is shared.
    static func make(episode: EpisodeListItemSnapshot, appModel: OpenCastAppModel) -> EpisodeShareContext? {
        let playback = appModel.playback
        // Loading and buffering count as playing, so a stall does not swap
        // the entry under an open menu.
        let playhead: Playhead = if playback.currentEpisode?.id.rawValue != episode.episodeID {
            .saved(appModel.library.progressSummary(for: episode))
        } else if playback.state.showsPauseButton {
            .playing
        } else {
            .paused(playback.position)
        }
        return make(episode: episode, playhead: playhead)
    }

    private static func fixedStart(
        at position: TimeInterval,
        payload: EpisodeSharePayload,
        baseURL: URL
    ) -> Start? {
        guard let startSeconds = startSeconds(at: position, payload: payload),
              let startURL = try? EpisodeShareURL.url(base: baseURL, payload: payload, startSeconds: startSeconds)
        else {
            return nil
        }
        return .fixed(startURL, label: TimeInterval(startSeconds).formattedPlaybackDuration)
    }

    /// Whole seconds, floored like the player's clock, so the link starts where the label says.
    private nonisolated static func startSeconds(at position: TimeInterval, payload: EpisodeSharePayload) -> Int? {
        guard position.isFinite, position >= 1, position < Double(payload.maximumStartSeconds + 1) else {
            return nil
        }
        return Int(position.rounded(.down))
    }
}
