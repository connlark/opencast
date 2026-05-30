import Foundation
@preconcurrency import MediaPlayer

struct NowPlayingInfoBuilder {
    func info(
        for snapshot: PlaybackSnapshot,
        resolvedDuration: TimeInterval?,
        artwork: MPMediaItemArtwork?
    ) -> [String: Any]? {
        guard let episode = snapshot.currentEpisode else {
            return nil
        }

        let duration = snapshot.bestFiniteDuration(preferring: resolvedDuration)
        let elapsedTime = clampPlaybackPosition(snapshot.position, to: duration)
        let playbackRate = snapshot.state == .playing ? sanitizedPlaybackRate(snapshot.rate) : 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyAlbumTitle: episode.podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]

        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        return info
    }

    private func sanitizedPlaybackRate(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else {
            return 1
        }

        return rate
    }
}
