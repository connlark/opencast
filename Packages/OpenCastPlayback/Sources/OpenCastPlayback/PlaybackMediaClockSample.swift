import Foundation

/// One wake-up from the transcript-scoped media clock. Consumers derive their
/// complete state from `position`; samples are never events to count.
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
