nonisolated struct TranscriptIntelligenceResponse<Content> {
    var content: Content
    var usage: TranscriptIntelligenceUsage
    var toolExchanges: [TranscriptIntelligenceToolExchange]
}

extension TranscriptIntelligenceResponse: Sendable where Content: Sendable {}
