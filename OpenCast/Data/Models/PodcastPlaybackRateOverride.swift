import Foundation
import OpenCastPlayback

/// Converts between a show's stored speed (`SubscriptionRecord.playbackRate`,
/// a `Double` where 0 follows the global speed) and the controller's `Float`
/// rate. Stored values go through the global clamp, never a step snap, so an
/// off-step value synced from another device plays as written.
nonisolated enum PodcastPlaybackRateOverride {
    /// The rate a stored value plays at, or nil when the show follows the
    /// global speed.
    static func resolved(_ stored: Double) -> Float? {
        guard stored.isFinite, stored > 0 else {
            return nil
        }

        let rate = Float(stored)
        // Past Float's range the conversion gives infinity, which the clamp
        // would read as 1x rather than as too fast.
        return PlaybackRateSteps.clamped(rate.isFinite ? rate : .greatestFiniteMagnitude)
    }

    static func stored(_ rate: Float?) -> Double {
        guard let rate else {
            return 0
        }

        return Double(PlaybackRateSteps.clamped(rate))
    }

    /// Whether a rate is one the global clamp keeps as it is (0.5x to 3x).
    static func isValid(_ rate: Float) -> Bool {
        PlaybackRateSteps.clamped(rate) == rate
    }

    /// The greatest stored value that resolves to a speed, else 0, so twin
    /// records merge to the same value in any order.
    static func merged(_ values: some Sequence<Double>) -> Double {
        values.filter { resolved($0) != nil }.max() ?? 0
    }

    static func nearestStep(to rate: Float) -> Float {
        PlaybackRateSteps.steps.min { abs($0 - rate) < abs($1 - rate) } ?? 1
    }
}
