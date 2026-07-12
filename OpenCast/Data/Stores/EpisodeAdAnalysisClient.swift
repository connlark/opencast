import Foundation

nonisolated protocol EpisodeAdAnalysisClient: Sendable {
    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisAPIResponse
}
