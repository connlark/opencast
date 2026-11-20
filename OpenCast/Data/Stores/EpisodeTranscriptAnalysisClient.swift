import Foundation

/// Only drains jobs an earlier build submitted; a current build analyses on the device.
nonisolated protocol EpisodeTranscriptAnalysisClient: Sendable {
    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome
}
