import FoundationModels

/// The structured reply to one Ask question. `answer` comes first so it
/// streams before the citations; the validator decides which citations are
/// shown.
@Generable(description: "An answer to a listener's question about one podcast episode, grounded only in transcript passages returned by the tools.")
nonisolated struct TranscriptAnswer: Equatable, Sendable {
    @Guide(description: "One to four sentences answering the question using only the passages. When the passages do not answer it, a brief note saying so.")
    var answer: String
    @Guide(description: "Ids of the passage lines the answer relies on: the number after # at the start of each line. Empty when the passages do not answer the question.")
    var citations: [Int]
    @Guide(description: "True only when the passages answer the question.")
    var isAnswerable: Bool
}
