import Foundation

/// Estimates the playback position between 1 Hz position ticks so the active
/// word can advance smoothly while playing.
nonisolated struct TranscriptPositionInterpolator: Equatable {
    var basePosition: TimeInterval
    var baseDate: Date
    var rate: Double
    var isPlaying: Bool

    func estimatedTime(at date: Date) -> TimeInterval {
        guard isPlaying, rate > 0 else {
            return basePosition
        }
        return basePosition + max(date.timeIntervalSince(baseDate), 0) * rate
    }
}
