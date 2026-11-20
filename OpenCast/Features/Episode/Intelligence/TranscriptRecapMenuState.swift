import Foundation

/// Derived off the 1 Hz tick but published only when it changes, so its owner re-renders on
/// threshold crossings, never per tick.
nonisolated struct TranscriptRecapMenuState: Equatable, Sendable {
    var canRecapLastFiveMinutes = false
    var showsRecapSoFar = false

    static func resolve(playhead: TimeInterval) -> TranscriptRecapMenuState {
        TranscriptRecapMenuState(
            canRecapLastFiveMinutes: playhead >= TranscriptRecapWindowKind.lastFiveMinutes.minimumPlayhead,
            showsRecapSoFar: playhead >= TranscriptRecapWindowKind.soFar.minimumPlayhead
        )
    }
}
