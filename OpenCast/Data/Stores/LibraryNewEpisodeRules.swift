import Foundation

nonisolated enum LibraryNewEpisodeRules {
    static let recencyWindow: TimeInterval = 30 * 24 * 60 * 60

    static func eligibleReleaseDates(subscribedAt: Date, asOf: Date) -> ClosedRange<Date>? {
        let lowerBound = max(subscribedAt, asOf.addingTimeInterval(-recencyWindow))
        guard lowerBound.timeIntervalSinceReferenceDate <= asOf.timeIntervalSinceReferenceDate else {
            return nil
        }

        return lowerBound...asOf
    }
}
