import Foundation

struct EpisodeProgressSummary: Equatable {
    let position: TimeInterval
    let duration: TimeInterval?
    let fractionCompleted: Double
    let remaining: TimeInterval?
    let isCompleted: Bool

    var hasVisibleProgress: Bool {
        guard !isCompleted, position >= 1 else {
            return false
        }

        return fractionCompleted > 0 || duration == nil
    }

    var remainingText: String? {
        guard !isCompleted, let remaining else {
            return nil
        }

        return remaining.formattedEpisodeRemaining
    }

    var accessibilityDescription: String {
        if isCompleted {
            return "Completed"
        }

        if let remainingText {
            return remainingText
        }

        if hasVisibleProgress {
            return "In progress"
        }

        return "Not started"
    }
}
