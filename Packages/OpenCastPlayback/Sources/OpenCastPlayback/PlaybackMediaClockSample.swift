import Foundation

/// Consumers derive their state from `position`; samples are not events to count.
public struct PlaybackMediaClockSample: Equatable, Sendable {
    public let position: TimeInterval
    public let rate: Float
    public let isPlaying: Bool

    public init(position: TimeInterval, rate: Float, isPlaying: Bool) {
        self.position = position
        self.rate = rate
        self.isPlaying = isPlaying
    }
}
