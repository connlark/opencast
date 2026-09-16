/// A completed turn: the content (plain text or a `@Generable` value), the
/// token usage, and every tool exchange the model made to produce it.
nonisolated struct TranscriptIntelligenceResponse<Content> {
    var content: Content
    var usage: TranscriptIntelligenceUsage
    var toolExchanges: [TranscriptIntelligenceToolExchange]
}

extension TranscriptIntelligenceResponse: Sendable where Content: Sendable {}
