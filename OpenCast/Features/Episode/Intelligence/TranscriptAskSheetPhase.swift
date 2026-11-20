enum TranscriptAskSheetPhase: Equatable {
    case loading
    case disclosure
    case unavailable(TranscriptIntelligenceAvailability)
    case failed(String)
    case ready
}
