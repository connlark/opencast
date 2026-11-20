import Foundation

/// Every surface that persists or summarizes progress uses these, so all agree on a usable
/// duration and an in-range position.
nonisolated func sanitizedDuration(_ duration: TimeInterval?) -> TimeInterval? {
    guard let duration, duration.isFinite, duration > 0 else {
        return nil
    }
    return duration
}

nonisolated func sanitizedPosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
    let lowerBounded = position.isFinite ? max(0, position) : 0
    guard let duration else {
        return lowerBounded
    }
    return min(lowerBounded, duration)
}
