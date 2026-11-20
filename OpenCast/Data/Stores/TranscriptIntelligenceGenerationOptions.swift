/// Reasoning stays `.light`: deeper levels never engaged on transcript-sized inputs, and on
/// short ones hidden reasoning tokens eat the context.
nonisolated struct TranscriptIntelligenceGenerationOptions: Equatable, Sendable {
    enum ToolCalling: Equatable, Sendable {
        case allowed
        case required
        case disallowed
    }

    /// Nil lets the model decide.
    var maximumResponseTokens: Int?
    var toolCalling = ToolCalling.allowed
}
