/// The Ask sheet's screen states, in the order a first open passes through
/// them: eligibility, the one-time disclosure, index building, and the
/// conversation.
enum TranscriptAskSheetPhase: Equatable {
    case loading
    case disclosure
    case unavailable(TranscriptIntelligenceAvailability)
    case failed(String)
    case ready
}
