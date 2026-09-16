/// Per-turn knobs the product actually varies. Reasoning stays `.light` in the
/// client: deeper levels never engaged on transcript-sized inputs and, when
/// they do engage on short ones, hidden reasoning tokens eat the context.
nonisolated struct TranscriptIntelligenceGenerationOptions: Equatable, Sendable {
    enum ToolCalling: Equatable, Sendable {
        case allowed
        case required
        case disallowed
    }

    /// Output headroom measured on device before the send; nil lets the
    /// model decide.
    var maximumResponseTokens: Int?
    var toolCalling = ToolCalling.allowed
}
