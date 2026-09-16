import Foundation

/// Recap outcomes that are not model failures.
nonisolated enum TranscriptRecapError: LocalizedError, Equatable {
    /// The playhead is too early for the requested window.
    case nothingToRecap(TranscriptRecapWindowKind)

    var errorDescription: String? {
        switch self {
        case .nothingToRecap(.lastFiveMinutes):
            "Play a little of the episode first, then recap the last few minutes."
        case .nothingToRecap(.soFar):
            "Recap So Far needs at least fifteen minutes of the episode played."
        }
    }
}
