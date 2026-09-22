import Foundation

/// What the Library's new-episode badges count: incomplete episodes released
/// since the show was followed and within the recency window. Deliberately
/// not the show page's all-time unplayed total, so a back catalog never
/// badges and the count clears itself as episodes age out.
nonisolated enum LibraryNewEpisodeRules {
    static let recencyWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Publication dates that count as new at `asOf`, both bounds inclusive;
    /// nil when the show was followed after `asOf`. Future-dated episodes fall
    /// outside the range until they are released.
    static func eligibleReleaseDates(subscribedAt: Date, asOf: Date) -> ClosedRange<Date>? {
        let lowerBound = max(subscribedAt, asOf.addingTimeInterval(-recencyWindow))
        guard lowerBound <= asOf else {
            return nil
        }

        return lowerBound...asOf
    }
}
