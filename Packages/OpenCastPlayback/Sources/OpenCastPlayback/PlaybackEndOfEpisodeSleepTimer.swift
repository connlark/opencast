import Foundation

nonisolated enum PlaybackEndOfEpisodeSleepTimer {
    static func remainingPlaybackDuration(
        duration: TimeInterval?,
        position: TimeInterval,
        rate: Float
    ) -> TimeInterval? {
        guard let duration = finitePositive(duration),
              position.isFinite,
              rate.isFinite,
              rate > 0
        else {
            return nil
        }

        let remainingMediaTime = duration - position.clamped(to: 0...duration)
        guard remainingMediaTime > 0 else {
            return nil
        }
        return remainingMediaTime / TimeInterval(rate)
    }
}
