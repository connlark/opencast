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
        // The chosen speed is the item's default rate whatever the transport does, so a
        // screen paused at 1.5x still reports 1.5x, not 1x.
        let selectedRate = sanitizedPlaybackRate(snapshot.rate)
        let playbackRate = snapshot.state == .playing ? selectedRate : 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyAlbumTitle: episode.podcastTitle,
            MPMediaItemPropertyArtist: episode.podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: selectedRate,
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
