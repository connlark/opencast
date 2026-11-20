import FoundationModels

/// Every thrown error is already a `TranscriptIntelligenceFailure`.
nonisolated protocol TranscriptIntelligenceModelClient: AnyObject {
    /// Keys cached results, so a model change never serves a stale recap.
    var modelIdentifier: String { get }
    var modelAvailability: TranscriptIntelligenceModelAvailability { get }
    var quota: TranscriptIntelligenceQuotaSnapshot { get }
    func tokenCount(for text: String) async throws -> Int
    func showLimitIncreaseSuggestion()
    func makeSession(instructions: String, tools: [any Tool]) -> any TranscriptIntelligenceSession
}
