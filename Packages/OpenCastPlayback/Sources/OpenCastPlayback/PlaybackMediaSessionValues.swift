import Foundation
import OpenCastCore

struct PlaybackMediaSessionValues: Equatable {
    let episodeID: EpisodeID
    let title: String
    let showName: String
    let releaseDate: Date?
    let artworkURL: URL?
    let duration: TimeInterval?
    let elapsedTime: TimeInterval
    let defaultPlaybackRate: Float
    let state: PlaybackState

    init?(_ snapshot: PlaybackSnapshot, resolvedDuration: TimeInterval?) {
        guard let episode = snapshot.currentEpisode else { return nil }
        episodeID = episode.id
        title = episode.title
        showName = episode.podcastTitle
        releaseDate = episode.publishedAt
        artworkURL = episode.artworkURL
        duration = snapshot.bestFiniteDuration(preferring: resolvedDuration)
        elapsedTime = clampPlaybackPosition(snapshot.position, to: duration)
        defaultPlaybackRate = snapshot.rate.isFinite && snapshot.rate > 0 ? snapshot.rate : 1
        state = snapshot.state
    }

    var playbackRate: Float {
        state == .playing ? defaultPlaybackRate : 0
    }

    var availableCommands: Set<PlaybackMediaCommand.Kind> {
        var commands: Set<PlaybackMediaCommand.Kind> = [
            .togglePlayPause, .skipForward, .skipBackward, .next, .previous, .changeRate
        ]
        commands.insert(state == .playing || state == .buffering ? .pause : .play)
        if duration != nil { commands.insert(.seek) }
        return commands
    }
}
