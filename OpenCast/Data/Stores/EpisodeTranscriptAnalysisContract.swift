import Foundation

enum EpisodeTranscriptAnalysisContract {
    nonisolated static let schemaVersion = 1
    nonisolated static let completedTranscriptState = EpisodeTranscriptState.completed.rawValue
    /// An analysis from any other policy is outdated.
    nonisolated static let expectedPolicy = "transcript_analysis_v2"
}
