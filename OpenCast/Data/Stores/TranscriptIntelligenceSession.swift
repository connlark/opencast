import FoundationModels

/// One conversation with the model. Recap uses a single turn; Ask keeps the
/// session across questions and reseeds a fresh one once the input grows.
nonisolated protocol TranscriptIntelligenceSession: AnyObject {
    /// Input tokens the session has consumed so far, including replayed
    /// history; Ask cuts a new session past its budget.
    var inputTokenCount: Int { get }

    func respond(
        to prompt: String,
        options: TranscriptIntelligenceGenerationOptions
    ) async throws -> TranscriptIntelligenceResponse<String>

    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        options: TranscriptIntelligenceGenerationOptions
    ) async throws -> TranscriptIntelligenceResponse<Content>

    /// Streams the structured turn: every partial snapshot reaches
    /// `onPartialContent` as raw generated content (callers read the fields
    /// they render early, such as an answer's text), and the completed
    /// response is returned exactly as the non-streaming form would.
    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        options: TranscriptIntelligenceGenerationOptions,
        onPartialContent: @escaping @MainActor (GeneratedContent) -> Void
    ) async throws -> TranscriptIntelligenceResponse<Content>
}
