import Foundation

/// Played-state-dependent playlist figures, computed on demand because played
/// state lives in the library's progress index rather than the playlist store.
nonisolated struct PlaylistCounts: Equatable, Sendable {
    var itemCount: Int
    var unplayedCount: Int
    var remainingDuration: TimeInterval
}
