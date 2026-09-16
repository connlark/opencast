/// Token accounting for one response, mirrored from the session usage so
/// callers can size the next turn without touching Foundation Models.
nonisolated struct TranscriptIntelligenceUsage: Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
}
