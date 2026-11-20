import Foundation

/// Only finishes server jobs an earlier build started; new analyses run on the device.
nonisolated protocol EpisodeAdAnalysisClient: Sendable {
    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome
}
