import Foundation

nonisolated protocol EpisodeTranscriptAnalysisClient: Sendable {
    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome
    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome
    /// Links this install to its purchase account (worker bootstrap route).
    /// Envelope lanes only — the bearer probe lane has no install identity.
    func bootstrapAccount() async throws
}

/// Clients without an account seam (test fakes, fixtures) refuse quietly;
/// both shipping clients implement the route.
extension EpisodeTranscriptAnalysisClient {
    func bootstrapAccount() async throws {
        throw EpisodeTranscriptAnalysisError.clientDisabled
    }
}
