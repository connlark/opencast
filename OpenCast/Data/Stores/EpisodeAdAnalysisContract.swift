import Foundation

enum EpisodeAdAnalysisContract {
    nonisolated static let schemaVersion = 1
    nonisolated static let completedTranscriptState = EpisodeTranscriptState.completed.rawValue
    /// Production serves v3 since 2026-09-18; v2 stays accepted for cached
    /// analyses and as the server's rollback policy. Both contracts
    /// produce complete-break spans in the same schema; older cue-fragment or
    /// unknown future policies remain unusable. This does not invalidate v2.
    nonisolated static let expectedPolicy = "promo_ad_breaks_v2"
    nonisolated static let wordBoundaryPolicy = "promo_ad_breaks_v3"

    nonisolated static func supports(policy: String) -> Bool {
        policy == expectedPolicy || policy == wordBoundaryPolicy
    }
}
