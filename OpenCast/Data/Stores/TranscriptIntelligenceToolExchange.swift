/// One tool round trip the model made during a turn: the arguments it chose
/// and the text the tool returned. Citation validation later checks answers
/// against exactly the passages these outputs showed the model.
nonisolated struct TranscriptIntelligenceToolExchange: Equatable, Sendable {
    var toolName: String
    var argumentsJSON: String
    var output: String?
}
