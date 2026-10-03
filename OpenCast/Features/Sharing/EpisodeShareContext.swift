import Foundation
import OpenCastCore

/// What the Share menu offers for one episode: the plain link and, when the
/// episode has a playhead, a "Share from 12:34" link, or "Share from Current
/// Time" while it plays. Built from the cached snapshot, never the playback
/// item, whose audio URL becomes the local file once the episode is
/// downloaded.
struct EpisodeShareContext: Equatable, Sendable {
    /// Where "Share from" starts.
    enum Playhead {
        /// The current episode while it plays.
        case playing
        /// The current episode while it is not playing, at the player's
        /// position.
        case paused(TimeInterval)
        /// Any other episode, at its saved progress.
        case saved(EpisodeProgressSummary)
    }

    /// The "Share from" entry.
    enum Start: Equatable {
        /// A fixed start, labelled with its time.
        case fixed(URL, label: String)
        /// Wherever the playing episode is when the link is shared, minted by
        /// `url(startingAt:)`.
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

    /// The link starting at `position`, or the plain link when the page would
    /// ignore that start. Nonisolated: the share sheet mints "Share from
    /// Current Time" off the main thread.
    nonisolated func url(startingAt position: TimeInterval) -> URL {
        guard let startSeconds = Self.startSeconds(at: position, payload: payload),
              let startURL = try? EpisodeShareURL.url(base: baseURL, payload: payload, startSeconds: startSeconds)
        else {
            return url
        }
        return startURL
    }

    /// The one place live playback and progress state is read. An open menu
    /// rebuilds whenever its content changes, which collapsed the Share
    /// submenu before an item could be tapped and made the Now Playing menu
    /// pulse, and SwiftUI realises menu content once rather than on each
    /// opening, so a sampled position would go stale. Nothing read here may
    /// change while the episode plays: its position is read only when the
    /// link is shared, and its saved progress, refreshed as it plays, is not
    /// read at all.
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

    /// Whole seconds, floored like the player's clock, so the link starts
    /// where the label says; nil for a start the page ignores.
    private nonisolated static func startSeconds(at position: TimeInterval, payload: EpisodeSharePayload) -> Int? {
        guard position.isFinite, position >= 1, position < Double(payload.maximumStartSeconds + 1) else {
            return nil
        }
        return Int(position.rounded(.down))
    }
}
