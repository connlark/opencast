import Foundation

public nonisolated struct PlaybackEpisodeBoundaries: Equatable, Sendable {
    public static let disabled = PlaybackEpisodeBoundaries()

    public let skipIntroSeconds: TimeInterval
    public let skipOutroSeconds: TimeInterval

    public init(
        skipIntroSeconds: TimeInterval = 0,
        skipOutroSeconds: TimeInterval = 0
    ) {
        self.skipIntroSeconds = Self.sanitized(skipIntroSeconds)
        self.skipOutroSeconds = Self.sanitized(skipOutroSeconds)
    }

    public func ordinaryStartPosition(
        _ position: TimeInterval,
        duration: TimeInterval?
    ) -> TimeInterval {
        let position = clampPlaybackPosition(position, to: duration)
        guard let duration = finitePositive(duration) else {
            return max(position, skipIntroSeconds)
        }
        guard hasPositivePlayableSpan(duration: duration) else {
            return position
        }
        return max(position, skipIntroSeconds.clamped(to: 0...duration))
    }

    public func replayPosition(duration: TimeInterval?) -> TimeInterval {
        ordinaryStartPosition(0, duration: duration)
    }

    public func outroCutoff(duration: TimeInterval?) -> TimeInterval? {
        guard skipOutroSeconds > 0,
              let duration = finitePositive(duration),
              hasPositivePlayableSpan(duration: duration)
        else {
            return nil
        }
        return duration - skipOutroSeconds
    }

    public func automaticEndPosition(duration: TimeInterval?) -> TimeInterval? {
        guard let duration = finitePositive(duration) else {
            return nil
        }
        return outroCutoff(duration: duration) ?? duration
    }

    public func crossesOutro(
        from previousPosition: TimeInterval,
        to position: TimeInterval,
        duration: TimeInterval?
    ) -> Bool {
        guard previousPosition.isFinite,
              position.isFinite,
              let cutoff = outroCutoff(duration: duration)
        else {
            return false
        }
        return previousPosition < cutoff && position >= cutoff
    }

    private func hasPositivePlayableSpan(duration: TimeInterval) -> Bool {
        skipIntroSeconds + skipOutroSeconds < duration
    }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value >= 0 ? value : 0
    }
}
