import Foundation

nonisolated enum PlaybackEndOfEpisodeSleepTimer {
    static func remainingPlaybackDuration(
        endPosition: TimeInterval?,
        position: TimeInterval,
        rate: Float
    ) -> TimeInterval? {
        guard let endPosition = finitePositive(endPosition),
              position.isFinite,
              rate.isFinite,
              rate > 0
        else {
            return nil
        }

        let remainingMediaTime = endPosition - position.clamped(to: 0...endPosition)
        guard remainingMediaTime > 0 else {
            return nil
        }
        return remainingMediaTime / TimeInterval(rate)
    }
}
