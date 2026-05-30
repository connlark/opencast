import Foundation

nonisolated func finitePositive(_ value: TimeInterval?) -> TimeInterval? {
    guard let value, value.isFinite, value > 0 else {
        return nil
    }

    return value
}

nonisolated func clampPlaybackPosition(_ position: TimeInterval, to duration: TimeInterval?) -> TimeInterval {
    guard position.isFinite else {
        return 0
    }

    let lowerBounded = max(0, position)
    if let duration = finitePositive(duration) {
        return min(lowerBounded, duration)
    }

    return lowerBounded
}

extension PlaybackSnapshot {
    nonisolated func bestFiniteDuration(preferring resolvedDuration: TimeInterval?) -> TimeInterval? {
        finitePositive(resolvedDuration)
            ?? finitePositive(duration)
            ?? finitePositive(currentEpisode?.duration)
    }
}

nonisolated func clampedPlaybackRate(_ rate: Float) -> Float {
    guard rate.isFinite else {
        return 1
    }

    return rate.clamped(to: 0.5...3)
}
