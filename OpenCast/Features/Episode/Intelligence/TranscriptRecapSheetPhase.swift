/// The recap sheet's screen states, in the order a first request passes
/// through them: eligibility, the one-time disclosure, the request, and its
/// outcome.
enum TranscriptRecapSheetPhase: Equatable {
    case loading
    case disclosure
    case unavailable(TranscriptIntelligenceAvailability)
    case nothingToRecap(TranscriptRecapWindowKind)
    case loaded(TranscriptRecapResult)
    case failed(TranscriptIntelligenceFailure)
}
