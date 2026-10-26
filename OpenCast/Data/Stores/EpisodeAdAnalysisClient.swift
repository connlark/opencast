import Foundation

/// Reads ad-analysis jobs an earlier build started on opencast's analysis
/// service, so a job accepted before the update still finishes. New
/// analyses run on the device and never create a job.
nonisolated protocol EpisodeAdAnalysisClient: Sendable {
    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome
}
