enum TranscriptRecapSheetPhase: Equatable {
    case loading
    case disclosure
    case unavailable(TranscriptIntelligenceAvailability)
    case nothingToRecap(TranscriptRecapWindowKind)
    case loaded(TranscriptRecapResult)
    case failed(TranscriptIntelligenceFailure)
}
