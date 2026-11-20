import Foundation

/// Capture before a flow's first suspension and re-check after every await that precedes a write,
/// so work parked across a data nuke unwinds. Share one instance by reference: `invalidate()` on a
/// second instance never reaches the flows holding the first.
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

    /// Throws `CancellationError` so a nuke unwinds like cancellation and never shows an error.
    func ensureCurrent(_ generation: Int) throws {
        if !isCurrent(generation) {
            throw CancellationError()
        }
    }
}
