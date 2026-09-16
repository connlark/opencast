/// One completed question and answer, kept in memory for the sheet's
/// lifetime so a fresh model session can be seeded with the conversation
/// (never with the tool output behind it).
nonisolated struct TranscriptAskExchange: Equatable, Sendable {
    var question: String
    var answer: String
    var citationIDs: [Int]
    var isAnswerable: Bool
}
