import Foundation

/// Point-in-time copy of `PrivateCloudComputeLanguageModel.quotaUsage`.
/// Advisory only: a request can still be rate limited while this reads below
/// the limit, so the store treats the request failure as authoritative.
nonisolated struct TranscriptIntelligenceQuotaSnapshot: Equatable, Sendable {
    var isLimitReached = false
    var isApproachingLimit = false
    var resetDate: Date?
    var hasLimitIncreaseSuggestion = false
}
