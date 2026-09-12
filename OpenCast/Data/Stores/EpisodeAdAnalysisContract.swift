import Foundation

enum EpisodeAdAnalysisContract {
    nonisolated static let schemaVersion = 1
    nonisolated static let completedTranscriptState = EpisodeTranscriptState.completed.rawValue
    /// Production stays on v2 during the v3 staging bake-off. Both contracts
    /// produce complete-break spans in the same schema; older cue-fragment or
    /// unknown future policies remain unusable. This does not invalidate v2.
    nonisolated static let expectedPolicy = "promo_ad_breaks_v2"
    nonisolated static let wordBoundaryPolicy = "promo_ad_breaks_v3"

    nonisolated static func supports(policy: String) -> Bool {
        policy == expectedPolicy || policy == wordBoundaryPolicy
    }
}
