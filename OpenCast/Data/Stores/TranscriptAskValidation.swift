/// What survived citation validation for one answer: citations whose id
/// names a segment the tools actually showed the model this turn, in the
/// order the model gave them, and the ids that were dropped.
nonisolated struct TranscriptAskValidation: Equatable, Sendable {
    var citations: [TranscriptAskCitation]
    var droppedCitationIDs: [Int]
}
