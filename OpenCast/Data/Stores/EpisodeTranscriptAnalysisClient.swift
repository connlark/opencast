import Foundation

/// The analysis service's job read. A current build runs Chapters & Summary
/// on the device; this only drains a job the service accepted from an
/// earlier build, so there is no submit.
nonisolated protocol EpisodeTranscriptAnalysisClient: Sendable {
    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome
}
