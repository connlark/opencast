import Foundation

/// Which recap entries the transcript menu offers for the current playhead.
/// Derived off the 1 Hz playback tick and published only when it changes,
/// so the toolbar-owning transcript view re-renders on threshold crossings,
/// never per tick.
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
