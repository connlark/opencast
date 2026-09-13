#if os(iOS)
import NowPlaying

extension PlaybackMediaSessionAdapter: @MainActor MediaSessionRepresentable {
    var content: (any MediaContentRepresentable)? {
        guard let values else { return nil }
        let artwork = artworkRequest.map { request in
            Artwork(id: request.id) { _ in
                try ArtworkRepresentation(cgImage: await request.image())
            }
        }
        return PodcastContent(
            id: values.episodeID.rawValue,
            episodeTitle: values.title,
            showName: values.showName,
            releaseDate: values.releaseDate,
            type: .audio,
            duration: values.duration.map(MediaDuration.finite),
            artwork: artwork
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard let values else { return nil }
        let state: MediaPlaybackSnapshot.PlaybackState = switch values.state {
        case .playing: .playing(rate: values.defaultPlaybackRate)
        case .buffering: .buffering
        case .paused, .loading, .failed: .paused
        case .idle: .stopped
        }
        return MediaPlaybackSnapshot(
            state: state,
            defaultPlaybackRate: values.defaultPlaybackRate,
            elapsedTime: values.elapsedTime,
            timestamp: snapshotTimestamp
        )
    }

    var commands: [MediaCommand] {
        PlaybackMediaCommand.Kind.allCases.compactMap { kind in
            guard availableCommands.contains(kind) else { return nil }
            switch kind {
            case .play: return .play { try self.perform(.play) }
            case .pause: return .pause { try self.perform(.pause) }
            case .togglePlayPause: return .togglePlayPause { try self.perform(.togglePlayPause) }
            case .skipForward:
                return .skipForward(preferredIntervals: [skipForwardInterval]) { _ in
                    try self.perform(.skipForward)
                }
            case .skipBackward:
                return .skipBackward(preferredIntervals: [skipBackwardInterval]) { _ in
                    try self.perform(.skipBackward)
                }
            case .next: return .next { try self.perform(.next) }
            case .previous: return .previous { try self.perform(.previous) }
            case .seek: return .seekToPosition { try self.perform(.seek($0)) }
            case .changeRate:
                return .changePlaybackRate(supported: PlaybackRateSteps.steps) {
                    try self.perform(.changeRate($0))
                }
            }
        }
    }
}
#endif
