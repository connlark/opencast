import Foundation

/// The data nuke's invalidation token for library write flows. A flow
/// captures the generation before its first suspension and re-checks it
/// after every await that precedes a write, so work parked across the nuke
/// unwinds instead of resurrecting rows into the reset store.
///
/// Exactly one instance exists per library, shared by reference with every
/// type that captures or checks: `invalidate()` on a second instance would
/// never reach the flows holding the first.
final class LibraryWriteGeneration {
    private(set) var current = 0

    func capture() -> Int {
        current
    }

    func invalidate() {
        current += 1
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }

    /// Unwinds like cancellation: callers already treat CancellationError as
    /// normal, so nuke invalidation never surfaces as a user-visible error.
    func ensureCurrent(_ generation: Int) throws {
        if !isCurrent(generation) {
            throw CancellationError()
        }
    }
}
