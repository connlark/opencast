import Foundation
import OpenCastCore

public struct PlaybackSnapshot: Equatable, Sendable {
    public var state: PlaybackState
    public var currentEpisode: Episode?
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var rate: Float
    public var sleepTimerEndsAt: Date?
    public var progressBoundaryID: Int

    public init(
        state: PlaybackState = .idle,
        currentEpisode: Episode? = nil,
        position: TimeInterval = 0,
        duration: TimeInterval? = nil,
        rate: Float = 1,
        sleepTimerEndsAt: Date? = nil,
        progressBoundaryID: Int = 0
    ) {
        self.state = state
        self.currentEpisode = currentEpisode
        self.position = position
        self.duration = duration
        self.rate = rate
        self.sleepTimerEndsAt = sleepTimerEndsAt
        self.progressBoundaryID = progressBoundaryID
    }

    public nonisolated var normalizedProgress: Double {
        normalizedProgress(for: position)
    }

    public nonisolated func normalizedProgress(for position: TimeInterval) -> Double {
        guard let duration, duration.isFinite, duration > 0, position.isFinite else {
            return 0
        }

        return (position / duration).clamped01
    }
}
