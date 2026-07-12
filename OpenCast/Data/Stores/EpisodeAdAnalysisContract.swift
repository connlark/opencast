import Foundation

enum EpisodeAdAnalysisContract {
    nonisolated static let schemaVersion = 1
    nonisolated static let completedTranscriptState = EpisodeTranscriptState.completed.rawValue
    /// Analyses from any other policy (e.g. the retired `ads_only` cue-fragment
    /// contract) are treated as outdated: no zones, no skipping, manual re-run.
    nonisolated static let expectedPolicy = "promo_ad_breaks_v2"
}
