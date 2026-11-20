nonisolated struct TranscriptAskValidation: Equatable, Sendable {
    var citations: [TranscriptAskCitation]
    var droppedCitationIDs: [Int]
}
