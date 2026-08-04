import Foundation

struct PlaybackPositionProtection {
    private static let settleTolerance: TimeInterval = 2.5
    private static let rejectionLimit = 10
    private static let expiration = Duration.seconds(5)

    private(set) var position: TimeInterval?
    private var generation = 0
    private var rejectionCount = 0
    private var startedAt: ContinuousClock.Instant?

    mutating func startSeek(
        to seekPosition: TimeInterval,
        now: ContinuousClock.Instant = .now
    ) -> Int? {
        generation += 1
        rejectionCount = 0
        startedAt = nil

        guard seekPosition.isFinite else {
            position = nil
            return nil
        }

        position = max(0, seekPosition)
        startedAt = now
        return generation
    }

    mutating func completeSeek(generation completedGeneration: Int, finished: Bool) {
        guard completedGeneration == generation else {
            return
        }

        if !finished {
            endProtection()
        }
    }

    mutating func clear() {
        generation += 1
        endProtection()
    }

    mutating func acceptsObservedPosition(
        _ observedPosition: TimeInterval,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard let position else {
            return true
        }

        guard observedPosition.isFinite else {
            return false
        }

        if abs(observedPosition - position) <= Self.settleTolerance {
            endProtection()
            return true
        }

        rejectionCount += 1
        if rejectionCount >= Self.rejectionLimit
            || (startedAt?.duration(to: now) ?? .zero) >= Self.expiration
        {
            endProtection()
            return true
        }

        return false
    }

    private mutating func endProtection() {
        position = nil
        rejectionCount = 0
        startedAt = nil
    }
}
