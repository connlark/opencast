import FoundationModels

/// The slice of Foundation Models the transcript features drive, so tests can
/// script it. The client owns eligibility and quota reads plus the on-device
/// token count that sizes prompts before they are sent; sessions are per
/// operation. Every thrown error is already a `TranscriptIntelligenceFailure`.
nonisolated protocol TranscriptIntelligenceModelClient: AnyObject {
    /// Stable name for the model behind this client, keyed into cached
    /// results so a model change never serves a stale recap.
    var modelIdentifier: String { get }
    var modelAvailability: TranscriptIntelligenceModelAvailability { get }
    var quota: TranscriptIntelligenceQuotaSnapshot { get }
    func tokenCount(for text: String) async throws -> Int
    /// Presents Apple's own limit-increase flow when the quota snapshot
    /// carries a suggestion; a no-op otherwise.
    func showLimitIncreaseSuggestion()
    func makeSession(instructions: String, tools: [any Tool]) -> any TranscriptIntelligenceSession
}
