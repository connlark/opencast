import Foundation

enum EpisodeTranscriptAnalysisContract {
    nonisolated static let schemaVersion = 1
    nonisolated static let completedTranscriptState = EpisodeTranscriptState.completed.rawValue
    /// The serving prompt is byte-pinned to this policy; analyses from any
    /// other policy are outdated — no chapters, no summary, manual re-run.
    nonisolated static let expectedPolicy = "transcript_analysis_v2"
}
