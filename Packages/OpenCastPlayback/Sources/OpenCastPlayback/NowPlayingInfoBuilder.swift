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
        // The speed the listener chose is this item's normal speed, whatever the
        // transport is doing. Publishing it keeps a paused-at-1.5x screen —
        // where the current rate is necessarily 0 — reporting 1.5x rather than
        // the 1x a hardcoded default would claim.
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
