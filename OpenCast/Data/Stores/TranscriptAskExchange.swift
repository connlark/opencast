/// Seeds a fresh model session with the conversation, never with the tool output behind it.
nonisolated struct TranscriptAskExchange: Equatable, Sendable {
    var question: String
    var answer: String
    var citationIDs: [Int]
    var isAnswerable: Bool
}
