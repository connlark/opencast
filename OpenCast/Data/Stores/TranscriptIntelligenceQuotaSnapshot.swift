import Foundation

/// Advisory only: a request can be rate limited while this reads below the limit, so the
/// request failure is authoritative.
nonisolated struct TranscriptIntelligenceQuotaSnapshot: Equatable, Sendable {
    var isLimitReached = false
    var isApproachingLimit = false
    var resetDate: Date?
    var hasLimitIncreaseSuggestion = false
}
