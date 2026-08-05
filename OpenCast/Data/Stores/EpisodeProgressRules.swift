import Foundation

/// Pure progress-domain rules shared by every progress writer: the
/// completion threshold, the smart-resume rewind, the trivial-progress prune
/// bounds, and the meaningful-change gates that keep routine writes from
/// dirtying synced records.
nonisolated enum EpisodeProgressRules {
    static let completedEpisodeRemainingThreshold: TimeInterval = 60
    static let trivialProgressPrunableMaxPosition: TimeInterval = 60
    static let trivialProgressPrunableMinAge: TimeInterval = 90 * 24 * 60 * 60

    static func isPlayed(position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0, position > 0 else {
            return false
        }

        let clampedPosition = position.clamped(to: 0...duration)
        let remainingThreshold = min(completedEpisodeRemainingThreshold, duration * 0.5)
        return duration - clampedPosition < remainingThreshold
    }

    /// Resuming drops the listener mid-word; rewind a little for context,
    /// more the longer the position has sat. Every resume consumer (play
    /// path, restore, CarPlay/Siri) inherits this through
    /// `LibraryStore.resumePosition`.
    static func smartResumePosition(
        position: TimeInterval,
        updatedAt: Date,
        now: Date
    ) -> TimeInterval {
        guard position > 0 else {
            return position
        }

        let age = now.timeIntervalSince(updatedAt)
        let rewind: TimeInterval = if age < 60 * 60 {
            3
        } else if age < 24 * 60 * 60 {
            10
        } else {
            20
        }
        return max(0, position - rewind)
    }

    @MainActor
    static func hasMeaningfulProgressChange(
        _ existing: EpisodeProgressRecord,
        position: TimeInterval,
        duration: TimeInterval?,
        isPlayed: Bool
    ) -> Bool {
        if existing.isPlayed != isPlayed {
            return true
        }

        if hasMeaningfulDurationChange(existing.duration, duration) {
            return true
        }

        return abs(existing.position - position) >= 1
    }

    static func hasMeaningfulDurationChange(
        _ existing: TimeInterval?,
        _ updated: TimeInterval?
    ) -> Bool {
        switch (existing, updated) {
        case (.none, .none):
            return false
        case (.none, .some), (.some, .none):
            return true
        case let (existing?, updated?):
            guard existing.isFinite, updated.isFinite else {
                return existing != updated
            }
            return abs(existing - updated) >= 1
        }
    }
}
