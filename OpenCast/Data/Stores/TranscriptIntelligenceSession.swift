import FoundationModels

nonisolated protocol TranscriptIntelligenceSession: AnyObject {
    /// Includes replayed history.
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

    /// Returns the completed response exactly as the non-streaming form would.
    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        options: TranscriptIntelligenceGenerationOptions,
        onPartialContent: @escaping @MainActor (GeneratedContent) -> Void
    ) async throws -> TranscriptIntelligenceResponse<Content>
}
