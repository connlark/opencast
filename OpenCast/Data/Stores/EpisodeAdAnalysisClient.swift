import Foundation

nonisolated protocol EpisodeAdAnalysisClient: Sendable {
    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome
    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome
    func servingPolicyRevision() async throws -> String?
}

extension EpisodeAdAnalysisClient {
    func servingPolicyRevision() async throws -> String? { nil }
}
