import Foundation

struct PlaybackPositionProtection {
    private static let settleTolerance: TimeInterval = 2.5

    private(set) var position: TimeInterval?
    private var generation = 0

    mutating func startSeek(to seekPosition: TimeInterval) -> Int? {
        generation += 1

        guard seekPosition.isFinite else {
            position = nil
            return nil
        }

        position = max(0, seekPosition)
        return generation
    }

    mutating func completeSeek(generation completedGeneration: Int, finished: Bool) {
        guard completedGeneration == generation else {
            return
        }

        if !finished {
            position = nil
        }
    }

    mutating func clear() {
        generation += 1
        position = nil
    }

    mutating func acceptsObservedPosition(_ observedPosition: TimeInterval) -> Bool {
        guard let position else {
            return true
        }

        guard observedPosition.isFinite else {
            return false
        }

        if abs(observedPosition - position) <= Self.settleTolerance {
            self.position = nil
            return true
        }

        return false
    }
}
